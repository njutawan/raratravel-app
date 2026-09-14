-- ============================================================================
-- 202609140004_payments.sql
-- Langkah 10 rencana migrasi: pembayaran + webhook.
--
-- Alur:
--   aplikasi → create_payment()            (booking milik pengguna, nominal ≤ total)
--   pengguna  → bayar di provider          (Midtrans/Xendit/transfer manual)
--   provider  → Edge Function payment-webhook → apply_payment_event()
--
-- Keamanan & ketahanan:
--   * Semua event webhook dicatat di `payment_events` dengan kunci unik
--     (provider, event_id) → webhook yang dikirim ulang provider TIDAK
--     memproses pembayaran dua kali (idempoten).
--   * Tanda tangan provider diverifikasi di Edge Function; RPC hanya mau
--     memproses event dengan p_signature_valid = true.
--   * Perubahan status booking ikut tercatat di booking_status_history.
-- ============================================================================

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  provider text not null
    check (provider in ('midtrans', 'xendit', 'manual', 'internal')),
  method text,
  provider_reference text,
  amount numeric(12, 2) not null check (amount > 0),
  paid_amount numeric(12, 2) check (paid_amount is null or paid_amount >= 0),
  currency text not null default 'IDR' check (char_length(currency) = 3),
  status text not null default 'pending'
    constraint payments_status_check
    check (status in ('pending', 'paid', 'failed', 'expired', 'refunded', 'cancelled')),
  checkout_url text,
  expires_at timestamptz,
  paid_at timestamptz,
  failure_reason text,
  created_by uuid references public.users(id) on delete set null,
  raw_request jsonb not null default '{}'::jsonb,
  raw_response jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists payments_provider_reference_idx
  on public.payments (provider, provider_reference)
  where provider_reference is not null;

create index if not exists payments_booking_idx
  on public.payments (booking_id, created_at desc);

create index if not exists payments_status_idx
  on public.payments (status)
  where status in ('pending', 'paid');

drop trigger if exists payments_set_updated_at on public.payments;
create trigger payments_set_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- payment_events: catatan mentah setiap webhook (audit + idempotency)
-- ---------------------------------------------------------------------------
create table if not exists public.payment_events (
  id bigint generated always as identity primary key,
  provider text not null,
  event_id text not null,
  event_type text,
  payment_id uuid references public.payments(id) on delete set null,
  booking_id uuid references public.bookings(id) on delete set null,
  signature_valid boolean not null default false,
  payload jsonb not null default '{}'::jsonb,
  processed_at timestamptz,
  processing_error text,
  created_at timestamptz not null default now()
);

create unique index if not exists payment_events_provider_event_idx
  on public.payment_events (provider, event_id);

create index if not exists payment_events_booking_idx
  on public.payment_events (booking_id, created_at desc);

-- ---------------------------------------------------------------------------
-- payment_json: bentuk balasan standar
-- ---------------------------------------------------------------------------
create or replace function public.payment_json(p_payment public.payments)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'id', p.id,
    'booking_id', p.booking_id,
    'provider', p.provider,
    'method', p.method,
    'provider_reference', p.provider_reference,
    'amount', p.amount,
    'paid_amount', p.paid_amount,
    'currency', p.currency,
    'status', p.status,
    'checkout_url', p.checkout_url,
    'expires_at', p.expires_at,
    'paid_at', p.paid_at,
    'failure_reason', p.failure_reason,
    'created_at', p.created_at,
    'updated_at', p.updated_at
  )
  from public.payments p
  where p.id = p_payment.id;
$$;

-- ===========================================================================
-- RPC: create_payment — buat "tagihan" untuk sebuah booking
-- ===========================================================================
create or replace function public.create_payment(
  p_user_id uuid,
  p_kode text,
  p_provider text,
  p_method text default null,
  p_amount numeric default null,
  p_provider_reference text default null,
  p_checkout_url text default null,
  p_expires_at timestamptz default null,
  p_raw_response jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
  v_payment public.payments;
  v_amount numeric(12, 2);
  v_provider text := lower(trim(coalesce(p_provider, 'manual')));
  v_reference text;
  v_paid numeric(12, 2);
begin
  if p_user_id is null then
    perform public.raise_app_error('validation_error', 'Pengguna tidak dikenali');
  end if;

  select * into v_booking
    from public.bookings b
   where b.kode = upper(trim(coalesce(p_kode, '')))
     and b.user_id = p_user_id
     for update;

  if v_booking.id is null then
    perform public.raise_app_error('not_found', 'Pesanan tidak ditemukan', jsonb_build_object('kode', p_kode));
  end if;
  if v_booking.status in ('cancelled', 'expired') then
    perform public.raise_app_error('conflict', 'Pesanan sudah dibatalkan/kedaluwarsa', jsonb_build_object('status', v_booking.status));
  end if;
  if v_booking.payment_status = 'paid' then
    perform public.raise_app_error('conflict', 'Pesanan ini sudah lunas', jsonb_build_object('kode', v_booking.kode));
  end if;
  if v_provider not in ('midtrans', 'xendit', 'manual', 'internal') then
    perform public.raise_app_error('validation_error', 'Provider pembayaran tidak dikenal', jsonb_build_object('provider', v_provider));
  end if;

  -- Nominal: boleh DP (uang muka), tidak boleh melebihi sisa tagihan.
  select coalesce(sum(p.paid_amount) filter (where p.status = 'paid'), 0)
    into v_paid
    from public.payments p
   where p.booking_id = v_booking.id;

  v_amount := coalesce(p_amount, v_booking.total - v_paid);
  if v_amount is null or v_amount <= 0 then
    perform public.raise_app_error('validation_error', 'Nominal pembayaran tidak valid', jsonb_build_object('amount', p_amount));
  end if;
  if v_amount > (v_booking.total - v_paid) then
    perform public.raise_app_error(
      'validation_error',
      'Nominal pembayaran melebihi sisa tagihan',
      jsonb_build_object('amount', v_amount, 'remaining', v_booking.total - v_paid)
    );
  end if;

  v_reference := nullif(trim(coalesce(p_provider_reference, '')), '');
  if v_reference is null then
    v_reference := case when v_provider = 'manual'
                        then v_booking.kode || '-MANUAL-' || public.random_code(4)
                        else v_booking.kode end;
  end if;

  insert into public.payments (
    booking_id, provider, method, provider_reference, amount, status,
    checkout_url, expires_at, created_by, raw_response
  )
  values (
    v_booking.id, v_provider, nullif(trim(coalesce(p_method, '')), ''), v_reference,
    v_amount, 'pending', nullif(trim(coalesce(p_checkout_url, '')), ''), p_expires_at,
    p_user_id, coalesce(p_raw_response, '{}'::jsonb)
  )
  on conflict (provider, provider_reference) where provider_reference is not null do update
    set amount = excluded.amount,
        method = coalesce(excluded.method, public.payments.method),
        checkout_url = coalesce(excluded.checkout_url, public.payments.checkout_url),
        expires_at = coalesce(excluded.expires_at, public.payments.expires_at),
        raw_response = public.payments.raw_response || excluded.raw_response,
        status = case when public.payments.status = 'pending' then 'pending' else public.payments.status end
  returning * into v_payment;

  -- Booking menunggu pembayaran; status booking itu sendiri belum berubah.
  update public.bookings b
     set payment_status = case when b.payment_status = 'unpaid' then 'pending' else b.payment_status end,
         payment_method = coalesce(b.payment_method, nullif(trim(coalesce(p_method, '')), '')),
         expires_at = coalesce(b.expires_at, p_expires_at)
   where b.id = v_booking.id
  returning * into v_booking;

  return jsonb_build_object(
    'payment', public.payment_json(v_payment),
    'booking', public.booking_json(v_booking),
    'remaining_amount', v_booking.total - v_paid - case when v_payment.status = 'paid' then 0 else 0 end
  );
end;
$$;

-- ===========================================================================
-- RPC: apply_payment_event — dipanggil webhook (setelah tanda tangan diverifikasi)
-- Idempoten terhadap (provider, event_id).
-- ===========================================================================
create or replace function public.apply_payment_event(
  p_provider text,
  p_event_id text,
  p_event_type text,
  p_status text,
  p_provider_reference text,
  p_amount numeric default null,
  p_payload jsonb default '{}'::jsonb,
  p_signature_valid boolean default false,
  p_failure_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_id bigint;
  v_event public.payment_events;
  v_payment public.payments;
  v_booking public.bookings;
  v_status text := lower(trim(coalesce(p_status, '')));
  v_paid_total numeric(12, 2);
  v_provider text := lower(trim(coalesce(p_provider, 'unknown')));
  v_paid_amount numeric(12, 2);
begin
  if coalesce(p_event_id, '') = '' then
    perform public.raise_app_error('validation_error', 'event_id webhook wajib ada');
  end if;
  if v_status not in ('pending', 'paid', 'failed', 'expired', 'refunded', 'cancelled') then
    perform public.raise_app_error('validation_error', 'Status pembayaran tidak dikenal', jsonb_build_object('status', p_status));
  end if;

  insert into public.payment_events (provider, event_id, event_type, signature_valid, payload)
  values (v_provider, p_event_id, nullif(trim(coalesce(p_event_type, '')), ''), coalesce(p_signature_valid, false), coalesce(p_payload, '{}'::jsonb))
  on conflict (provider, event_id) do nothing
  returning id into v_event_id;

  -- Sudah pernah diterima → jangan proses dua kali.
  if v_event_id is null then
    select * into v_event from public.payment_events e
     where e.provider = v_provider and e.event_id = p_event_id;
    return jsonb_build_object(
      'ok', true,
      'duplicate', true,
      'event_id', p_event_id,
      'processed_at', v_event.processed_at
    );
  end if;

  if not coalesce(p_signature_valid, false) then
    update public.payment_events e
       set processing_error = 'tanda tangan tidak valid'
     where e.id = v_event_id;
    return jsonb_build_object('ok', false, 'reason', 'invalid_signature', 'event_id', p_event_id);
  end if;

  select * into v_payment
    from public.payments p
   where p.provider = v_provider
     and p.provider_reference = nullif(trim(coalesce(p_provider_reference, '')), '')
     for update;

  if v_payment.id is null then
    update public.payment_events e
       set processing_error = 'pembayaran tidak ditemukan'
     where e.id = v_event_id;
    return jsonb_build_object('ok', false, 'reason', 'payment_not_found', 'event_id', p_event_id);
  end if;

  v_paid_amount := coalesce(p_amount, v_payment.amount);

  update public.payments p
     set status = v_status,
         paid_amount = case when v_status = 'paid' then v_paid_amount else p.paid_amount end,
         paid_at = case when v_status = 'paid' then now() else p.paid_at end,
         failure_reason = case when v_status in ('failed', 'expired')
                               then coalesce(nullif(trim(coalesce(p_failure_reason, '')), ''), p.failure_reason)
                               else p.failure_reason end,
         raw_response = p.raw_response || coalesce(p_payload, '{}'::jsonb)
   where p.id = v_payment.id
  returning * into v_payment;

  update public.payment_events e
     set payment_id = v_payment.id, booking_id = v_payment.booking_id, processed_at = now()
   where e.id = v_event_id;

  select * into v_booking from public.bookings b where b.id = v_payment.booking_id for update;
  if v_booking.id is null then
    return jsonb_build_object('ok', true, 'payment_id', v_payment.id, 'booking', null);
  end if;

  select coalesce(sum(p.paid_amount) filter (where p.status = 'paid'), 0)
    into v_paid_total
    from public.payments p
   where p.booking_id = v_booking.id;

  perform set_config('app.actor_role', 'webhook', true);
  perform set_config('app.actor_note', format('webhook %s: %s', v_provider, v_status), true);

  update public.bookings b
     set payment_status = case
           when v_status = 'paid' and v_paid_total >= b.total then 'paid'
           when v_status = 'paid' then 'partial'
           when v_status = 'refunded' then 'refunded'
           when v_status in ('failed', 'cancelled') then 'failed'
           when v_status = 'expired' then 'expired'
           else b.payment_status
         end,
         -- Lunas → konfirmasi otomatis (kursi diamankan).
         status = case
           when v_status = 'paid' and v_paid_total >= b.total and b.status = 'pending' then 'confirmed'
           when v_status = 'paid' and v_paid_total >= b.total then b.status
           else b.status
         end,
         confirmed_at = case
           when v_status = 'paid' and v_paid_total >= b.total and b.confirmed_at is null then now()
           else b.confirmed_at
         end
   where b.id = v_booking.id
  returning * into v_booking;

  return jsonb_build_object(
    'ok', true,
    'duplicate', false,
    'event_id', p_event_id,
    'payment', public.payment_json(v_payment),
    'booking', public.booking_json(v_booking),
    'paid_total', v_paid_total,
    'fully_paid', v_paid_total >= v_booking.total
  );
end;
$$;

-- ===========================================================================
-- RPC: payment_status_for_booking — dipakai aplikasi untuk memantau tagihan
-- ===========================================================================
create or replace function public.payment_status_for_booking(p_user_id uuid, p_kode text)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
  v_payments jsonb;
  v_paid numeric(12, 2);
begin
  if p_user_id is null then
    perform public.raise_app_error('validation_error', 'Pengguna tidak dikenali');
  end if;

  select * into v_booking
    from public.bookings b
   where b.kode = upper(trim(coalesce(p_kode, ''))) and b.user_id = p_user_id;

  if v_booking.id is null then
    perform public.raise_app_error('not_found', 'Pesanan tidak ditemukan', jsonb_build_object('kode', p_kode));
  end if;

  select coalesce(jsonb_agg(public.payment_json(p) order by p.created_at desc), '[]'::jsonb),
         coalesce(sum(p.paid_amount) filter (where p.status = 'paid'), 0)
    into v_payments, v_paid
    from public.payments p
   where p.booking_id = v_booking.id;

  return jsonb_build_object(
    'booking_kode', v_booking.kode,
    'booking_status', v_booking.status,
    'payment_status', v_booking.payment_status,
    'total', v_booking.total,
    'paid_total', v_paid,
    'remaining_amount', greatest(v_booking.total - v_paid, 0),
    'payments', v_payments
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Keamanan
-- ---------------------------------------------------------------------------
alter table public.payments enable row level security;
alter table public.payment_events enable row level security;

revoke all on table public.payments from anon, authenticated;
revoke all on table public.payment_events from anon, authenticated;

revoke all on function public.create_payment(uuid, text, text, text, numeric, text, text, timestamptz, jsonb) from public;
revoke all on function public.apply_payment_event(text, text, text, text, text, numeric, jsonb, boolean, text) from public;
revoke all on function public.payment_status_for_booking(uuid, text) from public;

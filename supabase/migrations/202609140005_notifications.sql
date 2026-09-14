-- ============================================================================
-- 202609140005_notifications.sql
-- Langkah 9 rencana migrasi: perubahan status booking otomatis memicu
-- Edge Function notifikasi (FCM) tanpa polling dari aplikasi.
--
-- Kenapa lewat tabel antrean (`notification_jobs`) dan bukan langsung kirim
-- dari trigger?
--   1. Trigger tidak boleh gagal hanya karena jaringan/HTTP error.
--   2. Kalau Edge Function sedang mati, notifikasi tetap tersimpan dan
--      terkirim saat cron berikutnya (tidak hilang).
--   3. Ada jejak audit: apa yang dikirim, kapan, berhasil atau tidak.
-- ============================================================================

create table if not exists public.notification_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete cascade,
  channel text not null default 'fcm'
    check (channel in ('fcm', 'whatsapp', 'email')),
  title text not null,
  body text,
  data jsonb not null default '{}'::jsonb,
  status text not null default 'queued'
    constraint notification_jobs_status_check
    check (status in ('queued', 'dispatched', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 3 check (max_attempts > 0),
  last_error text,
  provider_message_id text,
  dedupe_key text,
  scheduled_at timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Satu peristiwa (booking + status + status bayar) hanya menghasilkan satu job.
create unique index if not exists notification_jobs_dedupe_idx
  on public.notification_jobs (dedupe_key)
  where dedupe_key is not null;

create index if not exists notification_jobs_queue_idx
  on public.notification_jobs (scheduled_at)
  where status in ('queued', 'failed');

create index if not exists notification_jobs_user_idx
  on public.notification_jobs (user_id, created_at desc);

drop trigger if exists notification_jobs_set_updated_at on public.notification_jobs;
create trigger notification_jobs_set_updated_at
  before update on public.notification_jobs
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Susun judul & isi notifikasi untuk sebuah booking (mudah diuji terpisah).
-- ---------------------------------------------------------------------------
create or replace function public.booking_notification_text(p_booking public.bookings)
returns jsonb
language plpgsql
stable
as $$
declare
  v_jam text;
  v_rute text;
  v_kapan text;
  v_title text;
  v_body text;
begin
  v_jam := case when p_booking.departure_time is null then ''
                else ' jam ' || replace(to_char(p_booking.departure_time, 'HH24:MI'), ':', '.') end;
  v_rute := p_booking.origin_name || ' → ' || p_booking.destination_name;
  v_kapan := to_char(p_booking.travel_date, 'DD Mon YYYY');

  v_title := case p_booking.status
    when 'pending'   then 'Pesanan ' || p_booking.kode || ' diterima'
    when 'confirmed' then 'Pesanan ' || p_booking.kode || ' dikonfirmasi'
    when 'completed' then 'Pesanan ' || p_booking.kode || ' selesai — terima kasih!'
    when 'cancelled' then 'Pesanan ' || p_booking.kode || ' dibatalkan'
    when 'expired'   then 'Pesanan ' || p_booking.kode || ' kedaluwarsa'
    else 'Pembaruan pesanan ' || p_booking.kode
  end;

  if p_booking.status = 'pending' and p_booking.payment_status = 'partial' then
    v_title := 'Pembayaran sebagian diterima — ' || p_booking.kode;
  end if;
  if p_booking.status = 'confirmed' and p_booking.payment_status = 'paid' then
    v_title := 'Pembayaran lunas — ' || p_booking.kode || ' siap berangkat';
  end if;

  v_body := v_rute || ', ' || v_kapan || v_jam || ' • ' || p_booking.seats || ' kursi';

  return jsonb_build_object(
    'title', v_title,
    'body', v_body,
    'kode', p_booking.kode,
    'status', p_booking.status,
    'status_label', public.booking_status_label(p_booking.status)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Trigger: antrekan notifikasi setiap status berubah.
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_booking_notification()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_text jsonb;
  v_job_id uuid;
  v_dedupe text;
  v_url text;
  v_secret text;
begin
  if coalesce(new.user_id, null) is null then
    return null;
  end if;

  if tg_op = 'UPDATE'
     and new.status is not distinct from old.status
     and new.payment_status is not distinct from old.payment_status then
    return null;
  end if;

  v_text := public.booking_notification_text(new);
  v_dedupe := new.id::text || ':' || new.status || ':' || new.payment_status;

  insert into public.notification_jobs (
    user_id, booking_id, channel, title, body, data, dedupe_key, status
  )
  values (
    new.user_id, new.id, 'fcm',
    v_text->>'title', v_text->>'body',
    jsonb_build_object(
      'screen', 'orders',
      'kode', new.kode,
      'status', new.status,
      'status_label', v_text->>'status_label'
    ),
    v_dedupe, 'queued'
  )
  on conflict (dedupe_key) where dedupe_key is not null do nothing
  returning id into v_job_id;

  if v_job_id is null then
    return null;  -- sudah pernah diantrekan untuk perubahan yang sama
  end if;

  -- Kirim segera bila pg_net + URL Edge Function tersedia.
  -- Bila tidak, job tetap 'queued' dan dikirim oleh cron/drain berikutnya.
  v_url := nullif(current_setting('app.settings.notify_endpoint', true), '');
  v_secret := nullif(current_setting('app.settings.notify_secret', true), '');

  if v_url is not null and to_regproc('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null then
    begin
      -- Status job TIDAK diubah di sini: Edge Function yang menandai
      -- 'dispatched' saat benar-benar mengambil job. Kalau panggilan ini
      -- gagal (Edge Function mati/jaringan), job tetap 'queued' dan akan
      -- dikirim oleh cron drain — notifikasi tidak hilang.
      perform net.http_post(
        url := v_url,
        body := jsonb_build_object('job_id', v_job_id),
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-webhook-secret', coalesce(v_secret, '')
        ),
        timeout_milliseconds := 5000
      );
    exception when others then
      update public.notification_jobs j
         set last_error = left(sqlerrm, 500)
       where j.id = v_job_id;
    end;
  end if;

  return null;
end;
$$;

drop trigger if exists bookings_enqueue_notification on public.bookings;
create trigger bookings_enqueue_notification
  after insert or update of status, payment_status on public.bookings
  for each row execute function public.enqueue_booking_notification();

-- ---------------------------------------------------------------------------
-- RPC: claim_notification_jobs — Edge Function mengambil job siap kirim.
-- FOR UPDATE SKIP LOCKED: dua instance function tidak akan mengirim job sama.
-- ---------------------------------------------------------------------------
create or replace function public.claim_notification_jobs(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_jobs jsonb;
begin
  with siap as (
    select j.id
      from public.notification_jobs j
     where j.status in ('queued', 'failed')
       and j.attempts < j.max_attempts
       and j.scheduled_at <= now()
       and j.channel = 'fcm'
     order by j.scheduled_at
     limit v_limit
     for update skip locked
  ), klaim as (
    update public.notification_jobs j
       set status = 'dispatched',
           attempts = j.attempts + 1
      from siap s
     where j.id = s.id
    returning j.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', k.id,
           'user_id', k.user_id,
           'booking_id', k.booking_id,
           'title', k.title,
           'body', k.body,
           'data', k.data,
           'attempts', k.attempts,
           'max_attempts', k.max_attempts,
           'tokens', coalesce(
             (select jsonb_agg(d.fcm_token)
                from public.user_devices d
               where d.user_id = k.user_id and d.is_active),
             '[]'::jsonb)
         )), '[]'::jsonb)
    into v_jobs
    from klaim k;

  return jsonb_build_object('jobs', v_jobs, 'count', jsonb_array_length(v_jobs));
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: complete_notification_job — catat hasil kirim + bersihkan token mati
-- ---------------------------------------------------------------------------
create or replace function public.complete_notification_job(
  p_job_id uuid,
  p_ok boolean,
  p_error text default null,
  p_provider_message_id text default null,
  p_invalid_tokens text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_job public.notification_jobs;
  v_invalid integer := 0;
begin
  select * into v_job from public.notification_jobs j where j.id = p_job_id for update;
  if v_job.id is null then
    perform public.raise_app_error('not_found', 'Job notifikasi tidak ditemukan', jsonb_build_object('job_id', p_job_id));
  end if;

  if p_invalid_tokens is not null and array_length(p_invalid_tokens, 1) > 0 then
    update public.user_devices d
       set is_active = false,
           failure_count = d.failure_count + 1
     where d.fcm_token = any(p_invalid_tokens);
    get diagnostics v_invalid = row_count;
  end if;

  if coalesce(p_ok, false) then
    update public.notification_jobs j
       set status = 'sent',
           sent_at = now(),
           last_error = null,
           provider_message_id = coalesce(nullif(trim(coalesce(p_provider_message_id, '')), ''), j.provider_message_id)
     where j.id = p_job_id
    returning * into v_job;
  elsif v_job.attempts >= v_job.max_attempts then
    update public.notification_jobs j
       set status = 'failed',
           last_error = left(coalesce(p_error, 'gagal tanpa keterangan'), 500)
     where j.id = p_job_id
    returning * into v_job;
  else
    -- Mundur bertahap: 5 menit × percobaan ke-.
    update public.notification_jobs j
       set status = 'queued',
           last_error = left(coalesce(p_error, 'gagal tanpa keterangan'), 500),
           scheduled_at = now() + (interval '5 minutes' * j.attempts)
     where j.id = p_job_id
    returning * into v_job;
  end if;

  return jsonb_build_object(
    'job_id', v_job.id,
    'status', v_job.status,
    'attempts', v_job.attempts,
    'invalid_tokens_deactivated', v_invalid,
    'scheduled_at', v_job.scheduled_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Ringkasan antrean untuk pemantauan admin
-- ---------------------------------------------------------------------------
create or replace function public.notification_queue_summary()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'queued', count(*) filter (where status = 'queued'),
    'dispatched', count(*) filter (where status = 'dispatched'),
    'sent', count(*) filter (where status = 'sent'),
    'failed', count(*) filter (where status = 'failed'),
    'oldest_queued_at', min(created_at) filter (where status = 'queued')
  )
  from public.notification_jobs;
$$;

-- ---------------------------------------------------------------------------
-- Keamanan
-- ---------------------------------------------------------------------------
alter table public.notification_jobs enable row level security;
revoke all on table public.notification_jobs from anon, authenticated;
revoke all on function public.claim_notification_jobs(integer) from public;
revoke all on function public.complete_notification_job(uuid, boolean, text, text, text[]) from public;

-- ---------------------------------------------------------------------------
-- Opsional: jalankan drain otomatis tiap 5 menit bila pg_cron + pg_net ada.
-- Di Supabase keduanya tinggal diaktifkan di Dashboard → Database → Extensions.
-- ---------------------------------------------------------------------------
do $$
declare
  v_url text := nullif(current_setting('app.settings.notify_endpoint', true), '');
  v_secret text := nullif(current_setting('app.settings.notify_secret', true), '');
begin
  if to_regproc('cron.schedule(text,text,text)') is null then
    raise notice 'pg_cron tidak aktif — pakai Scheduled Function di Dashboard untuk memanggil notify-booking-status (mode drain).';
    return;
  end if;
  if to_regproc('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise notice 'pg_net tidak aktif — notifikasi hanya dikirim saat Edge Function dipanggil manual.';
    return;
  end if;

  perform cron.unschedule('rara-drain-notifications')
    where exists (select 1 from cron.job j where j.jobname = 'rara-drain-notifications');

  if v_url is null then
    raise notice 'app.settings.notify_endpoint belum diisi — cron drain dilewati. Lihat MIGRASI_SUPABASE.md.';
    return;
  end if;

  perform cron.schedule(
    'rara-drain-notifications',
    '*/5 * * * *',
    format(
      'select net.http_post(url := %L, body := ''{"drain": true}''::jsonb, headers := jsonb_build_object(''Content-Type'', ''application/json'', ''x-webhook-secret'', %L), timeout_milliseconds := 10000)',
      v_url, coalesce(v_secret, '')
    )
  );

  raise notice 'Cron drain notifikasi aktif (tiap 5 menit).';
end $$;

-- ---------------------------------------------------------------------------
-- RPC: prepare_notification_job — kirim SATU job tertentu (dipanggil trigger
-- langsung setelah HTTP request dikirim ke Edge Function).
-- Idempoten: job yang sudah dikirim tidak akan diproses ulang (return null).
-- ---------------------------------------------------------------------------
create or replace function public.prepare_notification_job(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_job public.notification_jobs;
  v_tokens jsonb;
begin
  if p_job_id is null then
    return null;
  end if;

  update public.notification_jobs j
     set status = 'dispatched',
         attempts = j.attempts + 1
   where j.id = p_job_id
     and j.status in ('queued', 'failed')
     and j.attempts < j.max_attempts
  returning * into v_job;

  if v_job.id is null then
    return null;
  end if;

  select coalesce(jsonb_agg(d.fcm_token), '[]'::jsonb)
    into v_tokens
    from public.user_devices d
   where d.user_id = v_job.user_id and d.is_active;

  return jsonb_build_object(
    'job_id', v_job.id,
    'user_id', v_job.user_id,
    'booking_id', v_job.booking_id,
    'title', v_job.title,
    'body', v_job.body,
    'data', v_job.data,
    'attempts', v_job.attempts,
    'max_attempts', v_job.max_attempts,
    'tokens', v_tokens
  );
end;
$$;

revoke all on function public.prepare_notification_job(uuid) from public;

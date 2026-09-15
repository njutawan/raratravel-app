#!/usr/bin/env python3
"""Generate Android launcher icons + logo aplikasi dari master icon.

Sumber : assets_src/icon_master.png (persegi, background TRANSPARAN)
Hasil  : mipmap-{mdpi..xxxhdpi}/ic_launcher.png (+round, +foreground)
         assets/icon/app_logo.png (logo untuk splash & header di Flutter)
         assets_src/preview_round.png (pratinjau ikon bulat)

Cara pakai (dari root proyek):
    python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pillow
    /tmp/venv/bin/python tools/make_icons.py

Ganti master icon dengan desain sendiri lalu jalankan ulang script ini.
"""
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit('Pillow belum terinstall.')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, 'assets_src', 'icon_master.png')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
BRAND_BLUE = (21, 101, 192, 255)  # AppTheme.primary (#1565C0)


def emblem_fit(master, canvas_px, fill):
    """Master transparan diskalakan agar emblem selebar `fill`×kanvas,
    lalu ditempatkan di tengah kanvas transparan `canvas_px`."""
    side = int(canvas_px * fill)
    small = master.resize((side, side), Image.LANCZOS)
    canvas = Image.new('RGBA', (canvas_px, canvas_px), (0, 0, 0, 0))
    off = (canvas_px - side) // 2
    canvas.alpha_composite(small, (off, off))
    return canvas


def main():
    if not os.path.exists(MASTER):
        sys.exit(f'Master icon tidak ditemukan: {MASTER}')
    master = Image.open(MASTER).convert('RGBA')
    w, h = master.size
    s = min(w, h)
    master = master.crop(((w - s) // 2, (h - s) // 2, (w + s) // 2, (h + s) // 2))
    print(f'Master: {s}x{s} (transparan)')

    legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    fore = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}

    for d, px in legacy.items():
        ddir = os.path.join(RES, f'mipmap-{d}')
        os.makedirs(ddir, exist_ok=True)
        # Legacy: emblem 68% di atas biru brand (konsisten di semua HP).
        bg = Image.new('RGBA', (px, px), BRAND_BLUE)
        bg.alpha_composite(emblem_fit(master, px, 0.68), (0, 0))
        bg.save(os.path.join(ddir, 'ic_launcher.png'))
        mask = Image.new('L', (px, px), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, px, px), fill=255)
        bg.putalpha(mask)
        bg.save(os.path.join(ddir, 'ic_launcher_round.png'))
        print(f'  mipmap-{d}: launcher {px}px + round {px}px')

    for d, px in fore.items():
        ddir = os.path.join(RES, f'mipmap-{d}')
        os.makedirs(ddir, exist_ok=True)
        # Foreground adaptif: emblem 60% di tengah (zona aman 72/108dp,
        # tak terpotong masker lingkaran/squircle) + transparan.
        emblem_fit(master, px, 0.60).save(
            os.path.join(ddir, 'ic_launcher_foreground.png'))
        print(f'  mipmap-{d}: foreground {px}px')

    adir = os.path.join(ROOT, 'assets', 'icon')
    os.makedirs(adir, exist_ok=True)
    # Logo dalam aplikasi: transparan (bagus di splash biru & kartu putih).
    master.resize((512, 512), Image.LANCZOS).save(
        os.path.join(adir, 'app_logo.png'))
    print('  assets/icon/app_logo.png: 512px transparan')

    # Pratinjau ikon bulat (seperti tampil di launcher HP modern).
    prev = Image.new('RGBA', (512, 512), BRAND_BLUE)
    prev.alpha_composite(emblem_fit(master, 512, 0.68), (0, 0))
    pmask = Image.new('L', (512, 512), 0)
    ImageDraw.Draw(pmask).ellipse((0, 0, 512, 512), fill=255)
    prev.putalpha(pmask)
    prev.save(os.path.join(ROOT, 'assets_src', 'preview_round.png'))
    print('  assets_src/preview_round.png: pratinjau')
    print('Selesai')


if __name__ == '__main__':
    main()

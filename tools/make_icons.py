#!/usr/bin/env python3
"""Generate Android launcher icons + logo aplikasi dari master icon.

Sumber : assets_src/icon_master.png (persegi, full-bleed)
Hasil  : mipmap-{mdpi..xxxhdpi}/ic_launcher.png (+round, +foreground)
         assets/icon/app_logo.png (logo untuk splash & header di Flutter)

Cara pakai (dari root proyek):
    pip install pillow
    python3 tools/make_icons.py

Ganti master icon dengan desain sendiri lalu jalankan ulang script ini.
"""
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit('Pillow belum terinstall. Jalankan: pip install pillow')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, 'assets_src', 'icon_master.png')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')


def main():
    if not os.path.exists(MASTER):
        sys.exit(f'Master icon tidak ditemukan: {MASTER}')
    master = Image.open(MASTER).convert('RGBA')
    w, h = master.size
    s = min(w, h)
    master = master.crop(((w - s) // 2, (h - s) // 2, (w + s) // 2, (h + s) // 2))
    print(f'Master: {s}x{s}')

    legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    fore = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}

    for d, px in legacy.items():
        ddir = os.path.join(RES, f'mipmap-{d}')
        os.makedirs(ddir, exist_ok=True)
        img = master.resize((px, px), Image.LANCZOS)
        img.save(os.path.join(ddir, 'ic_launcher.png'))
        mask = Image.new('L', (px, px), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, px, px), fill=255)
        img.putalpha(mask)
        img.save(os.path.join(ddir, 'ic_launcher_round.png'))
        print(f'  mipmap-{d}: launcher {px}px + round {px}px')

    for d, px in fore.items():
        ddir = os.path.join(RES, f'mipmap-{d}')
        os.makedirs(ddir, exist_ok=True)
        master.resize((px, px), Image.LANCZOS).save(
            os.path.join(ddir, 'ic_launcher_foreground.png'))
        print(f'  mipmap-{d}: foreground {px}px')

    adir = os.path.join(ROOT, 'assets', 'icon')
    os.makedirs(adir, exist_ok=True)
    master.resize((512, 512), Image.LANCZOS).save(
        os.path.join(adir, 'app_logo.png'))
    print('  assets/icon/app_logo.png: 512px')
    print('Selesai')


if __name__ == '__main__':
    main()

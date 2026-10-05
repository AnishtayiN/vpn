#!/usr/bin/env python3
"""Populate every Flutter-created iOS icon slot, including opaque store art."""
import json
from pathlib import Path
from PIL import Image
root = Path(__file__).resolve().parents[2]
folder = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
manifest = json.loads((folder / 'Contents.json').read_text())
source = Image.open(root / 'assets/branding/icon.png').convert('RGBA')
background = Image.new('RGB', source.size, '#10141f')
background.paste(source, mask=source.getchannel('A'))
for icon in manifest['images']:
    if 'filename' not in icon:
        continue
    pixels = round(float(icon['size'].split('x')[0]) * float(icon['scale'].rstrip('x')))
    background.resize((pixels, pixels), Image.Resampling.LANCZOS).save(folder / icon['filename'])

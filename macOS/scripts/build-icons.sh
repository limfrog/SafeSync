#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_image="$PWD/Resources/SafeSync.png"
iconset="$PWD/build/SafeSync.iconset"
mkdir -p "$iconset" "$PWD/Resources"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_image" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$source_image" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# Encode standard PNG-backed ICNS chunks (keeps source artwork unchanged).
python3 - <<'PYICON'
from pathlib import Path
import struct
root = Path('build/SafeSync.iconset')
entries = [('icp4','16x16'), ('icp5','32x32'), ('ic07','128x128'), ('ic08','256x256'), ('ic09','512x512'), ('ic10','512x512@2x'), ('ic11','16x16@2x'), ('ic12','32x32@2x'), ('ic13','128x128@2x'), ('ic14','256x256@2x')]
chunks = []
for tag, size in entries:
    data = (root / ('icon_' + size + '.png')).read_bytes()
    chunks.append(tag.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
Path('Resources/SafeSync.icns').write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
PYICON

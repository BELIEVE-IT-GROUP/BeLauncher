#!/bin/bash
# Produces AppIcon.icns at the path given as $1.
#
# Uses Resources/AppIcon-1024.png when it exists (the artwork of record), and otherwise
# draws the mark in code so a build never ends up with a blank icon.
set -euo pipefail

OUT="${1:?usage: make-icon.sh <output.icns>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Resources/AppIcon-1024.png"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$SOURCE" ]; then
    echo "▸ Icon: Resources/AppIcon-1024.png"
    cp "$SOURCE" "$WORK/master.png"
else
    echo "▸ Icon: drawing fallback mark (add Resources/AppIcon-1024.png to override)"
    swift "$ROOT/Scripts/draw-icon.swift" "$WORK/master.png"
fi

mkdir -p "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/master.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORK/master.png" \
        --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
echo "▸ Wrote $OUT"

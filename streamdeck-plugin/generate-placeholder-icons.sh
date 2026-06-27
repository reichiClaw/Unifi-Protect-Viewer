#!/usr/bin/env bash
# Generate simple placeholder PNG icons for the Stream Deck plugin.
# Requires ImageMagick (`brew install imagemagick`).
set -euo pipefail

ICONS_DIR="$(cd "$(dirname "$0")" && pwd)/com.unifiprotectviewer.sdPlugin/icons"
mkdir -p "$ICONS_DIR"

if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
  echo "ImageMagick not found. Install with: brew install imagemagick" >&2
  exit 1
fi

# Pick the available ImageMagick command.
IM="magick"
command -v magick >/dev/null 2>&1 || IM="convert"

# label  base-name  glyph
make_icon() {
  local name="$1" size="$2" size2="$3" label="$4" bg="$5"
  "$IM" -size "${size}x${size}" "xc:${bg}" \
    -gravity center -fill white -pointsize $((size/4)) -annotate 0 "$label" \
    "$ICONS_DIR/${name}.png"
  "$IM" -size "${size2}x${size2}" "xc:${bg}" \
    -gravity center -fill white -pointsize $((size2/4)) -annotate 0 "$label" \
    "$ICONS_DIR/${name}@2x.png"
}

make_icon plugin 28 56 "UP" "#1b6dff"
make_icon category 28 56 "UP" "#1b6dff"
make_icon key 72 144 "UP" "#222222"
make_icon switchView 20 40 "VW" "#222222"
make_icon nextView 20 40 ">" "#222222"
make_icon prevView 20 40 "<" "#222222"
make_icon fullscreen 20 40 "FS" "#222222"
make_icon exitFullscreen 20 40 "ESC" "#222222"

echo "Placeholder icons written to $ICONS_DIR"

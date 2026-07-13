#!/usr/bin/env bash
#
# Build a distributable `com.unifiprotectviewer.streamDeckPlugin` installer that
# users can double-click to install (no manual file copying).
#
# Prefers Elgato's official CLI (which validates the plugin first); falls back to
# a plain zip if the CLI isn't available — the .streamDeckPlugin format is just a
# zip of the .sdPlugin folder.
#
# Usage:  streamdeck-plugin/pack.sh

set -euo pipefail

cd "$(dirname "$0")"
PLUGIN="com.unifiprotectviewer.sdPlugin"
OUT="dist"
ARTIFACT="$OUT/com.unifiprotectviewer.streamDeckPlugin"

if [[ ! -f "$PLUGIN/manifest.json" ]]; then
  echo "error: $PLUGIN/manifest.json not found (run from the repo)." >&2
  exit 1
fi

# Ensure icons exist; regenerate them if Pillow is available and any are missing.
if [[ ! -f "$PLUGIN/icons/plugin.png" ]] && command -v python3 >/dev/null 2>&1; then
  python3 generate-icons.py || true
fi

mkdir -p "$OUT"
rm -f "$ARTIFACT"

if command -v npx >/dev/null 2>&1 && npx --yes @elgato/cli@latest validate "$PLUGIN"; then
  npx --yes @elgato/cli@latest pack "$PLUGIN" --output "$OUT" --force
  echo "Packed (validated) with @elgato/cli → $ARTIFACT"
else
  echo "Elgato CLI unavailable — using zip fallback (no validation)." >&2
  ( cd "$PLUGIN/.." && zip -r -X "$OLDPWD/$ARTIFACT" "$PLUGIN" \
      -x "*/.DS_Store" "*/icons/README.md" "*/.sdignore" >/dev/null )
  echo "Packed with zip fallback → $ARTIFACT"
fi

echo "Double-click the file to install it into the Stream Deck app."

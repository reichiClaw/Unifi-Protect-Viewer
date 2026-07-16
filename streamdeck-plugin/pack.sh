#!/usr/bin/env bash
#
# Build a distributable `com.unifiprotectviewer.streamDeckPlugin` installer that
# users can double-click to install (no manual file copying).
#
# Uses a pinned Elgato CLI release and refuses to package unvalidated content.
#
# Usage:  streamdeck-plugin/pack.sh

set -euo pipefail

cd "$(dirname "$0")"
PLUGIN="com.unifiprotectviewer.sdPlugin"
OUT="dist"
ARTIFACT="$OUT/com.unifiprotectviewer.streamDeckPlugin"
ELGATO_CLI_VERSION="1.7.4"

if [[ ! -f "$PLUGIN/manifest.json" ]]; then
  echo "error: $PLUGIN/manifest.json not found (run from the repo)." >&2
  exit 1
fi

# Ensure icons exist; regenerate them if Pillow is available and any are missing.
if [[ ! -f "$PLUGIN/icons/plugin.png" ]]; then
  command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required to generate icons" >&2; exit 1; }
  python3 generate-icons.py
fi

mkdir -p "$OUT"
rm -f "$ARTIFACT"

command -v npx >/dev/null 2>&1 || { echo "error: npx is required for validated packaging" >&2; exit 1; }
npx --yes "@elgato/cli@${ELGATO_CLI_VERSION}" validate "$PLUGIN"
npx --yes "@elgato/cli@${ELGATO_CLI_VERSION}" pack "$PLUGIN" --output "$OUT" --force
echo "Packed (validated) with @elgato/cli ${ELGATO_CLI_VERSION} → $ARTIFACT"

echo "Double-click the file to install it into the Stream Deck app."

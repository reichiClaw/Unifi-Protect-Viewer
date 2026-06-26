#!/usr/bin/env bash
# Generate the Xcode project for UniFi Protect Viewer.
#
# Requires macOS with Xcode and XcodeGen (`brew install xcodegen`).
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "Generating UnifiProtectViewer.xcodeproj from project.yml…"
xcodegen generate

echo "Done. Open it with:"
echo "  open UnifiProtectViewer.xcodeproj"

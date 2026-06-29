#!/usr/bin/env bash
# Build, sign, (optionally) notarize and package a Release build of
# UniFi Protect Viewer for distribution to other Macs.
#
# Requirements:
#   - macOS with Xcode + XcodeGen (`brew install xcodegen`)
#   - A "Developer ID Application" certificate in your keychain
#   - scripts/ExportOptions.plist with your Team ID filled in
#
# Optional notarization: set NOTARY_PROFILE to a stored notarytool profile
# (see docs/DISTRIBUTION.md) to notarize + staple automatically.
#
# Usage:
#   ./scripts/build-release.sh                 # build + export (+ notarize if NOTARY_PROFILE set)
#   NOTARY_PROFILE=UPV-NOTARY ./scripts/build-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="UnifiProtectViewer.xcodeproj"
SCHEME="UnifiProtectViewer"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/UnifiProtectViewer.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/UnifiProtectViewer.app"

command -v xcodegen >/dev/null 2>&1 || { echo "Install XcodeGen: brew install xcodegen" >&2; exit 1; }

echo "==> Generating project"
xcodegen generate

echo "==> Archiving (Release)"
rm -rf "$ARCHIVE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" archive

echo "==> Exporting (Developer ID)"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$EXPORT_DIR"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing with profile '$NOTARY_PROFILE'"
  ( cd "$EXPORT_DIR" && ditto -c -k --keepParent UnifiProtectViewer.app UnifiProtectViewer.zip )
  xcrun notarytool submit "$EXPORT_DIR/UnifiProtectViewer.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$APP"
  rm -f "$EXPORT_DIR/UnifiProtectViewer.zip"
fi

echo "==> Creating DMG"
hdiutil create -volname "UniFi Protect Viewer" \
  -srcfolder "$APP" -ov -format UDZO "$BUILD_DIR/UnifiProtectViewer.dmg"

echo "Done:"
echo "  App: $APP"
echo "  DMG: $BUILD_DIR/UnifiProtectViewer.dmg"
[[ -z "${NOTARY_PROFILE:-}" ]] && echo "  (Not notarized — set NOTARY_PROFILE to notarize for distribution.)"

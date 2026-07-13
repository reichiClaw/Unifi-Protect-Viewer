#!/usr/bin/env bash
#
# Installs a per-user launchd LaunchAgent that keeps UniFi Protect Viewer running
# on a 24/7 control-room wall: launchd relaunches it within seconds of any
# abnormal exit (crash / force-quit / out-of-memory kill) and starts it at login.
#
# A clean Quit (⌘Q) is respected and does NOT trigger a relaunch.
#
# Usage:
#   scripts/install-autorestart.sh                 # auto-detect the installed app
#   scripts/install-autorestart.sh /path/to/UnifiProtectViewer.app
#   scripts/install-autorestart.sh --uninstall
#
# Note: you can also toggle this from the app: Settings → Reliability.

set -euo pipefail

LABEL="com.unifiprotectviewer.autorestart"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl unload -w "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed auto-restart LaunchAgent ($PLIST)."
  exit 0
fi

APP="${1:-/Applications/UnifiProtectViewer.app}"
EXE="$APP/Contents/MacOS/UnifiProtectViewer"

if [[ ! -x "$EXE" ]]; then
  echo "error: app executable not found at: $EXE" >&2
  echo "Pass the path to UnifiProtectViewer.app as the first argument." >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>Program</key>
    <string>${EXE}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>ThrottleInterval</key>
    <integer>5</integer>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "Installed auto-restart LaunchAgent for: $EXE"
echo "Plist: $PLIST"
echo "Disable with: $0 --uninstall  (or Settings → Reliability in the app)"

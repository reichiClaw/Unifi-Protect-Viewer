# Running 24/7 in a control room

This app is built to run continuously on a live wall. This guide covers how to
make it recover on its own and how to keep low‑RAM machines (e.g. an 8 GB M2
mini) stable over long uptime.

## 1. Auto‑restart (recommended)

Enable **Settings → Reliability → “Automatically restart if it crashes or is
killed.”** This installs a per‑user launchd **LaunchAgent** that:

- starts the app at login, and
- relaunches it within seconds of any *abnormal* exit — a crash, a hang you
  force‑quit, or an out‑of‑memory (**jetsam**) kill.

A normal **Quit** (⌘Q) is respected and will **not** relaunch. If you move or
rename the app after enabling this, toggle it off and on again so the restart
points at the new location.

You can also install it from the command line (useful for headless setups):

```bash
scripts/install-autorestart.sh /Applications/UnifiProtectViewer.app
# disable:
scripts/install-autorestart.sh --uninstall
```

The LaunchAgent lives at
`~/Library/LaunchAgents/com.unifiprotectviewer.autorestart.plist`.

## 2. Keep memory under control (8 GB machines)

Decoded video RAM scales with resolution × number of tiles. The biggest levers,
in order:

1. **Grid quality = Low** (Settings → Connection → Streaming). By far the single
   biggest reduction in memory.
2. **Hardware decoding = on** (VideoToolbox) — less CPU and lower memory
   pressure than software decoding.
3. Prefer **fewer very‑high‑res tiles** per view; use **Fullscreen (High)** for
   detail on demand.

The app also actively protects itself:

- It frees a stream’s buffers when it scrolls off‑screen and fully evicts
  players that stay off‑screen.
- It listens for macOS **memory‑pressure** warnings and immediately releases
  off‑screen players when the system is low on RAM.
- It periodically recreates long‑running decoders to shed any slow drift/leak
  in the video engine over multi‑day uptime.

## 3. If it still crashes — get the evidence

The app records CPU, memory, memory‑pressure events and crashes to its own log:

- **In‑app:** Settings → Reliability → *Reveal log file in Finder* (or the log
  window). The log rotates automatically so it stays readable over long runs.
- **macOS reports:** `~/Library/Logs/DiagnosticReports/`. A `JetsamEvent‑*.ips`
  there means the app was killed for using too much memory (see section 2). A
  regular `.ips`/crash report with a backtrace means an in‑app/engine crash —
  share it (and the app log) so it can be diagnosed.

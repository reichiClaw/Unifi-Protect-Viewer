# Building UniFi Protect Viewer on a Mac

This guide walks through compiling and running the app on macOS from a clean
machine. The project ships as Swift source plus an [XcodeGen](https://github.com/yonyz/XcodeGen)
spec (`project.yml`) rather than a committed `.xcodeproj`, so the first step is
generating the Xcode project.

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| macOS 13 (Ventura) or newer | Deployment target is macOS 13. |
| Xcode 15 or newer | Install from the App Store, then run it once to finish component setup. |
| Xcode Command Line Tools | `xcode-select --install` |
| Homebrew | https://brew.sh — used to install XcodeGen |
| XcodeGen | `brew install xcodegen` |

Verify the toolchain:

```bash
xcodebuild -version     # Xcode 15.x
xcodegen --version      # 2.x
```

The two Swift Package dependencies are resolved automatically by Xcode/SwiftPM
(no manual install):

- **VLCKit** — `https://github.com/tylerjonesio/vlckit-spm` (RTSP/RTSPS playback)
- **Swifter** — `https://github.com/httpswift/swifter` (local control server)

## 2. Get the code

```bash
git clone https://github.com/reichiClaw/Unifi-Protect-Viewer.git
cd Unifi-Protect-Viewer
```

## 3. Generate the Xcode project

Either run the helper script:

```bash
./scripts/bootstrap.sh
```

…or call XcodeGen directly:

```bash
xcodegen generate
```

This creates `UnifiProtectViewer.xcodeproj` (it is git-ignored — regenerate it
any time `project.yml` changes).

## 4. Open and configure signing

```bash
open UnifiProtectViewer.xcodeproj
```

1. Select the **UnifiProtectViewer** project → **UnifiProtectViewer** target →
   **Signing & Capabilities**.
2. Pick your **Team** (a free personal Apple ID works for local runs). Xcode will
   assign a unique bundle identifier suffix if needed.
3. The target ships with the App Sandbox **off** and these capabilities, which are
   required and already configured in
   `Sources/UnifiProtectViewer/Resources/UnifiProtectViewer.entitlements`:
   - **Outgoing/Incoming Network Connections** (controller + RTSP, and the local
     control server for Stream Deck).

> VLCKit is incompatible with the App Sandbox in the default configuration, which
> is why sandboxing is disabled. The app talks only to your local controller.

## 5. Resolve packages & build

On first open, Xcode resolves the Swift packages. The VLCKit binary framework is
large, so the initial **“Resolving Package Versions”** / download step can take a
few minutes. If it seems stuck:

- **File → Packages → Reset Package Caches**, then
- **File → Packages → Resolve Package Versions**

Then build & run:

- Select the **UnifiProtectViewer** scheme and **My Mac** as the destination.
- Press **⌘R** (Run) or **⌘B** (Build only).

### Command-line build (optional)

```bash
xcodegen generate
xcodebuild -project UnifiProtectViewer.xcodeproj \
           -scheme UnifiProtectViewer \
           -destination 'platform=macOS' \
           -derivedDataPath build \
           build
```

The built app is under
`build/Build/Products/Debug/UnifiProtectViewer.app`.

## 6. First run

1. Launch the app, open **Settings** (⌘,) → **Connection**.
2. Enter your controller **host/IP**, a **local** UniFi Protect username/password
   (not a Ubiquiti cloud login).
3. **Save & Connect**. Cameras appear in the seeded **All Cameras** view.

See the main [README](../README.md) for using views/fullscreen and
[STREAMDECK.md](STREAMDECK.md) for the Stream Deck plugin.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `xcodegen: command not found` | `brew install xcodegen` |
| Package resolution hangs / fails | File → Packages → Reset Package Caches, then Resolve again. Check network access to GitHub. |
| Tiles show “Stream error — retrying…” | Enable RTSP for the camera in UniFi Protect (*Camera → Settings → Advanced → RTSP*), or enable “Auto-enable RTSP” in Settings with an admin account. |
| Login fails | Use a **local** Protect account; verify host/IP is reachable and uses the UniFi OS console address. |
| App won't open (Gatekeeper) on another Mac | For local dev, right-click → Open. For distribution you must codesign/notarize. |
| Self-signed cert errors | Expected for UniFi controllers; trust is pinned to your configured host automatically. |
| Crash on launch referencing VLCKit | Reset package caches; ensure the VLCKit (vlckit-spm) package finished downloading. |

## Notes on distribution

For sharing a `.app` with others you'll need to **codesign** and **notarize** it
with a paid Apple Developer account (`codesign --deep --options runtime` +
`xcrun notarytool`). Local development runs only need a personal team.

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

> **Adding/removing files:** the project uses Xcode 16 *synchronized folders*
> (`defaultSourceDirectoryType: syncedFolder`), so new source files pulled from
> git are included automatically — no need to regenerate. If you are on
> **Xcode 15**, change `defaultSourceDirectoryType` to `group` (and remove
> `projectFormat`) in `project.yml`, and re-run `xcodegen generate` whenever
> files are added or removed.

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

On first open, Xcode resolves the Swift packages. **VLCKit's binary framework is
~750 MB**, so the initial **“Resolving Package Versions”** / download step can
take several minutes (and needs reliable network access to GitHub).

> ### ⚠️ "Missing package product 'VLCKitSPM'" / "Missing package product 'Swifter'"
>
> These mean package resolution did not complete. SwiftPM resolves the whole
> dependency graph at once, so if the large VLCKit download fails or is
> cancelled, **both** products are reported missing. To fix:
>
> 1. Make sure you have network access and **wait for the VLCKit download to
>    finish** (watch the activity in the Xcode toolbar).
> 2. **File → Packages → Reset Package Caches**
> 3. **File → Packages → Resolve Package Versions** and let it finish.
> 4. If it still fails, quit Xcode and clear caches, then reopen:
>    ```bash
>    rm -rf ~/Library/Caches/org.swift.swiftpm
>    rm -rf ~/Library/Developer/Xcode/DerivedData/UnifiProtectViewer-*
>    rm -rf UnifiProtectViewer.xcodeproj
>    xcodegen generate && open UnifiProtectViewer.xcodeproj
>    ```
> 5. As a last resort, add the packages manually: delete the two entries under
>    `packages:`/`dependencies:` in the Xcode UI, then **File → Add Package
>    Dependencies…** and paste each URL:
>    - `https://github.com/tylerjonesio/vlckit-spm` (product **VLCKitSPM**)
>    - `https://github.com/httpswift/swifter` (product **Swifter**)
>
> Once the products resolve, the cascade of `ControlServer` errors
> (e.g. *"Enum case 'internalServerError' …"*) disappears too — those are only
> reported while the Swifter module is unresolved.

If resolution seems stuck:

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
| Black tiles / no video, or anything else misbehaving | Open the log: menu **View → Show Log** (⌘⇧L) or the log button in the sidebar. It records the resolved RTSP URLs and each player's state (PLAYING/ERROR/retry). Use **Reveal File** to open `~/Library/Application Support/UnifiProtectViewer/app.log`. |
| Login fails | Use a **local** Protect account; verify host/IP is reachable and uses the UniFi OS console address. |
| App won't open (Gatekeeper) on another Mac | For local dev, right-click → Open. For distribution you must codesign/notarize. |
| Self-signed cert errors | Expected for UniFi controllers; trust is pinned to your configured host automatically. |
| Tiles error immediately with `rtsps://…:7441` URLs | RTSPS (TLS) isn't supported by the video engine against UniFi's self-signed cert. Turn **off** "Use RTSPS" in Settings (plain RTSP on 7447). The app also auto-falls back to RTSP on failure. |
| Very high CPU / choppy video with many cameras | Each tile decodes a live stream; 4K×many is heavy. Set default quality (or a per-view quality) to **Low**/**Medium**, and keep **Hardware decoding (VideoToolbox)** on in Settings → Connection → Streaming so decode runs on dedicated silicon instead of the CPU. |
| Freezes / beachball from high **memory** use (esp. 8 GB Macs) | Decoded-frame RAM scales with resolution. Set **Grid quality = Low** (640×360) — the single biggest reduction. Keep **Hardware decoding** on so decode offloads to VideoToolbox (less CPU + lower memory pressure). The app also frees a stream's buffers when it scrolls off-screen and fully evicts players idle >60 s. Keep the buffer moderate (≈1500 ms) and prefer fewer very-high-res tiles; use Fullscreen (High) for detail on demand. |
| Green/garbled blocks or decode artifacts on some streams | Turn **Hardware decoding (VideoToolbox)** off in Settings to fall back to software decoding for that camera; then reconnect. |
| Crash on launch referencing VLCKit | Reset package caches; ensure the VLCKit (vlckit-spm) package finished downloading. |

## Notes on distribution

For sharing a `.app` with others you'll need to **codesign** and **notarize** it
with a paid Apple Developer account (`codesign --deep --options runtime` +
`xcrun notarytool`). Local development runs only need a personal team.

# Building UniFi Protect Viewer for other Macs

To run the app on Macs other than your build machine you need a **Release**
build that is **code‑signed** (and, for a smooth experience, **notarized** by
Apple). macOS Gatekeeper blocks unsigned/unnotarized apps downloaded from
elsewhere.

There are two paths depending on whether you have a paid Apple Developer
account.

---

## A. Proper distribution (recommended) — Developer ID + notarization

Requires a **paid Apple Developer Program** membership ($99/yr) and a
**Developer ID Application** certificate (create it in Xcode → Settings →
Accounts → Manage Certificates → +, or on the Apple Developer portal).

The app is configured for this: hardened runtime is on, and the entitlements
include `com.apple.security.cs.disable-library-validation` (needed so VLCKit can
load its plugin dylibs under the hardened runtime).

### 1. Generate the project and set your team

```bash
brew install xcodegen
xcodegen generate
open UnifiProtectViewer.xcodeproj
```

In Xcode → target **UnifiProtectViewer** → **Signing & Capabilities**:
- Team: your Developer ID team
- Signing Certificate: **Developer ID Application**

(You can also do everything from the command line — see the helper script
below.)

### 2. Archive

Xcode: **Product → Archive**. When it finishes, the Organizer opens.

Or CLI:
```bash
xcodebuild -project UnifiProtectViewer.xcodeproj \
           -scheme UnifiProtectViewer \
           -configuration Release \
           -archivePath build/UnifiProtectViewer.xcarchive \
           archive
```

### 3. Export a Developer ID‑signed app

Xcode Organizer: **Distribute App → Direct Distribution** (Developer ID) → it
will export and offer to notarize automatically. That's the easiest route.

Or CLI, using the included `scripts/ExportOptions.plist` (set your Team ID in
it first):
```bash
xcodebuild -exportArchive \
           -archivePath build/UnifiProtectViewer.xcarchive \
           -exportOptionsPlist scripts/ExportOptions.plist \
           -exportPath build/export
```
This produces `build/export/UnifiProtectViewer.app`.

### 4. Notarize and staple (CLI route)

First store credentials once (use an **app‑specific password** from
appleid.apple.com, not your main password):
```bash
xcrun notarytool store-credentials UPV-NOTARY \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"
```

Then notarize:
```bash
cd build/export
ditto -c -k --keepParent UnifiProtectViewer.app UnifiProtectViewer.zip
xcrun notarytool submit UnifiProtectViewer.zip --keychain-profile UPV-NOTARY --wait
xcrun stapler staple UnifiProtectViewer.app          # staple the ticket
```

`scripts/build-release.sh` automates steps 2–4 (export + notarize + staple).

### 5. Package for delivery

A `.dmg` is the nicest:
```bash
hdiutil create -volname "UniFi Protect Viewer" \
  -srcfolder build/export/UnifiProtectViewer.app \
  -ov -format UDZO build/UnifiProtectViewer.dmg
```
or just zip the stapled `.app`. Share the `.dmg`/`.zip`; users drag it to
**Applications** and it opens with no warnings.

---

## B. No Developer account (local / internal use)

You can still share the app, but recipients must bypass Gatekeeper manually.

1. Build Release and export an **ad‑hoc** signed app (Organizer → Distribute →
   *Custom* → *Copy App*, or set Signing to "Sign to Run Locally"). The included
   `scripts/ExportOptions.plist` can be switched to `"method": "mac-application"`
   /`"signingStyle": "automatic"` for a development‑signed build.
2. Zip the `.app` and send it.
3. On each recipient Mac, because it isn't notarized, the user must either:
   - **Right‑click the app → Open → Open** (first launch only), or
   - remove the quarantine attribute:
     ```bash
     xattr -dr com.apple.quarantine /Applications/UnifiProtectViewer.app
     ```

This is fine for a few known machines (e.g. your own control‑room Macs) but not
for wide distribution.

---

## Notes

- **VLCKit is bundled** inside the `.app` (the Swift Package embeds the
  xcframework), so target machines don't need VLC installed.
- The app is **not sandboxed** and talks only to your local controller; that's
  expected for a self‑hosted camera viewer.
- The **Stream Deck plugin** is distributed separately — see
  [STREAMDECK.md](STREAMDECK.md). To hand it to others, zip the
  `com.unifiprotectviewer.sdPlugin` folder (or build a `.streamDeckPlugin` with
  Elgato's DistributionTool) and they double‑click / drop it into the Stream
  Deck plugins folder.
- Minimum macOS for the app is **13.0** (set in `project.yml`).

# Plugin icons

Stream Deck expects PNG icons referenced by `manifest.json`. The plugin works
without them but the Stream Deck UI will show placeholders. Add the following
files (provide both `@1x` and `@2x` where noted):

| File | Size (1x / 2x) | Used for |
|------|----------------|----------|
| `plugin.png` / `plugin@2x.png` | 28×28 / 56×56 | Plugin icon (store / list) |
| `category.png` / `category@2x.png` | 28×28 / 56×56 | Actions category icon |
| `key.png` / `key@2x.png` | 72×72 / 144×144 | Default key image (all actions) |
| `switchView.png` / `switchView@2x.png` | 20×20 / 40×40 | Switch View action |
| `nextView.png` / `nextView@2x.png` | 20×20 / 40×40 | Next View action |
| `prevView.png` / `prevView@2x.png` | 20×20 / 40×40 | Previous View action |
| `fullscreen.png` / `fullscreen@2x.png` | 20×20 / 40×40 | Camera Fullscreen action |
| `exitFullscreen.png` / `exitFullscreen@2x.png` | 20×20 / 40×40 | Exit Fullscreen action |
| `ptz.png` / `ptz@2x.png` | 20×20 / 40×40 | PTZ: Go to Preset |
| `ptzHome.png` / `ptzHome@2x.png` | 20×20 / 40×40 | PTZ: Home |
| `ptzPatrol.png` / `ptzPatrol@2x.png` | 20×20 / 40×40 | PTZ: Start Patrol |
| `ptzStop.png` / `ptzStop@2x.png` | 20×20 / 40×40 | PTZ: Stop Patrol |

You can generate simple placeholder icons with the helper script:

```bash
cd streamdeck-plugin
./generate-placeholder-icons.sh   # requires ImageMagick (`brew install imagemagick`)
```

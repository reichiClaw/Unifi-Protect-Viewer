# Stream Deck integration

The UniFi Protect Viewer app exposes a local control server that the included
Stream Deck plugin uses to switch grid views and pop cameras fullscreen.

## 1. Enable the control server in the app

Open **Settings → Stream Deck**:

- **Enable control server** (on by default)
- **Port** — default `8723`
- **Auth token** — optional. Leave blank for an unauthenticated local server, or
  set one and enter the same value in each Stream Deck button.

Endpoints become available at `http://127.0.0.1:<port>`.

## 2. Install the plugin

The plugin lives in `streamdeck-plugin/com.unifiprotectviewer.sdPlugin`.

1. (Optional) generate placeholder icons:
   ```bash
   cd streamdeck-plugin
   ./generate-placeholder-icons.sh        # needs ImageMagick
   ```
2. Quit the Stream Deck app.
3. Copy the plugin into the Stream Deck plugins folder:
   ```bash
   cp -R streamdeck-plugin/com.unifiprotectviewer.sdPlugin \
     "$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/"
   ```
4. Relaunch the Stream Deck app. The **UniFi Protect** category appears in the
   actions list.

> For development you can instead double-click a packaged `.streamDeckPlugin`
> file produced with Elgato's
> [DistributionTool](https://docs.elgato.com/streamdeck/sdk/introduction/getting-started),
> but copying the folder is the quickest way to test.

## 3. Configure buttons

Drag an action onto a key, then in the **property inspector** set:

- **Host / Port / Token** — match your app's control-server settings
  (host is usually `127.0.0.1` if the Stream Deck and the app run on the same Mac).
- Click **Load views & cameras** to populate the dropdowns from the running app.
- For **Switch View**, choose a view (or enter an index/name).
- For **Camera Fullscreen**, choose a camera (or enter an index/name).

Button titles automatically update to show the active view / fullscreen camera.

## Actions

| Action | Effect |
|--------|--------|
| Switch View | Activate a specific grid view |
| Next View | Move to the next view |
| Previous View | Move to the previous view |
| Camera Fullscreen | Toggle a specific camera fullscreen |
| Exit Fullscreen | Return to the grid |

## Control server HTTP API

All responses are JSON `{ "ok": bool, "message": string?, "snapshot": {...} }`.
If an auth token is set, send it as the `X-Auth-Token` header, a `token` query
parameter, or a `token` field in the JSON body.

| Method | Path | Body |
|--------|------|------|
| GET | `/api/state` | — |
| GET | `/api/views` | — (alias of state) |
| GET | `/api/cameras` | — (alias of state) |
| POST | `/api/select-view` | `{ "id"?, "index"?, "name"? }` |
| POST | `/api/next-view` | — |
| POST | `/api/prev-view` | — |
| POST | `/api/fullscreen` | `{ "cameraId"?, "index"?, "name"? }` |
| POST | `/api/toggle-fullscreen` | `{ "cameraId"?, "index"?, "name"? }` |
| POST | `/api/exit-fullscreen` | — |
| POST | `/api/reconnect` | — |

`index` for `fullscreen` is relative to the **current view's** camera list, then
falls back to the global camera list.

### Snapshot shape

```json
{
  "connection": "connected",
  "currentViewID": "…", "currentViewIndex": 0, "currentViewName": "All Cameras",
  "fullscreenCameraID": null, "fullscreenCameraName": null,
  "views":   [{ "id": "…", "index": 0, "name": "All Cameras", "cameraCount": 6 }],
  "cameras": [{ "id": "…", "name": "Front Door", "online": true }]
}
```

### WebSocket

Connect to `ws://127.0.0.1:<port>/ws`. The server pushes a `ControlSnapshot`
(the `snapshot` shape above) on connect and whenever state changes. You can also
send text commands:

```json
{ "command": "next-view", "token": "…" }
{ "command": "select-view", "index": 2, "token": "…" }
{ "command": "fullscreen", "name": "Garage", "token": "…" }
{ "command": "exit-fullscreen" }
```

## Examples (curl)

```bash
# Switch to the 3rd view
curl -X POST http://127.0.0.1:8723/api/select-view -d '{"index":2}'

# Toggle the "Garage" camera fullscreen
curl -X POST http://127.0.0.1:8723/api/toggle-fullscreen -d '{"name":"Garage"}'

# With a token
curl -X POST http://127.0.0.1:8723/api/next-view -H 'X-Auth-Token: secret'
```

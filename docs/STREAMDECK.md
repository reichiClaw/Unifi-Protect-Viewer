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

## 2. Install the plugin (one click)

A ready-to-install package is included:

**`streamdeck-plugin/dist/com.unifiprotectviewer.streamDeckPlugin`**

1. Make sure the Stream Deck app is installed and running (**6.4+**).
2. **Double-click** `com.unifiprotectviewer.streamDeckPlugin`.
3. Confirm the install prompt. The **UniFi Protect Viewer** category and its
   actions appear in the Stream Deck actions list — no file copying needed.

### Rebuilding the package from source

The plugin source lives in `streamdeck-plugin/com.unifiprotectviewer.sdPlugin`.
To regenerate icons and repackage:

```bash
pip install pillow                       # once, for icon generation
python3 streamdeck-plugin/generate-icons.py
streamdeck-plugin/pack.sh                # validates + builds the .streamDeckPlugin
```

`pack.sh` uses Elgato's official [CLI](https://docs.elgato.com/streamdeck/cli/)
(`npx @elgato/cli`) to **validate** the plugin and produce the installer, falling
back to a plain zip if the CLI isn't available (the `.streamDeckPlugin` format is
a zip of the `.sdPlugin` folder). For live development you can instead link the
folder with `npx @elgato/cli link streamdeck-plugin/com.unifiprotectviewer.sdPlugin`.

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
| PTZ: Go to Preset | Move the **current fullscreen** PTZ camera to a preset slot |
| PTZ: Home | Move the current fullscreen PTZ camera to its home position |
| PTZ: Start Patrol | Start a patrol (tour) on the current fullscreen PTZ camera |
| PTZ: Stop Patrol | Stop the active patrol |

## PTZ control

The PTZ actions always target **whichever PTZ camera is currently shown
fullscreen** in the app — so a single set of PTZ buttons works for every PTZ
camera. Each PTZ action just needs the **Host/Port/Token**; *Preset* and
*Patrol* also take a **slot** number (0+ = saved presets/patrols; the *Home*
action uses the home position).

### Auto-switch to a PTZ page when a PTZ camera is fullscreen

The plugin can automatically switch your Stream Deck to a dedicated **PTZ
profile** the moment a PTZ camera goes fullscreen, and switch back when you
leave fullscreen. Because Stream Deck profiles are device-specific and must be
designed by you (preset slots map to *your* saved camera positions), this is a
one-time setup:

1. In the Stream Deck app, create a new **profile** and name it exactly
   **`UniFi Protect PTZ`**.
2. Add your PTZ buttons to it: e.g. **PTZ: Home**, several **PTZ: Go to Preset**
   (slot 0, 1, 2 …), **PTZ: Start Patrol**, **PTZ: Stop Patrol**, and an
   **Exit Fullscreen** button to leave.
3. Right-click the profile → **Export** → save `UniFi Protect PTZ.streamDeckProfile`
   into the plugin folder
   (`…/Plugins/com.unifiprotectviewer.sdPlugin/`).
4. Add it to the plugin's `manifest.json` `Profiles` array (create the array if
   missing), matching your device type (`0` = Stream Deck, `2` = XL, `7` = Plus):
   ```json
   "Profiles": [
     { "Name": "UniFi Protect PTZ", "DeviceType": 0, "Readonly": false, "DontAutoSwitchWhenInstalled": true }
   ]
   ```
5. Restart the Stream Deck app.

Now, when you make a PTZ camera fullscreen (in the app or via a **Camera
Fullscreen** button), the Stream Deck jumps to your PTZ profile; leaving
fullscreen switches back automatically.

> The PTZ **actions** work on any page even without this profile setup — the
> auto-switch is just a convenience layer on top.

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
| POST | `/api/ptz` | `{ "action": "goto"\|"home"\|"patrol-start"\|"patrol-stop", "slot"?, "cameraId"?/"index"?/"name"? }` (no camera → current fullscreen) |

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

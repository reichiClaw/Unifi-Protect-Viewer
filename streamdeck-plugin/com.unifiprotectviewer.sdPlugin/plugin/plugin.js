/* global WebSocket, fetch */
// UniFi Protect Viewer — Stream Deck plugin runtime.
//
// Connects to the Stream Deck application (registration socket) and bridges
// button presses to the viewer app's local control server. Also subscribes to
// the app's state WebSocket to keep button titles in sync with the active view
// / fullscreen camera.

let sd = null; // Stream Deck websocket
let pluginUUID = null;

// context -> { action, settings }
const buttons = new Map();

// "host:port" -> AppConnection
const appConnections = new Map();

// Connected Stream Deck device ids (for profile switching).
const devices = new Set();

// Name of the bundled profile to switch to when a PTZ camera is fullscreen.
// To enable auto-switching, create a profile with this exact name containing
// your PTZ actions, export it into the plugin folder, and add it to the
// manifest "Profiles" array (see docs/STREAMDECK.md).
const PTZ_PROFILE = "UniFi Protect PTZ";
let ptzProfileActive = false;

const ACTIONS = {
	SWITCH: "com.unifiprotectviewer.switchview",
	NEXT: "com.unifiprotectviewer.nextview",
	PREV: "com.unifiprotectviewer.prevview",
	FULLSCREEN: "com.unifiprotectviewer.fullscreen",
	EXIT: "com.unifiprotectviewer.exitfullscreen",
	PTZ_PRESET: "com.unifiprotectviewer.ptzpreset",
	PTZ_HOME: "com.unifiprotectviewer.ptzhome",
	PTZ_PATROL: "com.unifiprotectviewer.ptzpatrol",
	PTZ_STOP: "com.unifiprotectviewer.ptzstop",
	MOVE_UP: "com.unifiprotectviewer.ptzup",
	MOVE_DOWN: "com.unifiprotectviewer.ptzdown",
	MOVE_LEFT: "com.unifiprotectviewer.ptzleft",
	MOVE_RIGHT: "com.unifiprotectviewer.ptzright",
	ZOOM_IN: "com.unifiprotectviewer.ptzzoomin",
	ZOOM_OUT: "com.unifiprotectviewer.ptzzoomout",
};

// Hold-to-move actions: press moves in the given direction, release stops.
// dx = pan (+right/-left), dy = tilt (+up/-down), dz = zoom (+out/-in).
const MOVE_DIRS = {
	[ACTIONS.MOVE_UP]: { dx: 0, dy: 1, dz: 0 },
	[ACTIONS.MOVE_DOWN]: { dx: 0, dy: -1, dz: 0 },
	[ACTIONS.MOVE_LEFT]: { dx: -1, dy: 0, dz: 0 },
	[ACTIONS.MOVE_RIGHT]: { dx: 1, dy: 0, dz: 0 },
	[ACTIONS.ZOOM_IN]: { dx: 0, dy: 0, dz: -1 },
	[ACTIONS.ZOOM_OUT]: { dx: 0, dy: 0, dz: 1 },
};
const heldMoves = new Map(); // button context -> { action, settings }
const moveHeartbeats = new Map(); // connection key -> interval

function defaults(settings) {
	return {
		host: (settings && settings.host) || "127.0.0.1",
		port: (settings && settings.port) || "8723",
		token: (settings && settings.token) || "",
		viewIndex: settings && settings.viewIndex,
		viewName: settings && settings.viewName,
		cameraIndex: settings && settings.cameraIndex,
		cameraName: settings && settings.cameraName,
		slot: settings && settings.slot,
	};
}

function baseURL(s) {
	return `http://${s.host}:${s.port}`;
}

// fetch with a hard timeout so an unreachable app fails fast (button shows an
// alert) instead of hanging on the OS-level connection timeout.
function fetchWithTimeout(url, options, timeoutMs) {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), timeoutMs || 4000);
	const opts = Object.assign({}, options, { signal: controller.signal });
	return fetch(url, opts).finally(() => clearTimeout(timer));
}

// ---------------------------------------------------------------------------
// Stream Deck registration entry point.
// ---------------------------------------------------------------------------
function connectElgatoStreamDeckSocket(inPort, inPluginUUID, inRegisterEvent, inInfo) {
	pluginUUID = inPluginUUID;
	// Seed the known devices from the registration info.
	try {
		const info = JSON.parse(inInfo);
		(info.devices || []).forEach((d) => { if (d && d.id) devices.add(d.id); });
	} catch (e) { /* ignore */ }

	sd = new WebSocket(`ws://127.0.0.1:${inPort}`);

	sd.onopen = () => {
		sd.send(JSON.stringify({ event: inRegisterEvent, uuid: inPluginUUID }));
	};

	sd.onmessage = (evt) => {
		let msg;
		try { msg = JSON.parse(evt.data); } catch (e) { return; }
		handleSDMessage(msg);
	};
}
// Expose globally for Stream Deck.
window.connectElgatoStreamDeckSocket = connectElgatoStreamDeckSocket;

function handleSDMessage(msg) {
	try {
		const { event, action, context, payload } = msg;
		switch (event) {
			case "willAppear":
				buttons.set(context, { action, settings: defaults(payload && payload.settings) });
				ensureAppConnection(buttons.get(context).settings);
				refreshButton(context);
				break;
			case "willDisappear":
				releaseMove(context);
				buttons.delete(context);
				pruneConnections();
				break;
			case "didReceiveSettings":
				buttons.set(context, { action, settings: defaults(payload && payload.settings) });
				ensureAppConnection(buttons.get(context).settings);
				pruneConnections();
				refreshButton(context);
				break;
			case "keyDown":
				onKeyDown(action, context, defaults(payload && payload.settings));
				break;
			case "keyUp":
				onKeyUp(action, context, defaults(payload && payload.settings));
				break;
			case "deviceDidConnect":
				if (msg.device) devices.add(msg.device);
				break;
			case "deviceDidDisconnect":
				if (msg.device) devices.delete(msg.device);
				break;
			default:
				break;
		}
	} catch (e) {
		// Never let a malformed message take down the plugin runtime.
	}
}

// Switch to the PTZ profile when a PTZ camera is fullscreen, and back when not.
function evaluateProfileSwitch(snapshot) {
	const want = !!(snapshot && snapshot.fullscreenCameraPtz);
	if (want === ptzProfileActive) return;
	ptzProfileActive = want;
	if (!devices.size) return; // nothing to switch
	for (const device of devices) {
		send({
			event: "switchToProfile",
			context: pluginUUID,
			device,
			// Empty payload returns to the previously selected profile.
			payload: want ? { profile: PTZ_PROFILE } : {},
		});
	}
}

// ---------------------------------------------------------------------------
// Button presses -> app control server.
// ---------------------------------------------------------------------------
async function onKeyDown(action, context, s) {
	// Hold-to-move actions: start moving in the given direction on press.
	if (MOVE_DIRS[action]) {
		heldMoves.set(context, { action, settings: s });
		await sendCombinedMove(context, s);
		ensureMoveHeartbeat(s);
		return;
	}
	let path = null;
	let body = {};
	switch (action) {
		case ACTIONS.SWITCH:
			path = "/api/select-view";
			body = identifierForView(s);
			break;
		case ACTIONS.NEXT:
			path = "/api/next-view";
			break;
		case ACTIONS.PREV:
			path = "/api/prev-view";
			break;
		case ACTIONS.FULLSCREEN:
			path = "/api/toggle-fullscreen";
			body = identifierForCamera(s);
			break;
		case ACTIONS.EXIT:
			path = "/api/exit-fullscreen";
			break;
		case ACTIONS.PTZ_PRESET:
			path = "/api/ptz";
			body = { action: "goto", slot: parseInt(s.slot || "0", 10) };
			break;
		case ACTIONS.PTZ_HOME:
			path = "/api/ptz";
			body = { action: "home" };
			break;
		case ACTIONS.PTZ_PATROL:
			path = "/api/ptz";
			body = { action: "patrol-start", slot: parseInt(s.slot || "0", 10) };
			break;
		case ACTIONS.PTZ_STOP:
			path = "/api/ptz";
			body = { action: "patrol-stop" };
			break;
		default:
			return;
	}
	if (s.token) body.token = s.token;

	try {
		const res = await fetchWithTimeout(baseURL(s) + path, {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Auth-Token": s.token || "" },
			body: JSON.stringify(body),
		}, 4000);
		const data = await res.json().catch(() => ({}));
		if (res.ok && data.ok !== false) {
			showOk(context);
			if (data.snapshot) applySnapshot(s, data.snapshot);
		} else {
			showAlert(context);
		}
	} catch (e) {
		showAlert(context);
	}
}

// Stop continuous movement when a hold-to-move key is released.
async function onKeyUp(action, context, s) {
	if (MOVE_DIRS[action]) {
		heldMoves.delete(context);
		await sendCombinedMove(context, s);
		updateMoveHeartbeat(s);
	}
}

function moveKey(s) { return `${s.host}:${s.port}:${s.token || ""}`; }

function combinedMove(s) {
	const key = moveKey(s);
	const result = { dx: 0, dy: 0, dz: 0 };
	for (const [, held] of heldMoves) {
		if (moveKey(held.settings) !== key) continue;
		const d = MOVE_DIRS[held.action];
		if (!d) continue;
		result.dx += d.dx;
		result.dy += d.dy;
		result.dz += d.dz;
	}
	result.dx = Math.sign(result.dx);
	result.dy = Math.sign(result.dy);
	result.dz = Math.sign(result.dz);
	return result;
}

function firstHeldFor(s) {
	const key = moveKey(s);
	for (const [context, held] of heldMoves) {
		if (moveKey(held.settings) === key) return { context, settings: held.settings };
	}
	return null;
}

async function sendCombinedMove(context, s) {
	await postMove(context, s, combinedMove(s));
}

function ensureMoveHeartbeat(s) {
	const key = moveKey(s);
	if (moveHeartbeats.has(key)) return;
	const timer = setInterval(() => {
		const held = firstHeldFor(s);
		if (held) postMove(held.context, held.settings, combinedMove(held.settings));
		else updateMoveHeartbeat(s);
	}, 750);
	moveHeartbeats.set(key, timer);
}

function updateMoveHeartbeat(s) {
	const key = moveKey(s);
	if (firstHeldFor(s)) return;
	const timer = moveHeartbeats.get(key);
	if (timer) clearInterval(timer);
	moveHeartbeats.delete(key);
}

function releaseMove(context) {
	const held = heldMoves.get(context);
	if (!held) return;
	heldMoves.delete(context);
	sendCombinedMove(context, held.settings);
	updateMoveHeartbeat(held.settings);
}

// Send a continuous-move command (dx/dy/dz; all zero = stop) to the app.
async function postMove(context, s, body) {
	if (s.token) body.token = s.token;
	try {
		const res = await fetchWithTimeout(baseURL(s) + "/api/ptz-move", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Auth-Token": s.token || "" },
			body: JSON.stringify(body),
		}, 4000);
		const data = await res.json().catch(() => ({}));
		if (!res.ok || data.ok === false) showAlert(context);
	} catch (e) {
		showAlert(context);
	}
}

function identifierForView(s) {
	if (s.viewName) return { name: s.viewName };
	if (s.viewIndex !== undefined && s.viewIndex !== "") return { index: parseInt(s.viewIndex, 10) };
	return {};
}

function identifierForCamera(s) {
	if (s.cameraName) return { name: s.cameraName };
	if (s.cameraIndex !== undefined && s.cameraIndex !== "") return { index: parseInt(s.cameraIndex, 10) };
	return {};
}

// ---------------------------------------------------------------------------
// App state WebSocket (keeps titles in sync).
// ---------------------------------------------------------------------------
function connKey(s) { return `${s.host}:${s.port}`; }

function ensureAppConnection(s) {
	const key = connKey(s);
	if (appConnections.has(key)) return;
	const conn = new AppConnection(s);
	appConnections.set(key, conn);
	conn.connect();
}

// Close and forget any app connection no longer referenced by a button, so we
// don't keep a socket (and reconnect loop) alive for a host/port nobody uses.
function pruneConnections() {
	const inUse = new Set();
	for (const [, info] of buttons) inUse.add(connKey(info.settings));
	for (const [key, conn] of appConnections) {
		if (!inUse.has(key)) {
			conn.close();
			appConnections.delete(key);
		}
	}
}

class AppConnection {
	constructor(settings) {
		this.settings = settings;
		this.ws = null;
		this.snapshot = null;
		this.reconnectTimer = null;
		this.closed = false;
	}
	connect() {
		if (this.closed) return;
		const auth = this.settings.token ? `?token=${encodeURIComponent(this.settings.token)}` : "";
		const url = `ws://${this.settings.host}:${this.settings.port}/ws${auth}`;
		try {
			this.ws = new WebSocket(url);
		} catch (e) {
			this.scheduleReconnect();
			return;
		}
		this.ws.onmessage = (evt) => {
			try {
				const snap = JSON.parse(evt.data);
				this.snapshot = snap;
				broadcastSnapshot(connKey(this.settings), snap);
				evaluateProfileSwitch(snap);
			} catch (e) { /* ignore */ }
		};
		this.ws.onclose = () => this.scheduleReconnect();
		this.ws.onerror = () => { try { this.ws.close(); } catch (e) {} };
	}
	scheduleReconnect() {
		if (this.closed || this.reconnectTimer) return;
		this.reconnectTimer = setTimeout(() => {
			this.reconnectTimer = null;
			this.connect();
		}, 3000);
	}
	close() {
		this.closed = true;
		if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
		if (this.ws) {
			try { this.ws.onclose = null; this.ws.close(); } catch (e) { /* ignore */ }
			this.ws = null;
		}
	}
}

function broadcastSnapshot(key, snapshot) {
	for (const [context, info] of buttons) {
		if (connKey(info.settings) === key) {
			applySnapshotToButton(context, info, snapshot);
		}
	}
}

function applySnapshot(settings, snapshot) {
	const conn = appConnections.get(connKey(settings));
	if (conn) conn.snapshot = snapshot;
	broadcastSnapshot(connKey(settings), snapshot);
}

// ---------------------------------------------------------------------------
// Title / state rendering.
// ---------------------------------------------------------------------------
function refreshButton(context) {
	const info = buttons.get(context);
	if (!info) return;
	const conn = appConnections.get(connKey(info.settings));
	const snap = conn ? conn.snapshot : null;
	applySnapshotToButton(context, info, snap);
}

function applySnapshotToButton(context, info, snapshot) {
	const s = info.settings;
	let title = "";
	let active = false;

	switch (info.action) {
		case ACTIONS.SWITCH: {
			title = s.viewName || (s.viewIndex !== undefined ? `View ${s.viewIndex}` : "View");
			if (snapshot) {
				active = matchView(snapshot, s);
				if (snapshot.views && s.viewIndex !== undefined && !s.viewName) {
					const v = snapshot.views[parseInt(s.viewIndex, 10)];
					if (v) title = v.name;
				}
			}
			break;
		}
		case ACTIONS.FULLSCREEN: {
			title = s.cameraName || (s.cameraIndex !== undefined ? `Cam ${s.cameraIndex}` : "Camera");
			if (snapshot) active = matchCamera(snapshot, s);
			break;
		}
		case ACTIONS.NEXT: title = snapshot && snapshot.currentViewName ? `▶ ${snapshot.currentViewName}` : "Next"; break;
		case ACTIONS.PREV: title = "Prev"; break;
		case ACTIONS.EXIT: title = "Grid"; break;
		default: break;
	}

	if (active) title = `● ${title}`;
	setTitle(context, title);
}

function matchView(snapshot, s) {
	if (s.viewName && snapshot.currentViewName) {
		return s.viewName.toLowerCase() === snapshot.currentViewName.toLowerCase();
	}
	if (s.viewIndex !== undefined && s.viewIndex !== "") {
		return parseInt(s.viewIndex, 10) === snapshot.currentViewIndex;
	}
	return false;
}

function matchCamera(snapshot, s) {
	if (!snapshot.fullscreenCameraID && !snapshot.fullscreenCameraName) return false;
	if (s.cameraName && snapshot.fullscreenCameraName) {
		return s.cameraName.toLowerCase() === snapshot.fullscreenCameraName.toLowerCase();
	}
	if (s.cameraIndex !== undefined && s.cameraIndex !== "" && snapshot.cameras) {
		const cam = snapshot.cameras[parseInt(s.cameraIndex, 10)];
		return cam && cam.id === snapshot.fullscreenCameraID;
	}
	return false;
}

// ---------------------------------------------------------------------------
// Stream Deck send helpers.
// ---------------------------------------------------------------------------
function setTitle(context, title) {
	send({ event: "setTitle", context, payload: { title: title || "", target: 0 } });
}
function showOk(context) { send({ event: "showOk", context }); }
function showAlert(context) { send({ event: "showAlert", context }); }
function send(obj) {
	if (sd && sd.readyState === 1) sd.send(JSON.stringify(obj));
}

/* global WebSocket, fetch */
// Property inspector for all UniFi Protect Viewer actions.

let sd = null;
let uuid = null;
let actionType = null;
let settings = {};
let appWS = null;
let appWSReconnect = null;

const VIEW_ACTIONS = new Set([
	"com.unifiprotectviewer.switchview",
	"com.unifiprotectviewer.nextview",
	"com.unifiprotectviewer.prevview",
	"com.unifiprotectviewer.exitfullscreen",
]);
const SWITCH_ACTION = "com.unifiprotectviewer.switchview";
const FULLSCREEN_ACTION = "com.unifiprotectviewer.fullscreen";
const PTZ_SLOT_ACTIONS = new Set([
	"com.unifiprotectviewer.ptzpreset",
	"com.unifiprotectviewer.ptzpatrol",
]);

function connectElgatoStreamDeckSocket(inPort, inUUID, inRegisterEvent, _inInfo, inActionInfo) {
	uuid = inUUID;
	try {
		const actionInfo = JSON.parse(inActionInfo);
		actionType = actionInfo.action;
		settings = (actionInfo.payload && actionInfo.payload.settings) || {};
	} catch (e) {
		settings = {};
	}

	sd = new WebSocket(`ws://127.0.0.1:${inPort}`);
	sd.onopen = () => {
		sdSend({ event: inRegisterEvent, uuid: inUUID });
		initUI();
	};
	sd.onmessage = (evt) => {
		let msg;
		try { msg = JSON.parse(evt.data); } catch (e) { return; }
		if (msg.event === "didReceiveSettings") {
			settings = (msg.payload && msg.payload.settings) || {};
			fillUI();
		}
	};
}
window.connectElgatoStreamDeckSocket = connectElgatoStreamDeckSocket;

function el(id) { return document.getElementById(id); }

function sdSend(obj) {
	if (sd && sd.readyState === 1) sd.send(JSON.stringify(obj));
}

function fetchWithTimeout(url, options, timeoutMs) {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), timeoutMs || 4000);
	const opts = Object.assign({}, options || {}, { signal: controller.signal });
	return fetch(url, opts).finally(() => clearTimeout(timer));
}

function initUI() {
	// Show only the relevant action-specific group.
	if (actionType === SWITCH_ACTION) el("view-group").hidden = false;
	if (actionType === FULLSCREEN_ACTION) el("camera-group").hidden = false;
	if (PTZ_SLOT_ACTIONS.has(actionType)) el("ptz-group").hidden = false;
	if (!actionType || (!VIEW_ACTIONS.has(actionType) && actionType !== FULLSCREEN_ACTION)) {
		// generic
	}

	fillUI();

	["host", "port", "token", "viewIndex", "viewName", "cameraIndex", "cameraName", "slot"]
		.forEach((id) => {
			const node = el(id);
			if (node) node.addEventListener("input", persist);
		});
	el("viewSelect").addEventListener("change", () => {
		const opt = el("viewSelect").value;
		if (opt !== "") {
			el("viewName").value = "";
			el("viewIndex").value = opt;
			persist();
		}
	});
	el("cameraSelect").addEventListener("change", () => {
		const opt = el("cameraSelect").value;
		if (opt !== "") {
			el("cameraIndex").value = "";
			el("cameraName").value = opt;
			persist();
		}
	});
	el("refresh").addEventListener("click", () => { loadState(); connectAppWS(); });

	// Reconnect the live feed if the host/port changes.
	["host", "port"].forEach((id) => {
		const node = el(id);
		if (node) node.addEventListener("change", connectAppWS);
	});

	// Auto-load once, and also subscribe to the app's WebSocket so the lists
	// populate (and stay current) as soon as the app has cameras — regardless
	// of whether the app had finished connecting when this inspector opened.
	loadState();
	connectAppWS();
}

// Live updates from the app: the control server pushes a full snapshot on
// connect and whenever state changes. WebSockets aren't CORS-restricted, so
// this works even when a one-shot fetch would race the app's startup.
function connectAppWS() {
	const host = el("host").value || "127.0.0.1";
	const port = el("port").value || "8723";
	if (appWSReconnect) { clearTimeout(appWSReconnect); appWSReconnect = null; }
	if (appWS) { try { appWS.close(); } catch (e) { /* ignore */ } appWS = null; }
	try {
		appWS = new WebSocket(`ws://${host}:${port}/ws`);
	} catch (e) {
		return;
	}
	appWS.onmessage = (evt) => {
		let snap;
		try { snap = JSON.parse(evt.data); } catch (e) { return; }
		// The /ws feed sends the raw snapshot (no { snapshot: … } wrapper).
		if (snap.views) populateViews(snap.views);
		if (snap.cameras) populateCameras(snap.cameras);
		setStatus(`Loaded ${snap.views ? snap.views.length : 0} views, ${snap.cameras ? snap.cameras.length : 0} cameras.`);
	};
	appWS.onclose = () => {
		// Auto-reconnect so the lists recover if the app restarts.
		if (!appWSReconnect) appWSReconnect = setTimeout(connectAppWS, 3000);
	};
	appWS.onerror = () => { try { appWS.close(); } catch (e) { /* ignore */ } };
}

function fillUI() {
	el("host").value = settings.host || "127.0.0.1";
	el("port").value = settings.port || "8723";
	el("token").value = settings.token || "";
	el("viewIndex").value = settings.viewIndex || "";
	el("viewName").value = settings.viewName || "";
	el("cameraIndex").value = settings.cameraIndex || "";
	el("cameraName").value = settings.cameraName || "";
	el("slot").value = settings.slot || "";
}

function persist() {
	settings = {
		host: el("host").value || "127.0.0.1",
		port: el("port").value || "8723",
		token: el("token").value || "",
		viewIndex: el("viewIndex").value,
		viewName: el("viewName").value,
		cameraIndex: el("cameraIndex").value,
		cameraName: el("cameraName").value,
		slot: el("slot").value,
	};
	sdSend({ event: "setSettings", context: uuid, payload: settings });
}

async function loadState() {
	const host = el("host").value || "127.0.0.1";
	const port = el("port").value || "8723";
	const token = el("token").value || "";
	setStatus("Loading…");
	try {
		const res = await fetchWithTimeout(`http://${host}:${port}/api/state`, {
			headers: { "X-Auth-Token": token },
		}, 4000);
		const data = await res.json();
		const snap = data.snapshot || data;
		populateViews(snap.views || []);
		populateCameras(snap.cameras || []);
		setStatus(`Loaded ${snap.views ? snap.views.length : 0} views, ${snap.cameras ? snap.cameras.length : 0} cameras.`);
	} catch (e) {
		setStatus("Could not reach the app. Is it running and the control server enabled?");
	}
}

function populateViews(views) {
	const sel = el("viewSelect");
	sel.innerHTML = '<option value="">— choose —</option>';
	views.forEach((v) => {
		const o = document.createElement("option");
		o.value = String(v.index);
		o.textContent = `${v.index}: ${v.name}`;
		sel.appendChild(o);
	});
	if (settings.viewIndex !== undefined) sel.value = String(settings.viewIndex);
}

function populateCameras(cameras) {
	const sel = el("cameraSelect");
	sel.innerHTML = '<option value="">— choose —</option>';
	cameras.forEach((c) => {
		const o = document.createElement("option");
		o.value = c.name;
		o.textContent = c.name + (c.online ? "" : " (offline)");
		sel.appendChild(o);
	});
	if (settings.cameraName) sel.value = settings.cameraName;
}

function setStatus(text) { el("status").textContent = text; }

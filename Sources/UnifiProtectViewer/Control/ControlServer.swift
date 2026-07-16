import Foundation
import Swifter

/// Local HTTP + WebSocket server that lets external tools (the Stream Deck
/// plugin) drive the app: switch grid views and pop cameras fullscreen.
///
/// HTTP endpoints (all return JSON `ControlResult`):
///   GET  /api/state
///   GET  /api/views
///   GET  /api/cameras
///   POST /api/select-view        { "id": ..., "index": ..., "name": ... }
///   POST /api/next-view
///   POST /api/prev-view
///   POST /api/fullscreen         { "cameraId": ..., "index": ..., "name": ... }
///   POST /api/toggle-fullscreen  { "cameraId": ..., "index": ..., "name": ... }
///   POST /api/exit-fullscreen
///   POST /api/reconnect
///
/// WebSocket endpoint `/ws` pushes a `ControlSnapshot` whenever state changes,
/// so the Stream Deck can keep its button titles/state in sync.
final class ControlServer {
    private let server = HttpServer()
    private weak var handler: ControlServerHandler?
    private var token: String = ""
    private var isRunning = false
    private var port: UInt16 = 8723
    private var allowLAN = false
    private let stateLock = NSLock()

    private let socketsLock = NSLock()
    private var sockets: [WebSocketSession] = []
    private let rateLock = NSLock()
    private var requestTimes: [String: [Date]] = [:]
    /// Snapshot writes happen here, never on the main thread — a slow or
    /// half-dead Stream Deck client must not be able to block the UI.
    private let broadcastQueue = DispatchQueue(label: "com.unifiprotectviewer.control.broadcast")

    init(handler: ControlServerHandler) {
        self.handler = handler
        configureRoutes()
    }

    func start(port: UInt16, token: String, allowLAN: Bool) {
        if allowLAN && token.isEmpty {
            appLog("ControlServer: refusing LAN access without an auth token", .error)
            return
        }
        let existing = stateSnapshot()
        if existing.running {
            // Already running with the same configuration: nothing to do.
            if port == existing.port && token == existing.token && allowLAN == existing.allowLAN {
                return
            }
            // Configuration changed: stop and restart below.
            stop()
        }
        stateLock.lock()
        self.port = port
        self.token = token
        self.allowLAN = allowLAN
        stateLock.unlock()
        server.listenAddressIPv4 = allowLAN ? "0.0.0.0" : "127.0.0.1"
        do {
            try server.start(port, forceIPv4: true)
            stateLock.lock(); isRunning = true; stateLock.unlock()
            appLog("ControlServer: listening on \(allowLAN ? "LAN" : "127.0.0.1"):\(port) (auth \(token.isEmpty ? "off" : "on"))")
        } catch {
            stateLock.lock(); isRunning = false; stateLock.unlock()
            appLog("ControlServer: failed to start on port \(port): \(error)", .error)
        }
    }

    func stop() {
        guard stateSnapshot().running else { return }
        server.stop()
        stateLock.lock(); isRunning = false; stateLock.unlock()
        socketsLock.lock(); sockets.removeAll(); socketsLock.unlock()
    }

    /// Push the latest snapshot to all connected WebSocket clients.
    ///
    /// Often called from the main thread (via `AppState.broadcastSnapshot`), so
    /// the actual socket writes are dispatched to a background queue: a slow or
    /// stuck client can otherwise block the writer, and blocking the main thread
    /// would beachball the whole UI.
    func broadcast(snapshot: ControlSnapshot) {
        guard stateSnapshot().running else { return }
        guard let text = encodeToString(snapshot) else { return }
        socketsLock.lock()
        let current = sockets
        socketsLock.unlock()
        guard !current.isEmpty else { return }
        broadcastQueue.async {
            for socket in current {
                socket.writeText(text)
            }
        }
    }

    // MARK: - Routes

    private func configureRoutes() {
        // Answer CORS preflight (OPTIONS) for every route so the Stream Deck
        // plugin webview can call us.
        server.middleware.append { request in
            guard request.method == "OPTIONS" else { return nil }
            return .raw(204, "No Content", ControlServer.corsHeaders, nil)
        }

        server["/api/state"] = { [weak self] req in self?.handleGetState(req) ?? .internalServerError }
        server["/api/views"] = { [weak self] req in self?.handleGetState(req) ?? .internalServerError }
        server["/api/cameras"] = { [weak self] req in self?.handleGetState(req) ?? .internalServerError }

        server.POST["/api/select-view"] = { [weak self] req in self?.handleSelectView(req) ?? .internalServerError }
        server.POST["/api/next-view"] = { [weak self] req in self?.handleSimple(req) { $0.controlNextView() } ?? .internalServerError }
        server.POST["/api/prev-view"] = { [weak self] req in self?.handleSimple(req) { $0.controlPreviousView() } ?? .internalServerError }
        server.POST["/api/fullscreen"] = { [weak self] req in self?.handleFullscreen(req, toggle: false) ?? .internalServerError }
        server.POST["/api/toggle-fullscreen"] = { [weak self] req in self?.handleFullscreen(req, toggle: true) ?? .internalServerError }
        server.POST["/api/exit-fullscreen"] = { [weak self] req in self?.handleSimple(req) { $0.controlExitFullscreen() } ?? .internalServerError }
        server.POST["/api/reconnect"] = { [weak self] req in self?.handleSimple(req) { $0.controlReconnect() } ?? .internalServerError }
        server.POST["/api/ptz"] = { [weak self] req in self?.handlePTZ(req) ?? .internalServerError }
        server.POST["/api/ptz-move"] = { [weak self] req in self?.handlePTZMove(req) ?? .internalServerError }

        let websocketHandler = websocket(
            text: { [weak self] session, text in
                // Allow simple text commands too, e.g. "next-view".
                self?.handleSocketText(session, text)
            },
            connected: { [weak self] session in
                guard let self = self else { return }
                self.socketsLock.lock(); self.sockets.append(session); self.socketsLock.unlock()
                if let snapshot = self.snapshotSync() {
                    if let text = self.encodeToString(snapshot) { session.writeText(text) }
                }
            },
            disconnected: { [weak self] session in
                guard let self = self else { return }
                self.socketsLock.lock()
                self.sockets.removeAll { $0 === session }
                self.socketsLock.unlock()
            }
        )
        // A token-protected server must authenticate the WebSocket upgrade
        // before registering the client or exposing the initial snapshot.
        server["/ws"] = { [weak self] request in
            guard let self = self else { return .internalServerError }
            guard self.authorize(request) else { return self.unauthorized() }
            return websocketHandler(request)
        }
    }

    // MARK: - Handlers

    private func handleGetState(_ req: HttpRequest) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
        guard allowRequest("state", limit: 30, per: 1) else { return tooManyRequests() }
        guard let snapshot = snapshotSync() else { return .internalServerError }
        return jsonResult(ControlResult(ok: true, message: nil, snapshot: snapshot))
    }

    private func handleSelectView(_ req: HttpRequest) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
        guard allowRequest("view", limit: 20, per: 1) else { return tooManyRequests() }
        let params = parseParams(req)
        let id = params["id"] as? String
        let index = intParam(params["index"])
        let name = params["name"] as? String
        let ok = DispatchQueue.main.sync { [weak self] () -> Bool in
            guard let handler = self?.handler else { return false }
            return handler.controlSelectView(id: id, index: index, name: name)
        }
        return finish(ok: ok, message: ok ? nil : "View not found")
    }

    private func handleFullscreen(_ req: HttpRequest, toggle: Bool) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
        guard allowRequest("fullscreen", limit: 20, per: 1) else { return tooManyRequests() }
        let params = parseParams(req)
        let cameraId = (params["cameraId"] as? String) ?? (params["cameraID"] as? String)
        let index = intParam(params["index"])
        let name = params["name"] as? String
        let ok = DispatchQueue.main.sync { [weak self] () -> Bool in
            guard let handler = self?.handler else { return false }
            if toggle {
                return handler.controlToggleFullscreen(cameraID: cameraId, index: index, name: name)
            } else {
                return handler.controlShowFullscreen(cameraID: cameraId, index: index, name: name)
            }
        }
        return finish(ok: ok, message: ok ? nil : "Camera not found")
    }

    private func handlePTZ(_ req: HttpRequest) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
        guard allowRequest("ptz", limit: 20, per: 1) else { return tooManyRequests() }
        let params = parseParams(req)
        let cameraId = (params["cameraId"] as? String) ?? (params["cameraID"] as? String)
        let index = intParam(params["index"])
        let name = params["name"] as? String
        let action = (params["action"] as? String) ?? "goto"
        let slot = intParam(params["slot"]) ?? 0
        let ok = DispatchQueue.main.sync { [weak self] () -> Bool in
            guard let handler = self?.handler else { return false }
            return handler.controlPTZ(cameraID: cameraId, index: index, name: name, action: action, slot: slot)
        }
        return finish(ok: ok, message: ok ? nil : "Camera not found")
    }

    private func handlePTZMove(_ req: HttpRequest) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
        guard allowRequest("ptz-move", limit: 30, per: 1) else { return tooManyRequests() }
        let params = parseParams(req)
        let cameraId = (params["cameraId"] as? String) ?? (params["cameraID"] as? String)
        let index = intParam(params["index"])
        let name = params["name"] as? String
        let dx = intParam(params["dx"]) ?? 0
        let dy = intParam(params["dy"]) ?? 0
        let dz = intParam(params["dz"]) ?? 0
        let ok = DispatchQueue.main.sync { [weak self] () -> Bool in
            guard let handler = self?.handler else { return false }
            return handler.controlPTZMove(cameraID: cameraId, index: index, name: name, dx: dx, dy: dy, dz: dz)
        }
        return finish(ok: ok, message: ok ? nil : "Camera not found")
    }

    private func handleSimple(_ req: HttpRequest, _ action: @escaping (ControlServerHandler) -> Void) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
        let isReconnect = req.path == "/api/reconnect"
        guard allowRequest(isReconnect ? "reconnect" : "simple",
                           limit: isReconnect ? 1 : 20,
                           per: isReconnect ? 5 : 1) else { return tooManyRequests() }
        DispatchQueue.main.sync { [weak self] in
            guard let handler = self?.handler else { return }
            action(handler)
        }
        return finish(ok: true, message: nil)
    }

    private func handleSocketText(_ session: WebSocketSession, _ text: String) {
        // Token check for socket commands when a token is configured.
        var command = text
        var providedToken: String? = nil
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            command = (obj["command"] as? String) ?? ""
            providedToken = obj["token"] as? String
            guard tokenMatches(providedToken) else { return }
            if command == "select-view" {
                let id = obj["id"] as? String
                let index = intParam(obj["index"])
                let name = obj["name"] as? String
                _ = DispatchQueue.main.sync { self.handler?.controlSelectView(id: id, index: index, name: name) }
                pushSnapshot()
                return
            }
            if command == "fullscreen" || command == "toggle-fullscreen" {
                let cameraId = (obj["cameraId"] as? String) ?? (obj["cameraID"] as? String)
                let index = intParam(obj["index"])
                let name = obj["name"] as? String
                let toggle = command == "toggle-fullscreen"
                _ = DispatchQueue.main.sync {
                    toggle ? self.handler?.controlToggleFullscreen(cameraID: cameraId, index: index, name: name)
                           : self.handler?.controlShowFullscreen(cameraID: cameraId, index: index, name: name)
                }
                pushSnapshot()
                return
            }
        }
        guard tokenMatches(providedToken) else { return }
        switch command {
        case "next-view": DispatchQueue.main.sync { self.handler?.controlNextView() }
        case "prev-view": DispatchQueue.main.sync { self.handler?.controlPreviousView() }
        case "exit-fullscreen": DispatchQueue.main.sync { self.handler?.controlExitFullscreen() }
        case "reconnect": DispatchQueue.main.sync { self.handler?.controlReconnect() }
        case "state": break
        default: break
        }
        pushSnapshot()
    }

    private func pushSnapshot() {
        if let snapshot = snapshotSync() { broadcast(snapshot: snapshot) }
    }

    // MARK: - Utilities

    private func finish(ok: Bool, message: String?) -> HttpResponse {
        let snapshot = snapshotSync()
        if let snapshot = snapshot { broadcast(snapshot: snapshot) }
        return jsonResult(ControlResult(ok: ok, message: message, snapshot: snapshot))
    }

    private func snapshotSync() -> ControlSnapshot? {
        DispatchQueue.main.sync { [weak self] in self?.handler?.controlSnapshot() }
    }

    private func authorize(_ req: HttpRequest) -> Bool {
        guard !stateSnapshot().token.isEmpty else { return true }
        if tokenMatches(req.headers["x-auth-token"]) { return true }
        if tokenMatches(req.queryParams.first(where: { $0.0 == "token" })?.1) { return true }
        // Also accept token in JSON body.
        if let obj = bodyJSON(req), tokenMatches(obj["token"] as? String) { return true }
        return false
    }

    /// Compare secrets without an early-out on the first differing byte.
    private func tokenMatches(_ candidate: String?) -> Bool {
        let expected = stateSnapshot().token
        if expected.isEmpty { return true }
        guard let candidate = candidate else { return false }
        let a = Array(expected.utf8)
        let b = Array(candidate.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    private func stateSnapshot() -> (running: Bool, port: UInt16, token: String, allowLAN: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (isRunning, port, token, allowLAN)
    }

    /// Small global token bucket per operation. This is intentionally simple:
    /// the server normally binds only to loopback, and LAN mode requires auth.
    private func allowRequest(_ key: String, limit: Int, per seconds: TimeInterval) -> Bool {
        let now = Date()
        rateLock.lock()
        defer { rateLock.unlock() }
        let recent = (requestTimes[key] ?? []).filter { now.timeIntervalSince($0) < seconds }
        guard recent.count < limit else {
            requestTimes[key] = recent
            return false
        }
        requestTimes[key] = recent + [now]
        return true
    }

    private func parseParams(_ req: HttpRequest) -> [String: Any] {
        var result = bodyJSON(req) ?? [:]
        for (k, v) in req.queryParams where result[k] == nil {
            result[k] = v
        }
        return result
    }

    private func bodyJSON(_ req: HttpRequest) -> [String: Any]? {
        let data = Data(req.body)
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func intParam(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    private func encodeToString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func jsonResult<T: Encodable>(_ value: T) -> HttpResponse {
        guard let data = try? JSONEncoder().encode(value) else { return .internalServerError }
        var headers = ControlServer.corsHeaders
        headers["Content-Type"] = "application/json"
        return .raw(200, "OK", headers) { writer in
            try writer.write(data)
        }
    }

    private func unauthorized() -> HttpResponse {
        var headers = ControlServer.corsHeaders
        headers["Content-Type"] = "application/json"
        return .raw(401, "Unauthorized", headers) { writer in
            try writer.write(Data("{\"ok\":false,\"message\":\"Unauthorized\"}".utf8))
        }
    }

    private func tooManyRequests() -> HttpResponse {
        var headers = ControlServer.corsHeaders
        headers["Content-Type"] = "application/json"
        headers["Retry-After"] = "1"
        return .raw(429, "Too Many Requests", headers) { writer in
            try writer.write(Data("{\"ok\":false,\"message\":\"Too many requests\"}".utf8))
        }
    }

    /// CORS headers so the Stream Deck plugin's webview `fetch()` calls are
    /// allowed (they're cross-origin from the plugin's point of view).
    static let corsHeaders: [String: String] = [
        // Stream Deck property inspectors run from an opaque local-file origin.
        "Access-Control-Allow-Origin": "null",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, X-Auth-Token",
        "Access-Control-Max-Age": "86400"
    ]
}

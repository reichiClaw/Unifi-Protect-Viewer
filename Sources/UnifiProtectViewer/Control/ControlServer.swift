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
    private(set) var isRunning = false
    private var port: UInt16 = 8723

    private let socketsLock = NSLock()
    private var sockets: [WebSocketSession] = []

    init(handler: ControlServerHandler) {
        self.handler = handler
        configureRoutes()
    }

    func start(port: UInt16, token: String) {
        guard !isRunning else {
            if port != self.port || token != self.token {
                stop()
            } else {
                return
            }
        }
        self.port = port
        self.token = token
        do {
            try server.start(port, forceIPv4: true)
            isRunning = true
            NSLog("ControlServer: listening on port \(port)")
        } catch {
            isRunning = false
            NSLog("ControlServer: failed to start on port \(port): \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        server.stop()
        isRunning = false
        socketsLock.lock(); sockets.removeAll(); socketsLock.unlock()
    }

    /// Push the latest snapshot to all connected WebSocket clients.
    func broadcast(snapshot: ControlSnapshot) {
        guard isRunning else { return }
        guard let text = encodeToString(snapshot) else { return }
        socketsLock.lock()
        let current = sockets
        socketsLock.unlock()
        for socket in current {
            socket.writeText(text)
        }
    }

    // MARK: - Routes

    private func configureRoutes() {
        server["/api/state"] = { [weak self] req in self?.handleGetState(req) ?? .internalServerError(nil) }
        server["/api/views"] = { [weak self] req in self?.handleGetState(req) ?? .internalServerError(nil) }
        server["/api/cameras"] = { [weak self] req in self?.handleGetState(req) ?? .internalServerError(nil) }

        server.POST["/api/select-view"] = { [weak self] req in self?.handleSelectView(req) ?? .internalServerError(nil) }
        server.POST["/api/next-view"] = { [weak self] req in self?.handleSimple(req) { $0.controlNextView() } ?? .internalServerError(nil) }
        server.POST["/api/prev-view"] = { [weak self] req in self?.handleSimple(req) { $0.controlPreviousView() } ?? .internalServerError(nil) }
        server.POST["/api/fullscreen"] = { [weak self] req in self?.handleFullscreen(req, toggle: false) ?? .internalServerError(nil) }
        server.POST["/api/toggle-fullscreen"] = { [weak self] req in self?.handleFullscreen(req, toggle: true) ?? .internalServerError(nil) }
        server.POST["/api/exit-fullscreen"] = { [weak self] req in self?.handleSimple(req) { $0.controlExitFullscreen() } ?? .internalServerError(nil) }
        server.POST["/api/reconnect"] = { [weak self] req in self?.handleSimple(req) { $0.controlReconnect() } ?? .internalServerError(nil) }

        server["/ws"] = websocket(
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
    }

    // MARK: - Handlers

    private func handleGetState(_ req: HttpRequest) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
        guard let snapshot = snapshotSync() else { return .internalServerError(nil) }
        return jsonResult(ControlResult(ok: true, message: nil, snapshot: snapshot))
    }

    private func handleSelectView(_ req: HttpRequest) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
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

    private func handleSimple(_ req: HttpRequest, _ action: @escaping (ControlServerHandler) -> Void) -> HttpResponse {
        guard authorize(req) else { return unauthorized() }
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
        if !token.isEmpty && providedToken != token { return }
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
        guard !token.isEmpty else { return true }
        if let header = req.headers["x-auth-token"], header == token { return true }
        if let q = req.queryParams.first(where: { $0.0 == "token" })?.1, q == token { return true }
        // Also accept token in JSON body.
        if let obj = bodyJSON(req), (obj["token"] as? String) == token { return true }
        return false
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
        guard let data = try? JSONEncoder().encode(value) else { return .internalServerError(nil) }
        return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
            try writer.write(data)
        }
    }

    private func unauthorized() -> HttpResponse {
        return .raw(401, "Unauthorized", ["Content-Type": "application/json"]) { writer in
            try writer.write(Data("{\"ok\":false,\"message\":\"Unauthorized\"}".utf8))
        }
    }
}

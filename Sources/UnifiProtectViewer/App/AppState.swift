import Foundation
import SwiftUI
import Combine

enum ConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

/// Central application state. Owns the Protect API client, the loaded cameras,
/// the configurable grid views, the current selection/fullscreen state, and the
/// Stream Deck control server.
///
/// Not annotated `@MainActor`: the control server invokes the
/// `ControlServerHandler` methods on the main thread synchronously, and async
/// network work hops back to the main thread explicitly. All `@Published`
/// mutations happen on the main thread.
final class AppState: ObservableObject {
    // MARK: Published state
    @Published var config: AppConfiguration
    @Published var cameras: [ProtectCamera] = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var statusMessage: String?
    @Published var selectedViewID: UUID?
    @Published var fullscreenCameraID: String?
    /// Transient 2FA/MFA code used for the next connect attempt (never persisted).
    @Published var mfaCode: String = ""

    // MARK: Private
    private let apiClient = ProtectAPIClient()
    private var controlServer: ControlServer?
    private var camerasByID: [String: ProtectCamera] = [:]
    private var statusPollTimer: Timer?
    private var statsTimer: Timer?

    init() {
        self.config = ConfigStore.shared.load()
        if config.views.isEmpty {
            // Seed with a single empty "All Cameras" view; populated after connect.
            config.views = [CameraGridConfig(name: "All Cameras", layout: .auto, cameraIDs: [])]
        }
        self.selectedViewID = config.views.first?.id
        startControlServerIfNeeded()

        // Auto-connect on launch when configured and credentials are present.
        if config.connection.autoConnect,
           config.connection.isComplete,
           let pw = storedPassword, !pw.isEmpty {
            connect()
        }

        // Poll camera connection status so offline cameras stop retrying and
        // reconnected cameras resume automatically.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.pollCameraStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusPollTimer = timer

        // Periodic diagnostics: CPU / memory / per-stream state.
        let stats = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.logStats()
        }
        RunLoop.main.add(stats, forMode: .common)
        statsTimer = stats
    }

    private func logStats() {
        guard connectionState == .connected else { return }
        let cpu = SystemStats.cpuUsagePercent()
        let cores = SystemStats.activeProcessorCount
        let mem = SystemStats.memoryFootprintMB()
        let summary = CameraPlayerManager.shared.playbackSummary()
        appLog(String(format: "Stats: cpu=%.0f%% (%d cores → %d%% max) mem=%.0fMB | %@",
                      cpu, cores, cores * 100, mem, summary))
    }

    private func pollCameraStatus() {
        guard connectionState == .connected else { return }
        Task {
            guard let fetched = try? await apiClient.fetchCameras(), !fetched.isEmpty else { return }
            await MainActor.run { self.refreshCameraStatus(fetched) }
        }
    }

    /// Update connection/online status (and other fields) of known cameras
    /// without disturbing playback or view configuration.
    private func refreshCameraStatus(_ fetched: [ProtectCamera]) {
        var changed = false
        var map = camerasByID
        for cam in fetched where map[cam.id] != nil {
            if map[cam.id]?.isOnline != cam.isOnline { changed = true }
            map[cam.id] = cam
        }
        camerasByID = map
        cameras = cameras.map { map[$0.id] ?? $0 }
        if changed { broadcastSnapshot() }
    }

    // MARK: - Configuration persistence

    func saveConfig() {
        ConfigStore.shared.save(config)
    }

    func updateConnection(_ connection: ConnectionSettings, password: String?) {
        config.connection = connection
        if let password = password {
            ConfigStore.shared.setPassword(password, for: connection.username)
        }
        saveConfig()
    }

    var storedPassword: String? {
        ConfigStore.shared.password(for: config.connection.username)
    }

    // MARK: - Connection lifecycle

    func connect() {
        guard config.connection.isComplete else {
            setStatus("Configure the controller connection first.", state: .error)
            return
        }
        guard let password = storedPassword, !password.isEmpty else {
            setStatus("No password stored. Open Settings and re-enter it.", state: .error)
            return
        }
        connectionState = .connecting
        statusMessage = "Connecting to \(config.connection.host)…"
        let connection = config.connection
        let mfa = mfaCode
        appLog("Connecting to \(connection.host) as \(connection.username) (rtsps=\(connection.useRTSPS), grid=\(connection.gridQuality.rawValue), fullscreen=\(connection.fullscreenQuality.rawValue), buffer=\(connection.streamCacheMs)ms)")

        Task {
            do {
                await apiClient.configure(host: connection.host)
                try await apiClient.login(username: connection.username, password: password, mfaToken: mfa)
                appLog("Login succeeded; fetching bootstrap…")
                var bootstrap = try await apiClient.fetchBootstrap()

                if connection.autoEnableRTSP {
                    let updated = await apiClient.enableRTSPIfNeeded(for: bootstrap.cameras)
                    if !updated.isEmpty {
                        // Refresh to pick up the new rtsp aliases.
                        bootstrap = (try? await apiClient.fetchBootstrap()) ?? bootstrap
                    }
                }

                let loaded = bootstrap.cameras.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                await MainActor.run {
                    self.applyCameras(loaded)
                    self.connectionState = .connected
                    self.statusMessage = "Connected — \(loaded.count) camera\(loaded.count == 1 ? "" : "s")."
                    self.mfaCode = ""
                    self.logCameraStreams(loaded)
                    self.broadcastSnapshot()
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.connectionState = .error
                    self.statusMessage = message
                    appLog("Connection failed: \(message)", .error)
                    self.broadcastSnapshot()
                }
            }
        }
    }

    func disconnect() {
        connectionState = .disconnected
        statusMessage = "Disconnected."
        fullscreenCameraID = nil
        CameraPlayerManager.shared.stopAll()
        broadcastSnapshot()
    }

    func reconnect() {
        connect()
    }

    private func applyCameras(_ loaded: [ProtectCamera]) {
        cameras = loaded
        camerasByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })

        // Auto-populate any empty views (e.g. the seeded "All Cameras") with all cameras.
        for index in config.views.indices where config.views[index].cameraIDs.isEmpty {
            config.views[index].cameraIDs = loaded.map { $0.id }
        }
        // Drop camera IDs that no longer exist.
        for index in config.views.indices {
            config.views[index].cameraIDs.removeAll { camerasByID[$0] == nil }
        }
        if selectedViewID == nil { selectedViewID = config.views.first?.id }
        saveConfig()
    }

    private func setStatus(_ message: String, state: ConnectionState) {
        statusMessage = message
        connectionState = state
    }

    /// Log each camera's RTSP channels and the resolved stream URL — the most
    /// useful information for diagnosing "black tile" / no-video problems.
    private func logCameraStreams(_ loaded: [ProtectCamera]) {
        appLog("Loaded \(loaded.count) cameras.")
        for cam in loaded {
            let channels = cam.channels
                .map { "ch\($0.id)[\($0.width ?? 0)x\($0.height ?? 0) rtsp=\($0.isRtspEnabled ?? false) alias=\($0.rtspAlias ?? "nil")]" }
                .joined(separator: ", ")
            let url = streamURL(for: cam, quality: gridQuality(for: currentView))?.absoluteString ?? "nil"
            let level: AppLog.Level = (url == "nil") ? .warn : .info
            appLog("Camera \"\(cam.displayName)\" online=\(cam.isOnline) → \(url) | \(channels)", level)
        }
    }

    // MARK: - Cameras

    func camera(for id: String) -> ProtectCamera? { camerasByID[id] }

    func streamURL(for camera: ProtectCamera, quality: StreamQuality) -> URL? {
        return ProtectAPIClient.streamURL(
            host: config.connection.host,
            camera: camera,
            quality: quality,
            useRTSPS: config.connection.useRTSPS
        )
    }

    /// Quality for grid tiles: a per-view override wins, else the global grid quality.
    func gridQuality(for view: CameraGridConfig?) -> StreamQuality {
        view?.quality ?? config.connection.gridQuality
    }

    /// Quality for the fullscreen single-camera view.
    var fullscreenQuality: StreamQuality {
        config.connection.fullscreenQuality
    }

    // MARK: - Views

    var currentView: CameraGridConfig? {
        guard let id = selectedViewID else { return config.views.first }
        return config.views.first { $0.id == id } ?? config.views.first
    }

    func camerasForCurrentView() -> [ProtectCamera] {
        camerasForView(currentView)
    }

    func camerasForView(_ view: CameraGridConfig?) -> [ProtectCamera] {
        guard let view = view else { return [] }
        return view.cameraIDs.compactMap { camerasByID[$0] }
    }

    func selectView(_ id: UUID) {
        guard config.views.contains(where: { $0.id == id }) else { return }
        selectedViewID = id
        fullscreenCameraID = nil
        broadcastSnapshot()
    }

    func selectView(index: Int) {
        guard config.views.indices.contains(index) else { return }
        selectView(config.views[index].id)
    }

    func nextView() {
        guard !config.views.isEmpty else { return }
        let current = currentIndex ?? -1
        let next = (current + 1) % config.views.count
        selectView(index: next)
    }

    func previousView() {
        guard !config.views.isEmpty else { return }
        let current = currentIndex ?? 0
        let prev = (current - 1 + config.views.count) % config.views.count
        selectView(index: prev)
    }

    var currentIndex: Int? {
        guard let id = selectedViewID else { return nil }
        return config.views.firstIndex { $0.id == id }
    }

    @discardableResult
    func addView(name: String) -> CameraGridConfig {
        let view = CameraGridConfig(name: name.isEmpty ? "New View" : name,
                                    layout: .auto,
                                    cameraIDs: cameras.map { $0.id })
        config.views.append(view)
        saveConfig()
        broadcastSnapshot()
        return view
    }

    func updateView(_ view: CameraGridConfig) {
        guard let index = config.views.firstIndex(where: { $0.id == view.id }) else { return }
        config.views[index] = view
        saveConfig()
        broadcastSnapshot()
    }

    func deleteView(_ id: UUID) {
        config.views.removeAll { $0.id == id }
        if config.views.isEmpty {
            config.views = [CameraGridConfig(name: "All Cameras", layout: .auto, cameraIDs: cameras.map { $0.id })]
        }
        if selectedViewID == id { selectedViewID = config.views.first?.id }
        saveConfig()
        broadcastSnapshot()
    }

    func moveViews(fromOffsets: IndexSet, toOffset: Int) {
        config.views.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveConfig()
        broadcastSnapshot()
    }

    // MARK: - Fullscreen

    func showFullscreen(cameraID: String) {
        guard camerasByID[cameraID] != nil else { return }
        fullscreenCameraID = cameraID
        broadcastSnapshot()
    }

    func exitFullscreen() {
        fullscreenCameraID = nil
        broadcastSnapshot()
    }

    func toggleFullscreen(cameraID: String) {
        if fullscreenCameraID == cameraID {
            exitFullscreen()
        } else {
            showFullscreen(cameraID: cameraID)
        }
    }

    var fullscreenCamera: ProtectCamera? {
        guard let id = fullscreenCameraID else { return nil }
        return camerasByID[id]
    }

    // MARK: - Control server

    func startControlServerIfNeeded() {
        guard config.control.enabled else {
            controlServer?.stop()
            return
        }
        if controlServer == nil {
            controlServer = ControlServer(handler: self)
        }
        controlServer?.start(port: config.control.port, token: config.control.token)
    }

    func restartControlServer() {
        controlServer?.stop()
        controlServer = nil
        startControlServerIfNeeded()
    }

    private func broadcastSnapshot() {
        controlServer?.broadcast(snapshot: controlSnapshot())
    }

    /// Resolve a camera from either the current view (by index) or globally (by id/name).
    private func resolveCamera(id: String?, index: Int?, name: String?) -> ProtectCamera? {
        if let id = id, let cam = camerasByID[id] { return cam }
        if let name = name,
           let cam = cameras.first(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return cam
        }
        if let index = index {
            let viewCams = camerasForCurrentView()
            if viewCams.indices.contains(index) { return viewCams[index] }
            if cameras.indices.contains(index) { return cameras[index] }
        }
        return nil
    }
}

// MARK: - ControlServerHandler

extension AppState: ControlServerHandler {
    func controlSnapshot() -> ControlSnapshot {
        let viewInfos = config.views.enumerated().map { idx, v in
            ControlViewInfo(id: v.id.uuidString, index: idx, name: v.name, cameraCount: v.cameraIDs.count)
        }
        let cameraInfos = cameras.map {
            ControlCameraInfo(id: $0.id, name: $0.displayName, online: $0.isOnline)
        }
        let fsCam = fullscreenCamera
        return ControlSnapshot(
            connection: connectionState.rawValue,
            currentViewID: selectedViewID?.uuidString,
            currentViewIndex: currentIndex,
            currentViewName: currentView?.name,
            fullscreenCameraID: fullscreenCameraID,
            fullscreenCameraName: fsCam?.displayName,
            views: viewInfos,
            cameras: cameraInfos
        )
    }

    func controlSelectView(id: String?, index: Int?, name: String?) -> Bool {
        if let id = id, let uuid = UUID(uuidString: id), config.views.contains(where: { $0.id == uuid }) {
            selectView(uuid)
            return true
        }
        if let name = name,
           let match = config.views.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            selectView(match.id)
            return true
        }
        if let index = index, config.views.indices.contains(index) {
            selectView(index: index)
            return true
        }
        return false
    }

    func controlNextView() { nextView() }
    func controlPreviousView() { previousView() }

    func controlShowFullscreen(cameraID: String?, index: Int?, name: String?) -> Bool {
        guard let cam = resolveCamera(id: cameraID, index: index, name: name) else { return false }
        showFullscreen(cameraID: cam.id)
        return true
    }

    func controlExitFullscreen() { exitFullscreen() }

    func controlToggleFullscreen(cameraID: String?, index: Int?, name: String?) -> Bool {
        guard let cam = resolveCamera(id: cameraID, index: index, name: name) else { return false }
        toggleFullscreen(cameraID: cam.id)
        return true
    }

    func controlReconnect() { reconnect() }
}

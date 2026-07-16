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
@MainActor
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
    private lazy var ptzController = PTZController(apiClient: apiClient)
    private var connectTask: Task<Void, Never>?
    private var reauthTask: Task<Bool, Never>?
    private var connectionGeneration: UInt64 = 0
    private var controlServer: ControlServer?
    private var camerasByID: [String: ProtectCamera] = [:]
    /// Last cameras loaded from the UniFi controller (merged with manual ones).
    private var protectCameras: [ProtectCamera] = []
    private var statusPollTimer: Timer?
    private var statsTimer: Timer?
    // Adaptive status polling.
    private let pollTickSeconds: TimeInterval = 15
    private let slowPollSeconds: TimeInterval = 150
    private let onDemandThrottleSeconds: TimeInterval = 10
    private var lastStatusFetch = Date.distantPast
    private var lastOnDemandCheck = Date.distantPast
    private var isFetchingStatus = false
    private var lastMemWarning = Date.distantPast

    init() {
        self.config = ConfigStore.shared.load()
        if config.views.isEmpty {
            // Seed with a single empty "All Cameras" view; populated after connect.
            config.views = [CameraGridConfig(name: "All Cameras", layout: .auto, cameraIDs: [])]
        }
        self.selectedViewID = config.views.first?.id
        startControlServerIfNeeded()

        // When a stream keeps failing, confirm against the controller whether
        // the camera is actually offline (vs a transient stream problem).
        CameraPlayerManager.shared.onPersistentFailure = { [weak self] cameraID in
            Task { @MainActor in self?.confirmCameraStatus(triggeredBy: cameraID) }
        }

        // Log memory-pressure events with context (which view / how many tiles),
        // so a low-RAM machine's near-jetsam moments are visible in the log.
        CameraPlayerManager.shared.onMemoryPressure = { [weak self] critical in
            Task { @MainActor in
                guard let self = self else { return }
                appLog("Memory pressure (\(critical ? "critical" : "warning")) while showing view \"\(self.currentView?.name ?? "-")\" with \(self.camerasForCurrentView().count) tiles",
                       critical ? .error : .warn)
            }
        }

        // Make any user-added custom streams available immediately (even before
        // / without connecting to a UniFi controller).
        if !config.manualCameras.isEmpty {
            rebuildCameras(prune: false)
        }

        // Auto-connect on launch when configured and credentials are present.
        if config.connection.autoConnect,
           config.connection.isComplete,
           let pw = storedPassword, !pw.isEmpty {
            connect()
        }

        // Adaptive status poll: frequent while any camera is offline (to catch
        // it coming back), infrequent otherwise. Live health is driven by the
        // stream itself; this poll is for offline confirmation/recovery.
        let timer = Timer(timeInterval: pollTickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCameraStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusPollTimer = timer

        // Periodic diagnostics: CPU / memory / per-stream state.
        let stats = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logStats() }
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

        // Early warning as memory climbs toward a level where macOS may kill the
        // app (jetsam). Throttled so it doesn't spam the log.
        let physicalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1024.0 / 1024.0
        let ratio = physicalMB > 0 ? mem / physicalMB : 0
        if ratio >= 0.4, Date().timeIntervalSince(lastMemWarning) >= 60 {
            lastMemWarning = Date()
            appLog(String(format: "High memory: %.0fMB (%.0f%% of %.1fGB). Reduce load: set Grid quality = Low or use fewer tiles per view. Off-screen streams are freed automatically.",
                          mem, ratio * 100, physicalMB / 1024.0),
                   ratio >= 0.6 ? .error : .warn)
        }
    }

    /// Timer tick; only actually hits the API when needed.
    private func pollCameraStatus() {
        guard connectionState == .connected else { return }
        let anyOffline = camerasByID.values.contains { $0.directURL == nil && !$0.isOnline }
        let slowDue = Date().timeIntervalSince(lastStatusFetch) >= slowPollSeconds
        // Poll often while something is offline (to catch recovery), otherwise
        // just an occasional safety refresh.
        guard anyOffline || slowDue else { return }
        fetchCameraStatus()
    }

    /// On-demand check triggered by a persistently failing stream, throttled so
    /// several failing cameras don't cause a burst of API calls.
    private func confirmCameraStatus(triggeredBy cameraID: String) {
        guard connectionState == .connected else { return }
        guard Date().timeIntervalSince(lastOnDemandCheck) >= onDemandThrottleSeconds else { return }
        lastOnDemandCheck = Date()
        appLog("Stream for \"\(camerasByID[cameraID]?.displayName ?? cameraID)\" keeps failing — checking controller for offline status…", .debug)
        fetchCameraStatus()
    }

    private func fetchCameraStatus() {
        guard !isFetchingStatus else { return }
        isFetchingStatus = true
        lastStatusFetch = Date()
        Task { [weak self, apiClient] in
            guard let self = self else { return }
            defer { self.isFetchingStatus = false }
            do {
                var fetched: [ProtectCamera]
                do {
                    fetched = try await apiClient.fetchCameras()
                } catch {
                    guard self.isAuthenticationError(error),
                          await self.reauthenticate() else { throw error }
                    fetched = try await apiClient.fetchCameras()
                }
                if !fetched.isEmpty { self.refreshCameraStatus(fetched) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appLog("Camera status poll failed: \(message)", .warn)
            }
        }
    }

    private func isAuthenticationError(_ error: Error) -> Bool {
        guard let apiError = error as? ProtectAPIError else { return false }
        if case .authenticationFailed = apiError { return true }
        return false
    }

    /// Coalesce every session refresh into one login. Callers can retry one
    /// idempotent operation after this succeeds.
    private func reauthenticate() async -> Bool {
        if let existing = reauthTask { return await existing.value }
        guard connectionState == .connected,
              let password = storedPassword, !password.isEmpty else { return false }
        let connection = config.connection
        let task = Task { [apiClient] () -> Bool in
            do {
                await apiClient.clearSession()
                try await apiClient.login(username: connection.username,
                                          password: password,
                                          mfaToken: "")
                appLog("Controller session renewed")
                return true
            } catch {
                appLog("Controller session renewal failed: \(error.localizedDescription)", .error)
                return false
            }
        }
        reauthTask = task
        let result = await task.value
        reauthTask = nil
        if !result {
            connectionState = .error
            statusMessage = "Controller session expired. Reconnect required."
            broadcastSnapshot()
        }
        return result
    }

    /// Update connection/online status (and other fields) of known cameras
    /// without disturbing playback or view configuration.
    private func refreshCameraStatus(_ fetched: [ProtectCamera]) {
        var changed = false
        var map = camerasByID
        for cam in fetched where map[cam.id] != nil {
            if let old = map[cam.id], old.isOnline != cam.isOnline {
                changed = true
                appLog("Camera \"\(cam.displayName)\" is now \(cam.isOnline ? "online" : "offline") (state=\(cam.state ?? "?"), connected=\(cam.isConnected.map(String.init) ?? "?"))")
            }
            map[cam.id] = cam
        }
        camerasByID = map
        cameras = cameras.map { map[$0.id] ?? $0 }
        protectCameras = protectCameras.map { map[$0.id] ?? $0 }
        if changed { broadcastSnapshot() }
    }

    // MARK: - Configuration persistence

    func saveConfig() {
        ConfigStore.shared.save(config)
    }

    func updateConnection(_ connection: ConnectionSettings, password: String?) {
        let previous = config.connection
        config.connection = connection
        if let password = password, !password.isEmpty {
            if ConfigStore.shared.setPassword(password,
                                              host: connection.host,
                                              username: connection.username),
               previous.host != connection.host || previous.username != connection.username {
                ConfigStore.shared.removePassword(host: previous.host, username: previous.username)
            }
        }
        saveConfig()
    }

    var storedPassword: String? {
        ConfigStore.shared.password(host: config.connection.host,
                                    username: config.connection.username)
    }

    func removeStoredPassword() {
        ConfigStore.shared.removePassword(host: config.connection.host,
                                          username: config.connection.username)
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
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let previous = connectTask
        previous?.cancel()
        appLog("Connecting to \(connection.host) as \(connection.username) (rtsps=\(connection.useRTSPS), grid=\(connection.gridQuality.rawValue), fullscreen=\(connection.fullscreenQuality.rawValue), buffer=\(connection.streamCacheMs)ms)")

        connectTask = Task { [weak self, apiClient] in
            // Do not let two tasks reset/use the shared API session at once.
            if let previous = previous { _ = await previous.result }
            guard let self = self else { return }
            do {
                try Task.checkCancellation()
                await apiClient.configure(host: connection.host)
                try Task.checkCancellation()
                try await apiClient.login(username: connection.username, password: password, mfaToken: mfa)
                try Task.checkCancellation()
                appLog("Login succeeded; fetching bootstrap…")
                var bootstrap = try await apiClient.fetchBootstrap()
                try Task.checkCancellation()

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
                try Task.checkCancellation()
                guard generation == self.connectionGeneration else { return }
                self.applyCameras(loaded)
                self.connectionState = .connected
                self.statusMessage = "Connected — \(loaded.count) camera\(loaded.count == 1 ? "" : "s")."
                self.mfaCode = ""
                self.logCameraStreams(loaded)
                self.broadcastSnapshot()
                self.connectTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.connectionGeneration else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.connectionState = .error
                self.statusMessage = message
                self.connectTask = nil
                appLog("Connection failed: \(message)", .error)
                self.broadcastSnapshot()
            }
        }
    }

    func disconnect() {
        stopPTZ(cameraID: fullscreenCameraID)
        connectionGeneration &+= 1
        connectTask?.cancel(); connectTask = nil
        reauthTask?.cancel(); reauthTask = nil
        Task { [apiClient] in await apiClient.clearSession() }
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
        protectCameras = loaded
        rebuildCameras(prune: true)
    }

    private func manualProtectCameras() -> [ProtectCamera] {
        config.manualCameras.map { ProtectCamera(manualID: $0.id, name: $0.name, url: $0.url) }
    }

    /// Rebuild the combined camera list (UniFi + manual). `prune` is only true
    /// after a real controller load — it auto-populates empty views and drops
    /// stale IDs (we must not prune before Protect cameras are known).
    private func rebuildCameras(prune: Bool) {
        let combined = (protectCameras + manualProtectCameras())
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        cameras = combined
        camerasByID = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0) })

        if prune {
            for index in config.views.indices where config.views[index].cameraIDs.isEmpty {
                config.views[index].cameraIDs = combined.map { $0.id }
            }
            for index in config.views.indices {
                config.views[index].cameraIDs.removeAll { camerasByID[$0] == nil }
            }
        }
        if selectedViewID == nil { selectedViewID = config.views.first?.id }
        saveConfig()
    }

    // MARK: - Manual (non-UniFi) streams

    func addManualCamera(name: String, url: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let displayName = name.trimmingCharacters(in: .whitespaces)
        var cam = ManualCamera(name: displayName.isEmpty ? trimmedURL : displayName, url: trimmedURL)
        if !ConfigStore.shared.setManualStreamURL(trimmedURL, id: cam.id) {
            // Preserve the URL in config only when secure storage is
            // unavailable, so the user does not silently lose the stream.
            cam.requiresSecureMigration = true
        }
        config.manualCameras.append(cam)
        rebuildCameras(prune: false)
        // Show it right away by adding it to the current view.
        if let vid = selectedViewID ?? config.views.first?.id,
           let idx = config.views.firstIndex(where: { $0.id == vid }),
           !config.views[idx].cameraIDs.contains(cam.id) {
            config.views[idx].cameraIDs.append(cam.id)
        }
        saveConfig()
        broadcastSnapshot()
    }

    func updateManualCamera(_ cam: ManualCamera) {
        guard let idx = config.manualCameras.firstIndex(where: { $0.id == cam.id }) else { return }
        var secured = cam
        secured.requiresSecureMigration = !ConfigStore.shared.setManualStreamURL(cam.url, id: cam.id)
        config.manualCameras[idx] = secured
        rebuildCameras(prune: false)
        broadcastSnapshot()
    }

    func removeManualCamera(id: String) {
        ConfigStore.shared.removeManualStreamURL(id: id)
        config.manualCameras.removeAll { $0.id == id }
        for index in config.views.indices {
            config.views[index].cameraIDs.removeAll { $0 == id }
        }
        rebuildCameras(prune: false)
        broadcastSnapshot()
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
            let streamURL = streamURL(for: cam, quality: gridQuality(for: currentView))
            let level: AppLog.Level = streamURL == nil ? .warn : .info
            appLog("Camera \"\(cam.displayName)\" online=\(cam.isOnline) → \(SecretRedaction.url(streamURL)) | \(channels)", level)
        }
    }

    // MARK: - Cameras

    func camera(for id: String) -> ProtectCamera? { camerasByID[id] }

    func streamURL(for camera: ProtectCamera, quality: StreamQuality) -> URL? {
        // Manual/custom streams play their URL directly.
        if let direct = camera.directURL {
            return URL(string: direct)
        }
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
        stopPTZ(cameraID: fullscreenCameraID)
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
        if let current = fullscreenCameraID, current != cameraID {
            stopPTZ(cameraID: current)
        }
        fullscreenCameraID = cameraID
        broadcastSnapshot()
    }

    func exitFullscreen() {
        stopPTZ(cameraID: fullscreenCameraID)
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

    // MARK: - PTZ continuous move (hold-to-move)

    /// Start/adjust or stop continuous PTZ movement. `dx`/`dy`/`dz` are
    /// direction hints in {-1, 0, 1}: dx = pan (+right/-left), dy = tilt
    /// (+up/-down), dz = zoom (+out/-in). All zero = stop. The camera keeps
    /// moving until stopped, so callers send a non-zero move on press and a zero
    /// move on release; a safety timer also auto-stops after a few seconds.
    @discardableResult
    func ptzMove(cameraID: String?, dx: Int, dy: Int, dz: Int) -> Bool {
        let cam = cameraID.flatMap { camerasByID[$0] } ?? fullscreenCamera
        guard let cam = cam, cam.isPTZ, !cam.isManual else { return false }
        let id = cam.id
        let speed = ProtectAPIClient.ptzMoveSpeed
        let x = dx.signum() * speed
        let y = dy.signum() * speed
        let z = dz.signum() * speed
        Task { [weak self] in
            guard let self = self, await self.ensureAuthenticated() else { return }
            await self.ptzController.move(cameraID: id, x: x, y: y, z: z)
        }
        return true
    }

    private func stopPTZ(cameraID: String? = nil) {
        Task { [ptzController] in await ptzController.stop(cameraID: cameraID) }
    }

    private func ensureAuthenticated() async -> Bool {
        if await apiClient.isAuthenticated { return true }
        return await reauthenticate()
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
        controlServer?.start(port: config.control.port,
                             token: config.control.token,
                             allowLAN: config.control.allowLAN)
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
            ControlCameraInfo(id: $0.id, name: $0.displayName, online: $0.isOnline, ptz: $0.isPTZ)
        }
        let fsCam = fullscreenCamera
        return ControlSnapshot(
            connection: connectionState.rawValue,
            currentViewID: selectedViewID?.uuidString,
            currentViewIndex: currentIndex,
            currentViewName: currentView?.name,
            fullscreenCameraID: fullscreenCameraID,
            fullscreenCameraName: fsCam?.displayName,
            fullscreenCameraPtz: fsCam?.isPTZ ?? false,
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

    func controlPTZMove(cameraID: String?, index: Int?, name: String?, dx: Int, dy: Int, dz: Int) -> Bool {
        let cam = resolveCamera(id: cameraID, index: index, name: name) ?? fullscreenCamera
        guard let cam = cam else { return false }
        return ptzMove(cameraID: cam.id, dx: dx, dy: dy, dz: dz)
    }

    func controlPTZ(cameraID: String?, index: Int?, name: String?, action: String, slot: Int) -> Bool {
        // Default to the camera currently shown fullscreen, so Stream Deck PTZ
        // buttons control "whatever PTZ camera is on screen" with no per-button
        // configuration.
        let cam = resolveCamera(id: cameraID, index: index, name: name) ?? fullscreenCamera
        guard let cam = cam, cam.isPTZ, !cam.isManual else { return false }
        let allowed = ["home", "goto", "patrol-start", "patrol-stop"]
        guard allowed.contains(action) else { return false }
        if action == "goto" || action == "patrol-start" {
            guard (0...31).contains(slot) else { return false }
        }
        let id = cam.id
        appLog("PTZ \(action) slot=\(slot) on \"\(cam.displayName)\"")
        Task { [weak self] in
            guard let self = self, await self.ensureAuthenticated() else { return }
            do {
                await self.ptzController.stop(cameraID: id)
                do {
                    try await self.executePTZAction(action, cameraID: id, slot: slot)
                } catch {
                    guard self.isAuthenticationError(error),
                          await self.reauthenticate() else { throw error }
                    try await self.executePTZAction(action, cameraID: id, slot: slot)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appLog("PTZ \(action) failed: \(message)", .error)
            }
        }
        return true
    }

    private func executePTZAction(_ action: String, cameraID: String, slot: Int) async throws {
        switch action {
        case "home": try await apiClient.ptzGoto(cameraID: cameraID, slot: -1)
        case "goto": try await apiClient.ptzGoto(cameraID: cameraID, slot: slot)
        case "patrol-start": try await apiClient.ptzPatrolStart(cameraID: cameraID, slot: slot)
        case "patrol-stop": try await apiClient.ptzPatrolStop(cameraID: cameraID)
        default: return
        }
    }
}

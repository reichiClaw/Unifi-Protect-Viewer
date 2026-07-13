import SwiftUI

/// Shows a single camera filling the detail area, with controls to return to
/// the grid and to step between cameras in the current view.
struct FullscreenCameraView: View {
    let camera: ProtectCamera
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var status: CameraPlaybackStatus
    @State private var showControls = true

    init(camera: ProtectCamera) {
        self.camera = camera
        _status = ObservedObject(initialValue: CameraPlayerManager.shared.status(for: camera.id))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Instant layer: reuse the already-playing grid stream (just gets
            // reparented here → no delay). Shows overlays (offline/buffering).
            // A click here returns to the grid (if enabled in Settings).
            CameraTileView(camera: camera, view: appState.currentView, showName: false, isFullscreen: false) {
                if appState.config.tapFullscreenToExit { appState.exitFullscreen() }
            }
            .id(camera.id)

            // Upgrade layer: the high-quality stream, started in the background
            // and faded in only once it is actually playing — so the switch to
            // fullscreen is immediate and then sharpens, with no black gap.
            // Non-hit-testable so taps fall through to the base layer above.
            if needsUpgrade, let highURL = highQualityURL {
                UpgradeVideoLayer(streamKey: camera.id + "#fs",
                                  shadowCameraID: camera.id,
                                  url: highURL,
                                  caching: appState.config.connection.streamCacheMs,
                                  online: camera.isOnline,
                                  hardwareDecoding: appState.config.connection.hardwareDecoding)
                    .id(camera.id)
                    .allowsHitTesting(false)
            }

            if showControls {
                controlBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // On-screen PTZ controls for PTZ cameras — no Stream Deck required.
            if camera.isPTZ && showControls {
                VStack {
                    Spacer()
                    ptzPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color.black)
        .onHover { hovering in
            withAnimation { showControls = hovering }
        }
        .onAppear { showControls = true }
        // Esc returns to the grid.
        .onExitCommand { appState.exitFullscreen() }
    }

    private var statusColor: Color {
        switch status.state {
        case .playing: return .green
        case .offline: return .red
        case .error: return .orange
        case .buffering, .idle: return .gray
        }
    }

    private var statusText: String {
        switch status.state {
        case .playing: return "Live"
        case .offline: return "Offline"
        case .error: return "Reconnecting…"
        case .buffering, .idle: return "Connecting…"
        }
    }

    private var gridURL: URL? {
        appState.streamURL(for: camera, quality: appState.gridQuality(for: appState.currentView))
    }

    private var highQualityURL: URL? {
        appState.streamURL(for: camera, quality: appState.fullscreenQuality)
    }

    /// Only upgrade when the high-quality URL actually differs from the grid
    /// one (e.g. skip for manual streams or single-channel cameras).
    private var needsUpgrade: Bool {
        guard let high = highQualityURL, let base = gridURL else { return false }
        return high != base
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                appState.exitFullscreen()
            } label: {
                Label("Grid", systemImage: "square.grid.2x2")
            }

            Divider().frame(height: 18)

            Button {
                step(-1)
            } label: { Image(systemName: "chevron.left") }
                .help("Previous camera")

            Text(camera.displayName)
                .font(.headline)
                .foregroundColor(.white)
                .frame(minWidth: 160)

            Button {
                step(1)
            } label: { Image(systemName: "chevron.right") }
                .help("Next camera")

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private func step(_ delta: Int) {
        let cams = appState.camerasForCurrentView()
        guard let idx = cams.firstIndex(where: { $0.id == camera.id }), !cams.isEmpty else { return }
        let next = (idx + delta + cams.count) % cams.count
        appState.showFullscreen(cameraID: cams[next].id)
    }

    // MARK: PTZ controls

    /// Floating control bar for a PTZ camera: a hold-to-move D-pad, zoom, home,
    /// saved presets, and patrol. Preset buttons are labelled 1…N but map to
    /// zero-based slots (button *n* = slot *n-1*).
    private var ptzPanel: some View {
        HStack(alignment: .center, spacing: 14) {
            dPad
            zoomControls

            Divider().frame(height: 44)

            ptzButton(system: "house.fill", help: "Home position") {
                sendPTZ(action: "home", slot: 0)
            }

            if appState.config.ptzPresetCount > 0 {
                ForEach(1...appState.config.ptzPresetCount, id: \.self) { n in
                    Button("\(n)") { sendPTZ(action: "goto", slot: n - 1) }
                        .buttonStyle(.bordered)
                        .frame(minWidth: 30)
                        .help("Go to preset \(n)")
                }
            }

            Divider().frame(height: 44)
            ptzButton(system: "play.fill", help: "Start patrol") {
                sendPTZ(action: "patrol-start", slot: 0)
            }
            ptzButton(system: "stop.fill", help: "Stop patrol") {
                sendPTZ(action: "patrol-stop", slot: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 16)
    }

    /// Hold-to-move pan/tilt cross.
    private var dPad: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                dPadSpacer
                holdMove(dx: 0, dy: 1, system: "chevron.up", help: "Tilt up")
                dPadSpacer
            }
            GridRow {
                holdMove(dx: -1, dy: 0, system: "chevron.left", help: "Pan left")
                dPadSpacer
                holdMove(dx: 1, dy: 0, system: "chevron.right", help: "Pan right")
            }
            GridRow {
                dPadSpacer
                holdMove(dx: 0, dy: -1, system: "chevron.down", help: "Tilt down")
                dPadSpacer
            }
        }
    }

    private var dPadSpacer: some View { Color.clear.frame(width: 30, height: 26) }

    /// Hold-to-zoom controls (in = closer, out = wider).
    private var zoomControls: some View {
        VStack(spacing: 4) {
            holdMove(dz: -1, system: "plus.magnifyingglass", help: "Zoom in")
            holdMove(dz: 1, system: "minus.magnifyingglass", help: "Zoom out")
        }
    }

    private func holdMove(dx: Int = 0, dy: Int = 0, dz: Int = 0, system: String, help: String) -> some View {
        PTZHoldButton(system: system, help: help,
                      onPress: { appState.ptzMove(cameraID: camera.id, dx: dx, dy: dy, dz: dz) },
                      onRelease: { appState.ptzMove(cameraID: camera.id, dx: 0, dy: 0, dz: 0) })
    }

    private func ptzButton(system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.bordered)
        .help(help)
    }

    private func sendPTZ(action: String, slot: Int) {
        _ = appState.controlPTZ(cameraID: camera.id, index: nil, name: nil, action: action, slot: slot)
    }
}

/// A button that fires `onPress` the moment it's pressed and `onRelease` when
/// released — used for hold-to-move PTZ controls (move while held, stop on
/// release). A plain SwiftUI `Button` only reports a completed click, so we use
/// a zero-distance drag gesture to get down/up events.
private struct PTZHoldButton: View {
    let system: String
    let help: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressing = false

    var body: some View {
        Image(systemName: system)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 26)
            .background(pressing ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressing { pressing = true; onPress() }
                    }
                    .onEnded { _ in
                        pressing = false; onRelease()
                    }
            )
            .help(help)
    }
}

/// A high-quality video layer that stays transparent until its stream is
/// actually playing, then fades in on top of the instant (grid-quality) layer.
private struct UpgradeVideoLayer: View {
    let streamKey: String
    /// The grid-quality camera this HQ layer covers; its decode is suspended
    /// while this layer is actually playing, to avoid decoding it twice.
    let shadowCameraID: String
    let url: URL
    let caching: Int
    let online: Bool
    let hardwareDecoding: Bool
    @ObservedObject private var status: CameraPlaybackStatus

    init(streamKey: String, shadowCameraID: String, url: URL, caching: Int, online: Bool, hardwareDecoding: Bool) {
        self.streamKey = streamKey
        self.shadowCameraID = shadowCameraID
        self.url = url
        self.caching = caching
        self.online = online
        self.hardwareDecoding = hardwareDecoding
        _status = ObservedObject(initialValue: CameraPlayerManager.shared.status(for: streamKey))
    }

    var body: some View {
        CameraVideoView(cameraID: streamKey, url: url, caching: caching, online: online, hardwareDecoding: hardwareDecoding)
            .opacity(status.state == .playing ? 1 : 0)
            .animation(.easeIn(duration: 0.25), value: status.state)
            // Suspend the grid-quality decoder only while this HQ layer is
            // actually playing (and covering it); resume it otherwise so the
            // user never sees a black frame if this layer drops.
            .onChange(of: status.state) { newState in
                CameraPlayerManager.shared.setShadowed(cameraID: shadowCameraID, newState == .playing)
            }
            .onDisappear {
                CameraPlayerManager.shared.setShadowed(cameraID: shadowCameraID, false)
            }
    }
}

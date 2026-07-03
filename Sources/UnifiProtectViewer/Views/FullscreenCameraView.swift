import SwiftUI

/// Shows a single camera filling the detail area, with controls to return to
/// the grid and to step between cameras in the current view.
struct FullscreenCameraView: View {
    let camera: ProtectCamera
    @EnvironmentObject private var appState: AppState
    @State private var showControls = true

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
                                  url: highURL,
                                  caching: appState.config.connection.streamCacheMs,
                                  online: camera.isOnline)
                    .id(camera.id)
                    .allowsHitTesting(false)
            }

            if showControls {
                controlBar
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                    .fill(camera.isOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(camera.isOnline ? "Live" : "Offline")
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
}

/// A high-quality video layer that stays transparent until its stream is
/// actually playing, then fades in on top of the instant (grid-quality) layer.
private struct UpgradeVideoLayer: View {
    let streamKey: String
    let url: URL
    let caching: Int
    let online: Bool
    @ObservedObject private var status: CameraPlaybackStatus

    init(streamKey: String, url: URL, caching: Int, online: Bool) {
        self.streamKey = streamKey
        self.url = url
        self.caching = caching
        self.online = online
        _status = ObservedObject(initialValue: CameraPlayerManager.shared.status(for: streamKey))
    }

    var body: some View {
        CameraVideoView(cameraID: streamKey, url: url, caching: caching, online: online)
            .opacity(status.state == .playing ? 1 : 0)
            .animation(.easeIn(duration: 0.25), value: status.state)
    }
}

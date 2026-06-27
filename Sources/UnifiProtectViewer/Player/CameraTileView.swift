import SwiftUI

/// A single camera tile: live video plus an overlay with the camera name,
/// connection status, and a buffering / error indicator. Clicking the tile
/// toggles fullscreen for that camera.
struct CameraTileView: View {
    let camera: ProtectCamera
    let view: CameraGridConfig?
    var showName: Bool = true
    var onActivate: (() -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var status: CameraPlaybackStatus
    @State private var hovering = false

    init(camera: ProtectCamera,
         view: CameraGridConfig?,
         showName: Bool = true,
         onActivate: (() -> Void)? = nil) {
        self.camera = camera
        self.view = view
        self.showName = showName
        self.onActivate = onActivate
        _status = ObservedObject(initialValue: CameraPlayerManager.shared.status(for: camera.id))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black

            if let url = appState.streamURL(for: camera, in: view) {
                CameraVideoView(cameraID: camera.id,
                                url: url,
                                caching: appState.config.connection.streamCacheMs)
            } else {
                noStreamPlaceholder
            }

            statusOverlay

            if showName {
                nameBar
            }

            if hovering {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onActivate?() }
        .help(camera.displayName)
    }

    private var nameBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(camera.isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(camera.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear],
                           startPoint: .bottom, endPoint: .top)
        )
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch status.state {
        case .buffering, .idle:
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
                .tint(.white)
        case .error:
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("Stream error — retrying…")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
            }
        case .playing:
            EmptyView()
        }
    }

    private var noStreamPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash.fill")
                .font(.title)
                .foregroundColor(.secondary)
            Text("No RTSP stream available")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Enable RTSP for this camera in UniFi Protect.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

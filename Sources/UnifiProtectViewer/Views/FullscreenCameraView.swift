import SwiftUI

/// Shows a single camera filling the detail area, with controls to return to
/// the grid and to step between cameras in the current view.
struct FullscreenCameraView: View {
    let camera: ProtectCamera
    @EnvironmentObject private var appState: AppState
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .top) {
            CameraTileView(camera: camera, view: appState.currentView, showName: false)
                .id(camera.id) // recreate player when switching cameras

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

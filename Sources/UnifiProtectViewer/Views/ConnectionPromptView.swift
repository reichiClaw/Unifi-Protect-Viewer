import SwiftUI

/// Shown when the app is not yet connected and has no cameras loaded.
struct ConnectionPromptView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("UniFi Protect Viewer")
                .font(.largeTitle.bold())

            if appState.config.connection.isComplete {
                Text("Ready to connect to \(appState.config.connection.host).")
                    .foregroundColor(.secondary)
                HStack {
                    Button {
                        appState.connect()
                    } label: {
                        Label("Connect", systemImage: "bolt.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    SettingsOpener { Text("Settings…") }
                        .controlSize(.large)
                }
            } else {
                Text("Configure your UniFi Protect controller to get started.")
                    .foregroundColor(.secondary)
                SettingsOpener {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }

            if appState.connectionState == .error, let message = appState.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

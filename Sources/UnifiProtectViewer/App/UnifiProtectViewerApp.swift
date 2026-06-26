import SwiftUI

@main
struct UnifiProtectViewerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Next View") { appState.nextView() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous View") { appState.previousView() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Exit Fullscreen") { appState.exitFullscreen() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(appState.fullscreenCameraID == nil)
                Divider()
                Button(appState.connectionState == .connected ? "Reconnect" : "Connect") {
                    appState.connect()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

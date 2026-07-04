import SwiftUI
import AppKit

/// Installs crash diagnostics as early as possible and logs launch/quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        CrashReporter.install(logFileURL: AppLog.shared.fileURL)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        appLog("App launched (version \(version))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog("App terminating normally")
    }
}

@main
struct UnifiProtectViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
            LogCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        Window("Log", id: LogWindow.id) {
            LogView()
        }
    }
}

enum LogWindow {
    static let id = "log"
}

/// Adds a "View → Show Log" menu command that opens the Log window.
struct LogCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show Log") { openWindow(id: LogWindow.id) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

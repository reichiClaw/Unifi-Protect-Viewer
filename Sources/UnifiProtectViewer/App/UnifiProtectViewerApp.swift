import SwiftUI
import AppKit

/// Installs crash diagnostics as early as possible and logs launch/quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var ownsRun = false
    private var crashLoopDisabled = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        ownsRun = true
        if !RelaunchGuard.recordLaunch() {
            crashLoopDisabled = true
            try? LaunchAgentInstaller.uninstall()
        }
        CrashReporter.install(logFileURL: AppLog.shared.crashFileURL)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        appLog("App launched (version \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), session \(UUID().uuidString))")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard crashLoopDisabled else { return }
        appLog("Auto-restart disabled after repeated abnormal launches", .error)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Auto-restart was disabled"
        alert.informativeText = "The app exited abnormally several times in a short period. Auto-restart has been disabled to prevent a crash loop. Review the crash log before enabling it again."
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if ownsRun { RelaunchGuard.recordCleanExit() }
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

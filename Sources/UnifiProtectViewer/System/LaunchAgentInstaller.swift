import Foundation

/// Installs (or removes) a per-user launchd **LaunchAgent** that keeps the app
/// running on an unattended control-room wall: launchd relaunches it within
/// seconds of any abnormal exit — a crash, a hang you force-quit, or an
/// out-of-memory (jetsam) kill — and starts it again at login.
///
/// This is the ultimate safety net: it works regardless of *why* the app died,
/// so the wall recovers on its own instead of going dark until someone notices.
///
/// We use `KeepAlive = { SuccessfulExit = false }` so a **clean** quit (⌘Q,
/// which exits 0) is respected and does *not* trigger a relaunch, while any
/// crash/kill (non-zero / signal) is relaunched. The app is not sandboxed, so
/// writing to `~/Library/LaunchAgents` and invoking `launchctl` is permitted.
enum LaunchAgentInstaller {
    static let label = "com.unifiprotectviewer.autorestart"

    static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// The app executable launchd should keep alive (the binary inside the .app).
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Write the LaunchAgent plist and load it so it takes effect immediately.
    static func install() throws {
        let exe = executablePath
        guard !exe.isEmpty else { throw Error.noExecutablePath }

        let plist: [String: Any] = [
            "Label": label,
            "Program": exe,
            // Start at login and relaunch on any abnormal exit (crash / jetsam),
            // but not after a clean user quit.
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            // Give the GUI session context and don't hammer on a crash loop.
            "ProcessType": "Interactive",
            "ThrottleInterval": 5,
        ]

        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // Reload: unload any previous copy (ignore failures), then load fresh.
        _ = runLaunchctl(["unload", plistURL.path])
        let result = runLaunchctl(["load", "-w", plistURL.path])
        if result != 0 {
            appLog("Auto-restart: `launchctl load` returned \(result); the plist is written and will load at next login.", .warn)
        }
        appLog("Auto-restart LaunchAgent installed at \(plistURL.path)")
    }

    /// Unload and remove the LaunchAgent.
    static func uninstall() throws {
        if isInstalled {
            _ = runLaunchctl(["unload", "-w", plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
        }
        appLog("Auto-restart LaunchAgent removed")
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        // Silence output; we only care about the exit status.
        proc.standardOutput = nil
        proc.standardError = nil
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            appLog("Auto-restart: failed to run launchctl \(args.joined(separator: " ")): \(error)", .warn)
            return -1
        }
    }

    enum Error: LocalizedError {
        case noExecutablePath
        var errorDescription: String? {
            switch self {
            case .noExecutablePath: return "Could not determine the app's executable path."
            }
        }
    }
}

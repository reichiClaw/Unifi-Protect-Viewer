import Foundation

/// Detects repeated abnormal launches so launchd cannot spin forever on a
/// deterministic startup crash. A clean app termination resets the window.
enum RelaunchGuard {
    private struct State: Codable {
        var lastExitWasClean = true
        var launches: [Date] = []
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UnifiProtectViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("relaunch-state.json")
    }

    /// Returns false after six abnormal launches inside two minutes.
    static func recordLaunch() -> Bool {
        var state = load()
        let now = Date()
        if state.lastExitWasClean {
            state.launches.removeAll()
        } else {
            state.launches.removeAll { now.timeIntervalSince($0) > 120 }
        }
        state.launches.append(now)
        state.lastExitWasClean = false
        save(state)
        return state.launches.count <= 5
    }

    static func recordCleanExit() {
        var state = load()
        state.lastExitWasClean = true
        state.launches.removeAll()
        save(state)
    }

    private static func load() -> State {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private static func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

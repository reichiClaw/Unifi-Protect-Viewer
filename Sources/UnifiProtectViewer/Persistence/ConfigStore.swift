import Foundation

/// Loads and saves the app configuration to disk (JSON) and the password to
/// the Keychain.
final class ConfigStore {
    static let shared = ConfigStore()

    private let fileManager = FileManager.default

    private var configURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UnifiProtectViewer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("config.json")
    }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfiguration()
        }
        do {
            return try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            NSLog("ConfigStore: failed to decode config: \(error). Using defaults.")
            return AppConfiguration()
        }
    }

    func save(_ config: AppConfiguration) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("ConfigStore: failed to save config: \(error)")
        }
    }

    // MARK: - Password (Keychain)

    func password(for username: String) -> String? {
        guard !username.isEmpty else { return nil }
        return Keychain.get(account: username)
    }

    func setPassword(_ password: String, for username: String) {
        guard !username.isEmpty else { return }
        if password.isEmpty {
            Keychain.delete(account: username)
        } else {
            Keychain.set(password, account: username)
        }
    }
}

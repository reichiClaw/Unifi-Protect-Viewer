import Foundation

/// Loads and saves the app configuration and the controller password to disk.
///
/// The password is stored in a separate, permission-restricted file in
/// Application Support (not the Keychain). The Keychain re-prompts for
/// authorization whenever the app's code signature changes (which happens on
/// every local/dev build), which made the saved password effectively
/// unusable. A 0600 file in the user's Application Support directory avoids the
/// prompt and loads reliably. The value is base64-encoded (obfuscation, not
/// encryption).
final class ConfigStore {
    static let shared = ConfigStore()

    private let fileManager = FileManager.default

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UnifiProtectViewer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var credentialsURL: URL { directory.appendingPathComponent("credentials.json") }

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

    // MARK: - Password (file-backed)

    func password(for username: String) -> String? {
        guard !username.isEmpty else { return nil }
        let creds = loadCredentials()
        guard let encoded = creds[username],
              let data = Data(base64Encoded: encoded),
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    func setPassword(_ password: String, for username: String) {
        guard !username.isEmpty else { return }
        var creds = loadCredentials()
        if password.isEmpty {
            creds.removeValue(forKey: username)
        } else {
            creds[username] = Data(password.utf8).base64EncodedString()
        }
        saveCredentials(creds)
    }

    private func loadCredentials() -> [String: String] {
        guard let data = try? Data(contentsOf: credentialsURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveCredentials(_ creds: [String: String]) {
        do {
            let data = try JSONEncoder().encode(creds)
            try data.write(to: credentialsURL, options: .atomic)
            // Restrict to the owner only.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)
        } catch {
            NSLog("ConfigStore: failed to save credentials: \(error)")
        }
    }
}

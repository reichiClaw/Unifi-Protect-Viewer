import Foundation

/// Loads app configuration and stores all controller/manual-stream secrets in
/// macOS Keychain. Older file-backed credentials and plaintext manual URLs are
/// migrated after a successful Keychain write/read verification.
final class ConfigStore {
    static let shared = ConfigStore()

    private let fileManager = FileManager.default

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UnifiProtectViewer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var credentialsURL: URL { directory.appendingPathComponent("credentials.json") }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfiguration()
        }
        do {
            var config = try JSONDecoder().decode(AppConfiguration.self, from: data)
            if hydrateManualStreams(in: &config) {
                save(config)
            }
            return config
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

    // MARK: - Controller credentials

    func password(host: String, username: String) -> String? {
        guard !host.isEmpty, !username.isEmpty else { return nil }
        let account = controllerAccount(host: host, username: username)
        if let password = Keychain.get(account: account) { return password }

        // Also migrate the original Keychain account format, if present.
        if let oldKeychain = Keychain.get(account: username),
           Keychain.set(oldKeychain, account: account),
           Keychain.get(account: account) == oldKeychain {
            Keychain.delete(account: username)
            return oldKeychain
        }

        // Migrate the legacy 0600/base64 credentials file.
        let creds = loadCredentials()
        guard let encoded = creds[username],
              let data = Data(base64Encoded: encoded),
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard Keychain.set(password, account: account),
              Keychain.get(account: account) == password else { return password }
        var remaining = creds
        remaining.removeValue(forKey: username)
        saveCredentials(remaining)
        return password
    }

    @discardableResult
    func setPassword(_ password: String, host: String, username: String) -> Bool {
        guard !password.isEmpty, !host.isEmpty, !username.isEmpty else { return false }
        let account = controllerAccount(host: host, username: username)
        return Keychain.set(password, account: account)
            && Keychain.get(account: account) == password
    }

    func removePassword(host: String, username: String) {
        Keychain.delete(account: controllerAccount(host: host, username: username))
    }

    private func controllerAccount(host: String, username: String) -> String {
        "controller:\(host.lowercased())|\(username)"
    }

    // MARK: - Manual stream URLs

    @discardableResult
    func setManualStreamURL(_ url: String, id: String) -> Bool {
        guard !url.isEmpty else { return false }
        return Keychain.set(url, account: manualStreamAccount(id))
            && Keychain.get(account: manualStreamAccount(id)) == url
    }

    func removeManualStreamURL(id: String) {
        Keychain.delete(account: manualStreamAccount(id))
    }

    private func manualStreamAccount(_ id: String) -> String {
        "manual-stream:\(id)"
    }

    /// Returns true when plaintext legacy data was migrated and config should be
    /// rewritten without URLs.
    private func hydrateManualStreams(in config: inout AppConfiguration) -> Bool {
        var migrated = false
        for index in config.manualCameras.indices {
            let id = config.manualCameras[index].id
            let legacyURL = config.manualCameras[index].url
            if let stored = Keychain.get(account: manualStreamAccount(id)) {
                config.manualCameras[index].url = stored
                if config.manualCameras[index].requiresSecureMigration {
                    config.manualCameras[index].requiresSecureMigration = false
                    migrated = true
                }
            } else if !legacyURL.isEmpty,
                      setManualStreamURL(legacyURL, id: id) {
                config.manualCameras[index].url = legacyURL
                config.manualCameras[index].requiresSecureMigration = false
                migrated = true
            }
        }
        return migrated
    }

    private func loadCredentials() -> [String: String] {
        guard let data = try? Data(contentsOf: credentialsURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveCredentials(_ creds: [String: String]) {
        if creds.isEmpty {
            try? fileManager.removeItem(at: credentialsURL)
            return
        }
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

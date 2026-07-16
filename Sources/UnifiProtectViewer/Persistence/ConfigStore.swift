import Foundation

/// Loads app configuration and stores all controller/manual-stream secrets in
/// macOS Keychain. Older file-backed credentials and plaintext manual URLs are
/// migrated after a successful Keychain write/read verification.
final class ConfigStore {
    static let shared = ConfigStore()

    private let fileManager = FileManager.default
    private(set) var lastWarning: String?

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
    private var backupURL: URL { directory.appendingPathComponent("config.json.bak") }
    private var credentialsURL: URL { directory.appendingPathComponent("credentials.json") }

    func load() -> AppConfiguration {
        lastWarning = nil
        guard fileManager.fileExists(atPath: configURL.path) else {
            return loadBackupOrDefaults(reason: nil)
        }
        do {
            var config = try decodeConfig(at: configURL)
            if hydrateManualStreams(in: &config) {
                if save(config, preserveCurrentAsBackup: false) {
                    // The previous file may contain plaintext legacy stream URLs.
                    try? fileManager.removeItem(at: backupURL)
                }
            }
            return config
        } catch {
            let corrupt = directory.appendingPathComponent("config.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: configURL, to: corrupt)
            return loadBackupOrDefaults(reason: "Configuration was damaged and preserved as \(corrupt.lastPathComponent).")
        }
    }

    @discardableResult
    func save(_ config: AppConfiguration, preserveCurrentAsBackup: Bool = true) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            // Verify the exact bytes before replacing the last-known-good file.
            _ = try JSONDecoder().decode(AppConfiguration.self, from: data)
            if preserveCurrentAsBackup, fileManager.fileExists(atPath: configURL.path) {
                try? fileManager.removeItem(at: backupURL)
                try fileManager.copyItem(at: configURL, to: backupURL)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            }
            try data.write(to: configURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            lastWarning = nil
            return true
        } catch {
            lastWarning = "Could not save configuration: \(error.localizedDescription)"
            NSLog("ConfigStore: \(lastWarning!)")
            return false
        }
    }

    private func decodeConfig(at url: URL) throws -> AppConfiguration {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(AppConfiguration.self, from: data)
        guard config.configVersion <= 1 else { throw StoreError.unsupportedVersion(config.configVersion) }
        return config
    }

    private func loadBackupOrDefaults(reason: String?) -> AppConfiguration {
        if fileManager.fileExists(atPath: backupURL.path),
           var backup = try? decodeConfig(at: backupURL) {
            _ = hydrateManualStreams(in: &backup)
            lastWarning = [reason, "Recovered the last-known-good configuration backup."]
                .compactMap { $0 }.joined(separator: " ")
            _ = save(backup, preserveCurrentAsBackup: false)
            return backup
        }
        lastWarning = reason
        return AppConfiguration()
    }

    private enum StoreError: LocalizedError {
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "Configuration version \(version) is newer than this app supports."
            }
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

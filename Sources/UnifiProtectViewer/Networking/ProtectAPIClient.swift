import Foundation

enum ProtectAPIError: LocalizedError {
    case notConfigured
    case invalidHost
    case authenticationFailed(Int)
    case requestFailed(Int)
    case decodingFailed(String)
    case noCredentials
    case insufficientPermissions

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "The controller connection is not configured."
        case .invalidHost: return "The controller host is invalid."
        case .authenticationFailed(let code): return "Login failed (HTTP \(code)). Check your username and password."
        case .requestFailed(let code): return "The controller returned an error (HTTP \(code))."
        case .decodingFailed(let detail): return "Failed to parse the controller response: \(detail)"
        case .noCredentials: return "No password is stored for this account."
        case .insufficientPermissions: return "This account lacks permission to modify cameras (needed to enable RTSP)."
        }
    }
}

/// Client for the (unofficial) UniFi Protect controller API.
///
/// Flow:
///   1. `GET https://{host}/` to obtain a CSRF token.
///   2. `POST https://{host}/api/auth/login` to establish a session cookie.
///   3. `GET https://{host}/proxy/protect/api/bootstrap` to enumerate cameras.
///
/// RTSP streams are served by the controller on port 7447 (rtsp) / 7441
/// (rtsps) using each channel's `rtspAlias`.
actor ProtectAPIClient {
    private var session: URLSession
    private var delegate: InsecureTrustDelegate
    private var host: String = ""
    private var csrfToken: String?
    private(set) var isAuthenticated = false

    init() {
        self.delegate = InsecureTrustDelegate(trustedHost: "")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// (Re)configure the client for a host. Resets any existing session.
    func configure(host: String) {
        let cleaned = ProtectAPIClient.normalizeHost(host)
        self.host = cleaned
        self.csrfToken = nil
        self.isAuthenticated = false
        self.delegate = InsecureTrustDelegate(trustedHost: cleaned)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    var configuredHost: String { host }

    // MARK: - Authentication

    func login(username: String, password: String) async throws {
        guard !host.isEmpty else { throw ProtectAPIError.notConfigured }
        guard let baseURL = URL(string: "https://\(host)") else { throw ProtectAPIError.invalidHost }

        // Step 1: prime the CSRF token by hitting the root.
        await primeCSRFToken(baseURL: baseURL)

        // Step 2: login.
        guard let loginURL = URL(string: "https://\(host)/api/auth/login") else { throw ProtectAPIError.invalidHost }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = csrfToken { request.setValue(token, forHTTPHeaderField: "X-CSRF-Token") }
        let body: [String: Any] = ["username": username, "password": password, "rememberMe": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProtectAPIError.requestFailed(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProtectAPIError.authenticationFailed(http.statusCode)
        }
        // Capture the rotated CSRF token, if provided.
        if let updated = http.value(forHTTPHeaderField: "X-Updated-CSRF-Token")
            ?? http.value(forHTTPHeaderField: "X-CSRF-Token") {
            csrfToken = updated
        }
        isAuthenticated = true
    }

    private func primeCSRFToken(baseURL: URL) async {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        if let (_, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           let token = http.value(forHTTPHeaderField: "X-CSRF-Token") {
            csrfToken = token
        }
    }

    // MARK: - Bootstrap

    func fetchBootstrap() async throws -> ProtectBootstrap {
        let data = try await authedRequest(path: "/proxy/protect/api/bootstrap", method: "GET")
        do {
            return try JSONDecoder().decode(ProtectBootstrap.self, from: data)
        } catch {
            throw ProtectAPIError.decodingFailed(String(describing: error))
        }
    }

    /// Enable RTSP on the highest-resolution channel of each camera that has it
    /// disabled. Returns the IDs of cameras that were updated.
    @discardableResult
    func enableRTSPIfNeeded(for cameras: [ProtectCamera]) async -> [String] {
        var updated: [String] = []
        for camera in cameras {
            let hasEnabled = camera.channels.contains { ($0.isRtspEnabled ?? false) && ($0.rtspAlias != nil) }
            if hasEnabled { continue }
            if (try? await enableRTSP(cameraID: camera.id, channels: camera.channels)) != nil {
                updated.append(camera.id)
            }
        }
        return updated
    }

    private func enableRTSP(cameraID: String, channels: [ProtectChannel]) async throws {
        // Build a channels payload enabling RTSP on all channels. Preserve
        // channel ids so the controller maps them correctly.
        let channelPayload: [[String: Any]] = channels.map { ch in
            ["id": ch.id, "isRtspEnabled": true]
        }
        let body: [String: Any] = ["channels": channelPayload]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await authedRequest(path: "/proxy/protect/api/cameras/\(cameraID)", method: "PATCH", body: data)
    }

    // MARK: - Stream URLs

    nonisolated static func streamURL(host: String,
                                      camera: ProtectCamera,
                                      quality: StreamQuality,
                                      useRTSPS: Bool) -> URL? {
        let cleanedHost = normalizeHost(host)
        // Among channels with an rtspAlias, pick by quality preference.
        let usable = camera.channels.filter { $0.rtspAlias?.isEmpty == false }
        guard !usable.isEmpty else { return nil }

        let chosen: ProtectChannel
        if let match = quality.preferredChannelOrder
            .compactMap({ idx in usable.first(where: { $0.id == idx }) })
            .first {
            chosen = match
        } else {
            chosen = usable[0]
        }
        guard let alias = chosen.rtspAlias else { return nil }

        if useRTSPS {
            return URL(string: "rtsps://\(cleanedHost):7441/\(alias)?enableSrtp")
        } else {
            return URL(string: "rtsp://\(cleanedHost):7447/\(alias)")
        }
    }

    // MARK: - Helpers

    private func authedRequest(path: String, method: String, body: Data? = nil) async throws -> Data {
        guard !host.isEmpty else { throw ProtectAPIError.notConfigured }
        guard let url = URL(string: "https://\(host)\(path)") else { throw ProtectAPIError.invalidHost }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = csrfToken { request.setValue(token, forHTTPHeaderField: "X-CSRF-Token") }
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProtectAPIError.requestFailed(-1) }
        if let updated = http.value(forHTTPHeaderField: "X-Updated-CSRF-Token") {
            csrfToken = updated
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            if method != "GET" { throw ProtectAPIError.insufficientPermissions }
            throw ProtectAPIError.authenticationFailed(http.statusCode)
        default:
            throw ProtectAPIError.requestFailed(http.statusCode)
        }
    }

    nonisolated static func normalizeHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacingOccurrences(of: "https://", with: "")
        h = h.replacingOccurrences(of: "http://", with: "")
        if let slash = h.firstIndex(of: "/") {
            h = String(h[..<slash])
        }
        return h
    }
}

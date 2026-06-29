import Foundation

enum ProtectAPIError: LocalizedError {
    case notConfigured
    case invalidHost
    case invalidCredentials
    case twoFactorRequired
    case authenticationFailed(Int)
    case requestFailed(Int)
    case decodingFailed(String)
    case noCredentials
    case insufficientPermissions

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "The controller connection is not configured."
        case .invalidHost: return "The controller host is invalid."
        case .invalidCredentials:
            return "Login failed (HTTP 401): invalid credentials. Use a LOCAL UniFi Protect account — not your Ubiquiti cloud (account.ui.com) login. In UniFi Protect go to Settings → Admins & Users → Add, create a user with a local username/password and grant it access to Protect. If that account has two-factor authentication enabled, enter a current 2FA code in Settings, or disable 2FA for it."
        case .twoFactorRequired:
            return "This account requires two-factor authentication. Enter a current 2FA code in Settings → Connection and connect again."
        case .authenticationFailed(let code): return "The controller rejected the request (HTTP \(code)). The session may have expired, or this account may not have access to UniFi Protect. Check Console → Logs for details."
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
    /// Session cookie (e.g. `TOKEN=…`) captured from responses and resent on
    /// every request. Managed manually instead of relying on URLSession's
    /// cookie storage, which is unreliable for this flow.
    private var sessionCookie: String?
    private(set) var isAuthenticated = false

    init() {
        self.delegate = InsecureTrustDelegate(trustedHost: "")
        self.session = ProtectAPIClient.makeSession(delegate: delegate)
    }

    private static func makeSession(delegate: InsecureTrustDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // We manage cookies and CSRF tokens by hand (see sessionCookie/csrfToken).
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// (Re)configure the client for a host. Resets any existing session.
    func configure(host: String) {
        let cleaned = ProtectAPIClient.normalizeHost(host)
        self.host = cleaned
        self.csrfToken = nil
        self.sessionCookie = nil
        self.isAuthenticated = false
        self.delegate = InsecureTrustDelegate(trustedHost: cleaned)
        self.session = ProtectAPIClient.makeSession(delegate: delegate)
    }

    /// Attach the CSRF token and session cookie to an outgoing request.
    private func applyAuth(to request: inout URLRequest) {
        if let token = csrfToken { request.setValue(token, forHTTPHeaderField: "X-CSRF-Token") }
        if let cookie = sessionCookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    }

    /// Capture rotated CSRF token and session cookie from a response.
    private func captureAuth(from http: HTTPURLResponse) {
        if let updated = http.value(forHTTPHeaderField: "X-Updated-CSRF-Token")
            ?? http.value(forHTTPHeaderField: "X-CSRF-Token") {
            csrfToken = updated
        }
        if let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") {
            // Keep only the `name=value` portion (drop Path/HttpOnly/etc.).
            let first = setCookie.split(separator: ";").first.map(String.init) ?? setCookie
            if first.contains("=") { sessionCookie = first }
        }
    }

    var configuredHost: String { host }

    // MARK: - Authentication

    func login(username: String, password: String, mfaToken: String = "") async throws {
        guard !host.isEmpty else { throw ProtectAPIError.notConfigured }
        guard let baseURL = URL(string: "https://\(host)") else { throw ProtectAPIError.invalidHost }

        // Step 1: prime the CSRF token by hitting the root.
        await primeCSRFToken(baseURL: baseURL)

        // Step 2: login. The body mirrors the Protect web UI, including the
        // `token` field used for two-factor authentication (empty if unused).
        var (data, http) = try await performLogin(username: username, password: password, mfaToken: mfaToken)

        // Some controllers require a valid CSRF token on the login request
        // itself. If we didn't have one and the first attempt failed, fetch a
        // token from the controller root and retry once.
        if !(200...299).contains(http.statusCode), csrfToken == nil {
            await primeCSRFToken(baseURL: baseURL)
            if csrfToken != nil {
                (data, http) = try await performLogin(username: username, password: password, mfaToken: mfaToken)
            }
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyText = (String(data: data, encoding: .utf8) ?? "")
            appLog("Login failed HTTP \(http.statusCode): \(bodyText)", .error)
            let lower = bodyText.lowercased()
            if http.statusCode == 401 || http.statusCode == 499 {
                if lower.contains("2fa") || lower.contains("mfa") || lower.contains("two") || lower.contains("otp") {
                    throw ProtectAPIError.twoFactorRequired
                }
                throw ProtectAPIError.invalidCredentials
            }
            throw ProtectAPIError.authenticationFailed(http.statusCode)
        }

        captureAuth(from: http)
        isAuthenticated = true
    }

    private func performLogin(username: String, password: String, mfaToken: String) async throws -> (Data, HTTPURLResponse) {
        guard let loginURL = URL(string: "https://\(host)/api/auth/login") else { throw ProtectAPIError.invalidHost }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)
        let body: [String: Any] = [
            "username": username,
            "password": password,
            "token": mfaToken,
            "rememberMe": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProtectAPIError.requestFailed(-1) }
        captureAuth(from: http)
        return (data, http)
    }

    private func primeCSRFToken(baseURL: URL) async {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        applyAuth(to: &request)
        if let (_, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse {
            captureAuth(from: http)
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

    /// Lightweight fetch of just the cameras (used to poll online/connection
    /// status without pulling the whole bootstrap).
    func fetchCameras() async throws -> [ProtectCamera] {
        let data = try await authedRequest(path: "/proxy/protect/api/cameras", method: "GET")
        do {
            return try JSONDecoder().decode([ProtectCamera].self, from: data)
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

    // MARK: - PTZ control (UniFi Protect integration API)

    /// Move a PTZ camera to a saved preset. Slot -1 is the home position,
    /// 0+ are user-configured presets.
    func ptzGoto(cameraID: String, slot: Int) async throws {
        _ = try await authedRequest(path: "/proxy/protect/integration/v1/cameras/\(cameraID)/ptz/goto/\(slot)", method: "POST")
    }

    /// Start a PTZ patrol (tour) by slot.
    func ptzPatrolStart(cameraID: String, slot: Int) async throws {
        _ = try await authedRequest(path: "/proxy/protect/integration/v1/cameras/\(cameraID)/ptz/patrol/start/\(slot)", method: "POST")
    }

    /// Stop the active PTZ patrol.
    func ptzPatrolStop(cameraID: String) async throws {
        _ = try await authedRequest(path: "/proxy/protect/integration/v1/cameras/\(cameraID)/ptz/patrol/stop", method: "POST")
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProtectAPIError.requestFailed(-1) }
        captureAuth(from: http)
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            appLog("\(method) \(path) failed HTTP \(http.statusCode): \(bodyText)", .error)
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

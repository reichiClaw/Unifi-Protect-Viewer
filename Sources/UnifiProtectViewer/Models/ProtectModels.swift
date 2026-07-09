import Foundation

/// Subset of the UniFi Protect `bootstrap` payload that we care about.
///
/// The full bootstrap object is large; we decode only the fields needed to
/// enumerate cameras and build RTSP stream URLs. Unknown keys are ignored.
struct ProtectBootstrap: Decodable {
    let nvr: ProtectNVR?
    let cameras: [ProtectCamera]
    let lastUpdateId: String?

    enum CodingKeys: String, CodingKey { case nvr, cameras, lastUpdateId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nvr = try c.decodeIfPresent(ProtectNVR.self, forKey: .nvr)
        cameras = try c.decodeIfPresent([ProtectCamera].self, forKey: .cameras) ?? []
        lastUpdateId = try c.decodeIfPresent(String.self, forKey: .lastUpdateId)
    }
}

struct ProtectNVR: Decodable {
    let id: String?
    let name: String?
    let host: String?
    let version: String?
}

/// A camera as reported by the controller.
struct ProtectCamera: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let mac: String?
    let type: String?
    let state: String?
    let isConnected: Bool?
    let channels: [ProtectChannel]
    let featureFlags: ProtectFeatureFlags?
    /// For user-added (non-UniFi) streams: the direct stream URL to play.
    /// `nil` for real Protect cameras (their URL is built from channels).
    let directURL: String?

    /// True for a user-added custom stream.
    var isManual: Bool { directURL != nil }

    /// Construct a manual (non-UniFi) camera from a direct stream URL.
    init(manualID: String, name: String, url: String) {
        self.id = manualID
        self.name = name
        self.mac = nil
        self.type = "manual"
        self.state = "connected"
        self.isConnected = true
        self.channels = []
        self.featureFlags = nil
        self.directURL = url
    }

    /// Whether this camera supports pan/tilt/zoom.
    var isPTZ: Bool {
        (featureFlags?.isPtz ?? false) || (featureFlags?.canOpticalZoom ?? false) || (type?.lowercased().contains("ptz") ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, mac, type, state, isConnected, channels, featureFlags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        isConnected = try c.decodeIfPresent(Bool.self, forKey: .isConnected)
        channels = try c.decodeIfPresent([ProtectChannel].self, forKey: .channels) ?? []
        featureFlags = try c.decodeIfPresent(ProtectFeatureFlags.self, forKey: .featureFlags)
        directURL = nil
    }

    /// Best-effort display name.
    var displayName: String {
        name?.isEmpty == false ? name! : (mac ?? id)
    }

    var isOnline: Bool {
        // Manual/custom streams are always considered online.
        if directURL != nil { return true }
        // Treat as offline if *either* indicator reports not-connected, so a
        // camera that drops is reflected promptly. (Previously used OR, which
        // kept a camera "online" if only one of the two fields had updated.)
        if isConnected == false { return false }
        if let s = state, s.caseInsensitiveCompare("connected") != .orderedSame { return false }
        return true
    }

    static func == (lhs: ProtectCamera, rhs: ProtectCamera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Subset of a camera's feature flags (used to detect PTZ capability).
struct ProtectFeatureFlags: Decodable, Hashable {
    let isPtz: Bool?
    let canOpticalZoom: Bool?

    enum CodingKeys: String, CodingKey { case isPtz, canOpticalZoom }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isPtz = try c.decodeIfPresent(Bool.self, forKey: .isPtz)
        canOpticalZoom = try c.decodeIfPresent(Bool.self, forKey: .canOpticalZoom)
    }
}

/// A camera channel (resolution profile). RTSP is exposed per-channel.
struct ProtectChannel: Decodable, Hashable {
    let id: Int
    let name: String?
    let width: Int?
    let height: Int?
    let fps: Int?
    let isRtspEnabled: Bool?
    let rtspAlias: String?

    /// Human readable quality label, e.g. "High (1920x1080)".
    var qualityLabel: String {
        let base = name ?? "Channel \(id)"
        if let w = width, let h = height {
            return "\(base) (\(w)x\(h))"
        }
        return base
    }
}

/// Resolution preference when picking a channel for a stream.
enum StreamQuality: String, Codable, CaseIterable, Identifiable {
    case high
    case medium
    case low

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Preferred channel index ordering for this quality. UniFi Protect
    /// conventionally orders channels high→low (0,1,2).
    var preferredChannelOrder: [Int] {
        switch self {
        case .high: return [0, 1, 2]
        case .medium: return [1, 2, 0]
        case .low: return [2, 1, 0]
        }
    }
}

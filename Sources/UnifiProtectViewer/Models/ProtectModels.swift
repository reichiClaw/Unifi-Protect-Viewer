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

    enum CodingKeys: String, CodingKey {
        case id, name, mac, type, state, isConnected, channels
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
    }

    /// Best-effort display name.
    var displayName: String {
        name?.isEmpty == false ? name! : (mac ?? id)
    }

    var isOnline: Bool {
        (isConnected ?? false) || (state?.lowercased() == "connected")
    }

    static func == (lhs: ProtectCamera, rhs: ProtectCamera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

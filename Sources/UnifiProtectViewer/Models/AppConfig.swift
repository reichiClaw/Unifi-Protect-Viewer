import Foundation

/// Connection details for a UniFi Protect controller.
///
/// The password is *not* stored in this struct when persisted to disk; it lives
/// in the macOS Keychain (see `ConfigStore`). Only the non-secret metadata is
/// encoded here.
struct ConnectionSettings: Codable, Equatable {
    /// Hostname or IP of the UniFi OS console / NVR (no scheme).
    var host: String = ""
    /// Username for a local UniFi Protect account.
    var username: String = ""
    /// Whether to use RTSPS (encrypted, port 7441) instead of RTSP (7447).
    var useRTSPS: Bool = false
    /// Legacy single quality (kept for migration of older configs).
    var defaultQuality: StreamQuality = .high
    /// Quality used for tiles in the grid (a view may override it).
    var gridQuality: StreamQuality = .high
    /// Quality used when a single camera is shown fullscreen.
    var fullscreenQuality: StreamQuality = .high
    /// Automatically enable RTSP on cameras that have it disabled.
    var autoEnableRTSP: Bool = true
    /// Network/jitter buffer in milliseconds. Higher = more latency but more
    /// resilient to network hiccups (recommended for a 24/7 wall).
    var streamCacheMs: Int = 1500

    init() {}

    /// Resilient decoding so adding fields never invalidates an existing
    /// saved configuration (missing keys fall back to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        useRTSPS = try c.decodeIfPresent(Bool.self, forKey: .useRTSPS) ?? false
        let legacyQuality = try c.decodeIfPresent(StreamQuality.self, forKey: .defaultQuality) ?? .high
        defaultQuality = legacyQuality
        gridQuality = try c.decodeIfPresent(StreamQuality.self, forKey: .gridQuality) ?? legacyQuality
        fullscreenQuality = try c.decodeIfPresent(StreamQuality.self, forKey: .fullscreenQuality) ?? .high
        autoEnableRTSP = try c.decodeIfPresent(Bool.self, forKey: .autoEnableRTSP) ?? true
        streamCacheMs = try c.decodeIfPresent(Int.self, forKey: .streamCacheMs) ?? 1500
    }

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The supported layout shapes for a grid view.
enum GridLayout: String, Codable, CaseIterable, Identifiable {
    case auto          // pick columns based on camera count
    case single        // 1x1
    case grid2x2       // 2x2
    case grid3x3       // 3x3
    case grid4x4       // 4x4
    case grid1x2       // 1 row, 2 cols
    case grid2x1       // 2 rows, 1 col
    case grid3x2       // 3 cols, 2 rows
    case grid4x3       // 4 cols, 3 rows

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .single: return "1 × 1"
        case .grid2x2: return "2 × 2"
        case .grid3x3: return "3 × 3"
        case .grid4x4: return "4 × 4"
        case .grid1x2: return "2 × 1"
        case .grid2x1: return "1 × 2"
        case .grid3x2: return "3 × 2"
        case .grid4x3: return "4 × 3"
        }
    }

    /// Number of columns for a given camera count. Returns nil for `.auto`,
    /// which is computed dynamically by the view.
    var fixedColumns: Int? {
        switch self {
        case .auto: return nil
        case .single: return 1
        case .grid2x2: return 2
        case .grid3x3: return 3
        case .grid4x4: return 4
        case .grid1x2: return 2
        case .grid2x1: return 1
        case .grid3x2: return 3
        case .grid4x3: return 4
        }
    }
}

/// A configurable, named grid view: an ordered set of cameras plus a layout.
struct CameraGridConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var layout: GridLayout = .auto
    /// Ordered list of camera IDs to display in this view.
    var cameraIDs: [String] = []
    /// Optional per-view quality override.
    var quality: StreamQuality? = nil

    static func == (lhs: CameraGridConfig, rhs: CameraGridConfig) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.layout == rhs.layout &&
        lhs.cameraIDs == rhs.cameraIDs && lhs.quality == rhs.quality
    }
}

/// Root persisted document for the app.
struct AppConfiguration: Codable {
    var connection: ConnectionSettings = ConnectionSettings()
    var views: [CameraGridConfig] = []
    /// Local control server (Stream Deck bridge) settings.
    var control: ControlServerSettings = ControlServerSettings()
}

/// Settings for the local HTTP/WebSocket control server used by the
/// Stream Deck plugin (and any other automation).
struct ControlServerSettings: Codable, Equatable {
    var enabled: Bool = true
    var port: UInt16 = 8723
    /// Shared secret required on control requests. Empty = no auth (local only).
    var token: String = ""
}

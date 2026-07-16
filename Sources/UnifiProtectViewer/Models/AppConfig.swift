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
    /// Connect automatically when the app launches.
    var autoConnect: Bool = true
    /// Network/jitter buffer in milliseconds. Higher = more latency but more
    /// resilient to network hiccups (recommended for a 24/7 wall).
    var streamCacheMs: Int = 1500
    /// Use the Mac's VideoToolbox hardware decoder instead of software decoding.
    /// Offloads H.264/H.265 decode to dedicated silicon — big CPU savings and
    /// lower memory pressure on low-RAM machines. Turn off only if a stream
    /// shows decode artifacts.
    var hardwareDecoding: Bool = true

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
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        streamCacheMs = try c.decodeIfPresent(Int.self, forKey: .streamCacheMs) ?? 1500
        hardwareDecoding = try c.decodeIfPresent(Bool.self, forKey: .hardwareDecoding) ?? true
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

/// A user-added stream that isn't a UniFi Protect camera (e.g. a third-party
/// RTSP/HTTP camera). Played by the same engine as Protect cameras.
struct ManualCamera: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    /// Runtime-only. Persisted securely in Keychain; decoded here only to
    /// migrate configurations written by older versions.
    var url: String
    var requiresSecureMigration: Bool = false

    init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
        self.requiresSecureMigration = false
    }

    enum CodingKeys: String, CodingKey { case id, name, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        requiresSecureMigration = !url.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        // Preserve legacy data only if Keychain migration failed; remove it
        // from the next save immediately after secure storage succeeds.
        if requiresSecureMigration { try c.encode(url, forKey: .url) }
    }
}

/// Root persisted document for the app.
struct AppConfiguration: Codable {
    var connection: ConnectionSettings = ConnectionSettings()
    var views: [CameraGridConfig] = []
    /// Local control server (Stream Deck bridge) settings.
    var control: ControlServerSettings = ControlServerSettings()
    /// Clicking the fullscreen single-camera view returns to the grid.
    var tapFullscreenToExit: Bool = true
    /// Number of on-screen PTZ preset buttons shown for a fullscreen PTZ camera.
    var ptzPresetCount: Int = 4
    /// User-added non-UniFi streams.
    var manualCameras: [ManualCamera] = []

    init() {}

    /// Resilient decoding so adding fields never invalidates a saved config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connection = try c.decodeIfPresent(ConnectionSettings.self, forKey: .connection) ?? ConnectionSettings()
        views = try c.decodeIfPresent([CameraGridConfig].self, forKey: .views) ?? []
        control = try c.decodeIfPresent(ControlServerSettings.self, forKey: .control) ?? ControlServerSettings()
        tapFullscreenToExit = try c.decodeIfPresent(Bool.self, forKey: .tapFullscreenToExit) ?? true
        ptzPresetCount = try c.decodeIfPresent(Int.self, forKey: .ptzPresetCount) ?? 4
        manualCameras = try c.decodeIfPresent([ManualCamera].self, forKey: .manualCameras) ?? []
    }
}

/// Settings for the local HTTP/WebSocket control server used by the
/// Stream Deck plugin (and any other automation).
struct ControlServerSettings: Codable, Equatable {
    var enabled: Bool = true
    var port: UInt16 = 8723
    /// Bind to all IPv4 interfaces so another machine can control the viewer.
    /// Disabled by default: the Stream Deck normally runs on this Mac.
    var allowLAN: Bool = false
    /// Shared secret required on control requests. Empty = no auth (local only).
    var token: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8723
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    }

    static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

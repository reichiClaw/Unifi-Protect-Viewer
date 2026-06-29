import Foundation

/// Snapshot of the app state exposed to external controllers (Stream Deck).
struct ControlSnapshot: Codable {
    var connection: String          // "disconnected" | "connecting" | "connected" | "error"
    var currentViewID: String?
    var currentViewIndex: Int?
    var currentViewName: String?
    var fullscreenCameraID: String?
    var fullscreenCameraName: String?
    /// True when the currently fullscreen camera supports PTZ — the Stream Deck
    /// plugin uses this to auto-switch to its PTZ control profile.
    var fullscreenCameraPtz: Bool
    var views: [ControlViewInfo]
    var cameras: [ControlCameraInfo]
}

struct ControlViewInfo: Codable {
    var id: String
    var index: Int
    var name: String
    var cameraCount: Int
}

struct ControlCameraInfo: Codable {
    var id: String
    var name: String
    var online: Bool
    var ptz: Bool
}

/// Result returned to a control client after a command.
struct ControlResult: Codable {
    var ok: Bool
    var message: String?
    var snapshot: ControlSnapshot?
}

/// Implemented by `AppState` to service control commands.
///
/// The control server always invokes these methods on the main thread (via
/// `DispatchQueue.main.sync`), so implementations may safely touch UI state.
protocol ControlServerHandler: AnyObject {
    func controlSnapshot() -> ControlSnapshot
    func controlSelectView(id: String?, index: Int?, name: String?) -> Bool
    func controlNextView()
    func controlPreviousView()
    func controlShowFullscreen(cameraID: String?, index: Int?, name: String?) -> Bool
    func controlExitFullscreen()
    func controlToggleFullscreen(cameraID: String?, index: Int?, name: String?) -> Bool
    func controlReconnect()
    /// PTZ control. `action` is one of: "goto", "home", "patrol-start",
    /// "patrol-stop". `slot` is the preset/patrol slot (ignored for stop/home).
    func controlPTZ(cameraID: String?, index: Int?, name: String?, action: String, slot: Int) -> Bool
}

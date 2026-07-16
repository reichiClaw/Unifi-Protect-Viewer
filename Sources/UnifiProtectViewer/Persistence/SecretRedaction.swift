import Foundation

enum SecretRedaction {
    /// Return enough URL information to diagnose routing without exposing
    /// credentials, query tokens, fragments, or camera stream aliases.
    static func url(_ url: URL?) -> String {
        guard let url = url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "(none)"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if !components.path.isEmpty && components.path != "/" {
            components.path = "/<redacted>"
        }
        return components.string ?? "\(url.scheme ?? "stream")://<redacted>"
    }
}

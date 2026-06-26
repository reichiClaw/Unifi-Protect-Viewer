import Foundation

/// URLSession delegate that accepts the self-signed certificate presented by a
/// UniFi Protect controller.
///
/// UniFi OS consoles ship with a self-signed certificate for their local
/// hostname/IP. Standard TLS validation therefore fails. We scope the
/// override to the single host the user configured to limit exposure.
final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
    private let trustedHost: String

    init(trustedHost: String) {
        self.trustedHost = trustedHost
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == trustedHost,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
    }
}

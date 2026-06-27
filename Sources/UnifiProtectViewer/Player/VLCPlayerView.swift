import SwiftUI
import AppKit
import VLCKitSPM

/// Playback state surfaced to the tile UI.
enum PlaybackStatus: Equatable {
    case idle, buffering, playing, error
}

/// Observable per-camera status so SwiftUI tiles can show overlays.
final class CameraPlaybackStatus: ObservableObject {
    @Published var state: PlaybackStatus = .idle
}

/// Owns and **reuses** one `VLCMediaPlayer` (and its video surface) per camera.
///
/// Design goals (live control-room wall, 24/7):
/// - Switching views / fullscreen just **reparents** the already-playing video
///   surface — instant, no black frame, no player churn.
/// - Playback is started on the **main thread** (required by VLCKit on macOS);
///   teardown happens on a background queue so the UI never blocks.
/// - A watchdog keeps streams alive, but judges health by **player state** (not
///   by a fragile time-progress heuristic that false-flags healthy streams),
///   recovers at most a few streams per tick, and backs off per camera so a
///   permanently-offline camera can't thrash the whole app.
final class CameraPlayerManager: NSObject, VLCMediaPlayerDelegate {
    static let shared = CameraPlayerManager()

    private final class Entry {
        let id: String
        var player = VLCMediaPlayer()
        let surface = NSView()
        let status = CameraPlaybackStatus()
        let controlQueue: DispatchQueue
        var requestedURL: URL?
        var activeURL: URL?
        var triedFallback = false
        var stopWork: DispatchWorkItem?
        weak var hostedIn: NSView?
        var caching = 1500
        var muted = true
        // Watchdog bookkeeping.
        var lastHealthyAt = Date()
        var recoveryAttempts = 0
        var nextRecoveryAllowedAt = Date.distantPast
        init(id: String) {
            self.id = id
            controlQueue = DispatchQueue(label: "com.unifiprotectviewer.vlc.\(id)")
        }
    }

    private var entries: [String: Entry] = [:]
    /// Keep a stopped stream warm this long after it leaves the screen so quick
    /// back-and-forth resumes instantly.
    private let graceSeconds: TimeInterval = 10
    private var watchdog: Timer?
    private let watchdogInterval: TimeInterval = 4
    /// A stream must be continuously unhealthy for this long before we recover
    /// it (tolerates normal startup buffering).
    private let unhealthyGrace: TimeInterval = 12
    /// Never recover more than this many streams in a single tick — prevents a
    /// network blip from triggering a thundering herd of simultaneous restarts.
    private let maxRecoveriesPerTick = 3

    override init() {
        super.init()
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    // MARK: Public API (main thread)

    func status(for id: String) -> CameraPlaybackStatus {
        entry(for: id).status
    }

    func attach(cameraID id: String, to host: NSView, url: URL, caching: Int, muted: Bool) {
        let e = entry(for: id)
        e.stopWork?.cancel(); e.stopWork = nil
        e.caching = caching
        e.muted = muted

        if e.surface.superview !== host {
            e.surface.removeFromSuperview()
            e.surface.frame = host.bounds
            e.surface.autoresizingMask = [.width, .height]
            host.addSubview(e.surface)
        }
        e.hostedIn = host

        if e.requestedURL != url {
            e.requestedURL = url
            e.activeURL = url
            e.triedFallback = false
            resetHealth(e)
            start(e)
        } else {
            switch e.player.state {
            case .playing, .buffering, .opening, .esAdded:
                break // already running — keep it
            default:
                resetHealth(e)
                start(e)
            }
        }
    }

    func detach(cameraID id: String, from host: NSView) {
        guard let e = entries[id], e.hostedIn === host else { return }
        e.surface.removeFromSuperview()
        e.hostedIn = nil
        e.stopWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak e] in
            guard let self = self, let e = e, e.hostedIn == nil else { return }
            self.stop(e)
        }
        e.stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds, execute: work)
    }

    func stopAll() {
        for (_, e) in entries {
            e.stopWork?.cancel(); e.stopWork = nil
            stop(e)
        }
    }

    // MARK: Internals

    private func entry(for id: String) -> Entry {
        if let e = entries[id] { return e }
        let e = Entry(id: id)
        e.surface.wantsLayer = true
        e.surface.layer?.backgroundColor = NSColor.black.cgColor
        e.player.drawable = e.surface
        e.player.delegate = self
        entries[id] = e
        return e
    }

    private func resetHealth(_ e: Entry) {
        let now = Date()
        e.lastHealthyAt = now
        e.recoveryAttempts = 0
        e.nextRecoveryAllowedAt = now
    }

    private func makeMedia(url: URL, caching: Int) -> VLCMedia {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(caching)")
        media.addOption(":live-caching=\(caching)")
        media.addOption(":rtsp-tcp")
        media.addOption(":rtsp-frame-buffer-size=1000000")
        media.addOption(":no-audio")
        return media
    }

    /// Start (or resume) playback. The VLC calls run on the **main thread**
    /// (required for video output on macOS) but via `async` so nothing blocks.
    private func start(_ e: Entry) {
        guard let url = e.activeURL else { return }
        setStatus(e, .buffering)
        e.lastHealthyAt = Date()
        appLog("Player[\(e.id)]: start \(url.absoluteString)", .debug)
        let caching = e.caching
        DispatchQueue.main.async { [weak self, weak e] in
            guard let self = self, let e = e else { return }
            e.player.media = self.makeMedia(url: url, caching: caching)
            e.player.play()
        }
    }

    /// Clean stop (background) → restart (main). Used for recovery.
    private func restart(_ e: Entry) {
        guard let url = e.activeURL else { return }
        setStatus(e, .buffering)
        e.lastHealthyAt = Date()
        let caching = e.caching
        e.controlQueue.async { [weak self, weak e] in
            guard let e = e else { return }
            e.player.stop()
            DispatchQueue.main.async {
                guard let self = self else { return }
                e.player.media = self.makeMedia(url: url, caching: caching)
                e.player.play()
            }
        }
    }

    private func stop(_ e: Entry) {
        setStatus(e, .idle)
        e.controlQueue.async {
            e.player.stop()
        }
    }

    // MARK: Watchdog

    private func isHealthy(_ e: Entry) -> Bool {
        switch e.player.state {
        case .playing, .esAdded:
            return true
        default:
            return false
        }
    }

    private func checkHealth() {
        let now = Date()
        var budget = maxRecoveriesPerTick
        for e in entries.values where e.hostedIn != nil {
            if isHealthy(e) {
                e.lastHealthyAt = now
                e.recoveryAttempts = 0
                e.nextRecoveryAllowedAt = now
                continue
            }
            guard budget > 0,
                  now.timeIntervalSince(e.lastHealthyAt) >= unhealthyGrace,
                  now >= e.nextRecoveryAllowedAt else { continue }
            budget -= 1
            recover(e, now: now)
        }
    }

    private func recover(_ e: Entry, now: Date) {
        if applyFallback(e) { return } // rtsps→rtsp, counts as the recovery
        e.recoveryAttempts += 1
        // Exponential-ish backoff so a dead camera settles to infrequent retries.
        let backoff = min(15.0 * Double(e.recoveryAttempts), 300.0)
        e.nextRecoveryAllowedAt = now.addingTimeInterval(backoff)
        appLog("Player[\(e.id)]: unhealthy — restarting (attempt \(e.recoveryAttempts), next try in \(Int(backoff))s)", .warn)
        restart(e)
    }

    /// UniFi RTSPS (7441, TLS+SRTP) isn't reliably supported by libvlc, so on
    /// failure switch to the unencrypted RTSP equivalent on 7447.
    private func applyFallback(_ e: Entry) -> Bool {
        guard !e.triedFallback,
              let active = e.activeURL, active.scheme?.lowercased() == "rtsps",
              var comps = URLComponents(url: active, resolvingAgainstBaseURL: false) else { return false }
        comps.scheme = "rtsp"
        comps.port = 7447
        comps.query = nil
        guard let fb = comps.url else { return false }
        e.triedFallback = true
        e.activeURL = fb
        appLog("Player[\(e.id)]: RTSPS failed — falling back to \(fb.absoluteString)", .warn)
        restart(e)
        return true
    }

    private func setStatus(_ e: Entry, _ s: PlaybackStatus) {
        DispatchQueue.main.async {
            if e.status.state != s { e.status.state = s }
        }
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let object = aNotification.object
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let player = object as? VLCMediaPlayer,
                  let e = self.entries.values.first(where: { $0.player === player }) else { return }
            self.handleState(e)
        }
    }

    private func handleState(_ e: Entry) {
        switch e.player.state {
        case .playing, .esAdded:
            e.recoveryAttempts = 0
            e.nextRecoveryAllowedAt = Date()
            e.lastHealthyAt = Date()
            setStatus(e, .playing)
        case .buffering, .opening:
            setStatus(e, .buffering)
        case .error:
            appLog("Player[\(e.id)]: ERROR \(e.activeURL?.absoluteString ?? "")", .error)
            setStatus(e, .error)
            // Let the watchdog recover promptly (respecting backoff).
            if e.hostedIn != nil { e.lastHealthyAt = .distantPast }
        case .ended, .stopped:
            if e.hostedIn != nil {
                setStatus(e, .buffering)
                e.lastHealthyAt = .distantPast
            }
        default:
            break
        }
    }
}

// MARK: - SwiftUI video view

/// A lightweight SwiftUI view that hosts a camera's (pooled) video surface.
struct CameraVideoView: NSViewRepresentable {
    let cameraID: String
    let url: URL
    var caching: Int = 1500
    var muted: Bool = true

    func makeNSView(context: Context) -> HostView {
        let host = HostView()
        host.configure(cameraID: cameraID, url: url, caching: caching, muted: muted)
        return host
    }

    func updateNSView(_ host: HostView, context: Context) {
        host.configure(cameraID: cameraID, url: url, caching: caching, muted: muted)
    }

    static func dismantleNSView(_ host: HostView, coordinator: Void) {
        CameraPlayerManager.shared.detach(cameraID: host.cameraID, from: host)
    }
}

/// Container that hosts a pooled camera surface while it is in a window.
final class HostView: NSView {
    private(set) var cameraID = ""
    private var url: URL?
    private var caching = 1500
    private var muted = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func configure(cameraID: String, url: URL, caching: Int, muted: Bool) {
        if self.cameraID != cameraID, !self.cameraID.isEmpty {
            CameraPlayerManager.shared.detach(cameraID: self.cameraID, from: self)
        }
        self.cameraID = cameraID
        self.url = url
        self.caching = caching
        self.muted = muted
        if window != nil { attachIfPossible() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            attachIfPossible()
        } else if !cameraID.isEmpty {
            CameraPlayerManager.shared.detach(cameraID: cameraID, from: self)
        }
    }

    private func attachIfPossible() {
        guard let url = url, !cameraID.isEmpty else { return }
        CameraPlayerManager.shared.attach(cameraID: cameraID, to: self, url: url, caching: caching, muted: muted)
    }
}

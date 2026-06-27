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
/// Why: creating/destroying players every time the grid or fullscreen view
/// changes is slow, causes black frames (a cold player has nothing to show
/// yet), and crashes under rapid switching (concurrent start/stop and dealloc
/// races). Instead we keep a player alive per camera and, when the UI changes,
/// simply **reparent** its already-rendering surface into the new host view —
/// which is instant and seamless. Players that go off-screen are stopped after
/// a short grace period (so rapid back-and-forth keeps them warm), and all
/// start/stop calls for a given player are serialized to avoid races.
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
        var retryCount = 0
        var retryWork: DispatchWorkItem?
        var stopWork: DispatchWorkItem?
        weak var hostedIn: NSView?
        var caching = 1500
        var muted = true
        // Health tracking for the watchdog.
        var lastTimeMs = -1
        var unhealthyTicks = 0
        var softRestarts = 0
        init(id: String) {
            self.id = id
            controlQueue = DispatchQueue(label: "com.unifiprotectviewer.vlc.\(id)")
        }
    }

    private var entries: [String: Entry] = [:]
    /// Keep a stopped stream's player around (warm) for this long after it goes
    /// off-screen, so flipping back to it resumes instantly.
    private let graceSeconds: TimeInterval = 10
    private var watchdog: Timer?
    private let watchdogInterval: TimeInterval = 4
    /// Consecutive watchdog ticks without healthy progress before recovering.
    private let unhealthyThreshold = 3
    /// After this many soft restarts that don't recover, recreate the player.
    private let maxSoftRestarts = 3

    override init() {
        super.init()
        // Periodically verify every on-screen stream is actually making
        // progress, and escalate recovery if not. This is the core of the
        // "bulletproof over long runtime" behaviour.
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        // .common so the watchdog keeps firing during menu tracking / live resize.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Returns true if the on-screen stream is healthy (playing and advancing).
    private func isHealthy(_ e: Entry) -> Bool {
        switch e.player.state {
        case .playing, .esAdded:
            let t = Int(e.player.time.intValue)
            if t <= 0 { e.lastTimeMs = t; return true } // just starting
            if t != e.lastTimeMs { e.lastTimeMs = t; return true }
            return false // time frozen → stalled
        default:
            return false // opening/buffering/error/stopped/ended while on-screen
        }
    }

    private func checkHealth() {
        for e in entries.values where e.hostedIn != nil {
            if isHealthy(e) {
                e.unhealthyTicks = 0
                e.softRestarts = 0
            } else {
                e.unhealthyTicks += 1
                if e.unhealthyTicks >= unhealthyThreshold {
                    recover(e)
                }
            }
        }
    }

    /// Escalating recovery: clean stop→restart a few times, then recreate the
    /// underlying player if it stays wedged.
    private func recover(_ e: Entry) {
        e.unhealthyTicks = 0
        e.lastTimeMs = -1
        e.retryWork?.cancel(); e.retryWork = nil
        if e.softRestarts < maxSoftRestarts {
            e.softRestarts += 1
            appLog("Player[\(e.id)]: unhealthy — restart \(e.softRestarts)/\(maxSoftRestarts)", .warn)
            restart(e)
        } else {
            e.softRestarts = 0
            appLog("Player[\(e.id)]: still wedged — recreating player", .error)
            recreatePlayer(e)
        }
    }

    // MARK: Public API (all called on the main thread)

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
            e.retryCount = 0
            start(e)
        } else {
            switch e.player.state {
            case .playing, .buffering, .opening, .esAdded:
                break // already running — keep it
            default:
                e.retryCount = 0
                start(e)
            }
        }
    }

    func detach(cameraID id: String, from host: NSView) {
        guard let e = entries[id], e.hostedIn === host else { return }
        e.surface.removeFromSuperview()
        e.hostedIn = nil
        e.retryWork?.cancel(); e.retryWork = nil
        e.stopWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak e] in
            guard let self = self, let e = e, e.hostedIn == nil else { return }
            self.stop(e)
        }
        e.stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds, execute: work)
    }

    /// Stop and tear down every player (e.g. on disconnect).
    func stopAll() {
        for (_, e) in entries {
            e.retryWork?.cancel(); e.retryWork = nil
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

    private func makeMedia(url: URL, caching: Int, muted: Bool) -> VLCMedia {
        let media = VLCMedia(url: url)
        // Trade a little latency for resilience over long runtimes.
        media.addOption(":network-caching=\(caching)")
        media.addOption(":live-caching=\(caching)")
        media.addOption(":rtsp-tcp")                       // TCP is far more reliable than UDP
        media.addOption(":rtsp-frame-buffer-size=1000000")
        media.addOption(":no-audio") // grid/wall: video only (lower load, fewer stalls)
        _ = muted
        return media
    }

    private func start(_ e: Entry) {
        guard let url = e.activeURL else { return }
        setStatus(e, .buffering)
        e.lastTimeMs = -1
        e.unhealthyTicks = 0
        let caching = e.caching
        let muted = e.muted
        appLog("Player[\(e.id)]: start \(url.absoluteString)", .debug)
        // Serialize per camera on the control queue (so we never race a pending
        // stop), but drive the actual playback on the MAIN thread — VLCKit's
        // video output/presentation on macOS must be started from the main run
        // loop, otherwise it decodes a single frame and freezes (a "still").
        e.controlQueue.async { [weak self] in
            let media = self?.makeMedia(url: url, caching: caching, muted: muted) ?? VLCMedia(url: url)
            DispatchQueue.main.sync {
                e.player.media = media
                e.player.play()
            }
        }
    }

    /// Clean stop → restart, serialized so the two never overlap.
    private func restart(_ e: Entry) {
        guard let url = e.activeURL else { return }
        setStatus(e, .buffering)
        e.lastTimeMs = -1
        let caching = e.caching
        let muted = e.muted
        e.controlQueue.async { [weak self] in
            e.player.stop()
            let media = self?.makeMedia(url: url, caching: caching, muted: muted) ?? VLCMedia(url: url)
            DispatchQueue.main.sync {
                e.player.media = media
                e.player.play()
            }
        }
    }

    /// Nuclear option: replace a wedged player with a fresh one (reusing the
    /// same on-screen surface) so a single bad player can't stay broken.
    private func recreatePlayer(_ e: Entry) {
        guard let url = e.activeURL else { return }
        setStatus(e, .buffering)
        e.lastTimeMs = -1
        let old = e.player
        let fresh = VLCMediaPlayer()
        fresh.drawable = e.surface
        fresh.delegate = self
        e.player = fresh
        let caching = e.caching
        let muted = e.muted
        e.controlQueue.async { [weak self] in
            old.delegate = nil
            old.stop()
            let media = self?.makeMedia(url: url, caching: caching, muted: muted) ?? VLCMedia(url: url)
            DispatchQueue.main.sync {
                fresh.media = media
                fresh.play()
            }
        }
    }

    private func stop(_ e: Entry) {
        setStatus(e, .idle)
        // Runs on the (background) control queue, serialized after any start —
        // keeps the main thread responsive while the RTSP session closes.
        e.controlQueue.async {
            e.player.stop()
        }
    }

    private func applyFallback(_ e: Entry) -> Bool {
        guard e.hostedIn != nil, !e.triedFallback,
              let active = e.activeURL, active.scheme?.lowercased() == "rtsps",
              var comps = URLComponents(url: active, resolvingAgainstBaseURL: false),
              let _ = active.host else { return false }
        comps.scheme = "rtsp"
        comps.port = 7447
        comps.query = nil
        guard let fb = comps.url else { return false }
        e.triedFallback = true
        e.activeURL = fb
        e.retryCount = 0
        appLog("Player[\(e.id)]: RTSPS failed — falling back to \(fb.absoluteString)", .warn)
        start(e)
        return true
    }

    private func scheduleRetry(_ e: Entry) {
        guard e.hostedIn != nil else { return } // don't retry off-screen players
        e.retryWork?.cancel()
        e.retryCount += 1
        let delay = min(pow(2.0, Double(e.retryCount - 1)), 10.0)
        let work = DispatchWorkItem { [weak self, weak e] in
            guard let self = self, let e = e, e.hostedIn != nil else { return }
            appLog("Player[\(e.id)]: retry #\(e.retryCount)", .warn)
            self.start(e)
        }
        e.retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setStatus(_ e: Entry, _ s: PlaybackStatus) {
        // Always defer to the next main-thread cycle. setStatus is often called
        // from within a SwiftUI view update (via attach during makeNSView), and
        // mutating an @Published value during an update is undefined behavior.
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
            e.retryCount = 0
            setStatus(e, .playing)
        case .buffering, .opening:
            setStatus(e, .buffering)
        case .error:
            appLog("Player[\(e.id)]: ERROR \(e.activeURL?.absoluteString ?? "")", .error)
            if applyFallback(e) { return }
            setStatus(e, .error)
            scheduleRetry(e)
        case .ended, .stopped:
            // A live stream shouldn't end; if we still want it, recover.
            if e.hostedIn != nil {
                if applyFallback(e) { return }
                setStatus(e, .buffering)
                scheduleRetry(e)
            }
        default:
            break
        }
    }
}

// MARK: - SwiftUI video view

/// A lightweight SwiftUI view that hosts a camera's (pooled) video surface.
/// It never owns a player — it just asks the manager to host the camera's
/// surface inside it while on screen.
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
    private var caching = 300
    private var muted = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func configure(cameraID: String, url: URL, caching: Int, muted: Bool) {
        let cameraChanged = self.cameraID != cameraID
        if cameraChanged, !self.cameraID.isEmpty {
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

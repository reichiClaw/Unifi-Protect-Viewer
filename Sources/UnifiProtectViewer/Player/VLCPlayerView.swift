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
        let player = VLCMediaPlayer()
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
        var caching = 300
        var muted = true
        init(id: String) {
            self.id = id
            controlQueue = DispatchQueue(label: "com.unifiprotectviewer.vlc.\(id)")
        }
    }

    private var entries: [String: Entry] = [:]
    /// Keep a stopped stream's player around (warm) for this long after it goes
    /// off-screen, so flipping back to it resumes instantly.
    private let graceSeconds: TimeInterval = 8

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

    private func start(_ e: Entry) {
        guard let url = e.activeURL else { return }
        setStatus(e, .buffering)
        let caching = e.caching
        let muted = e.muted
        appLog("Player[\(e.id)]: start \(url.absoluteString)", .debug)
        e.controlQueue.async {
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=\(caching)")
            media.addOption(":rtsp-tcp")
            media.addOption(":rtsp-frame-buffer-size=500000")
            media.addOption(":clock-jitter=0")
            media.addOption(":clock-synchro=0")
            if muted { media.addOption(":no-audio") }
            e.player.media = media
            e.player.play()
        }
    }

    private func stop(_ e: Entry) {
        setStatus(e, .idle)
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
        let apply = { if e.status.state != s { e.status.state = s } }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
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
    var caching: Int = 300
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

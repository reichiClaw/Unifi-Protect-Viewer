import SwiftUI
import AppKit
import VLCKitSPM

/// Playback state surfaced to the tile UI.
enum PlaybackStatus: Equatable {
    case idle, buffering, playing, error, offline
}

/// Observable per-camera status so SwiftUI tiles can show overlays.
final class CameraPlaybackStatus: ObservableObject {
    @Published var state: PlaybackStatus = .idle
}

/// Bridges libvlc's own log output into the app log so we can see the **actual**
/// decoder each stream ends up using (hardware VideoToolbox vs. software
/// avcodec). VLCKit doesn't expose the chosen decoder any other way, and the
/// per-stream config only tells us what was *requested* — this shows what libvlc
/// actually did, including any automatic hardware→software fallback.
///
/// To keep overhead low we accept libvlc's full (debug-level) firehose but
/// immediately discard everything except decoder/VideoToolbox/avcodec lines,
/// and de-duplicate so a stream logs its decoder choice once, not per frame.
final class VLCDecodeLogger: NSObject, VLCLogging {
    // Handle everything; decoder-selection lines are debug level in libvlc.
    var level: VLCLogLevel = .debug

    private let lock = NSLock()
    private var seen = Set<String>()

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let objectType = context?.objectType ?? ""
        let module = context?.module ?? ""
        // Cheap gate first: only decoder objects / the video codec modules.
        guard objectType == "decoder" || module == "videotoolbox" || module == "avcodec" else { return }

        let lower = message.lowercased()
        // The interesting lines: which decoder module was chosen, and any
        // hardware-decode / fallback notices.
        let picksDecoder = lower.contains("decoder module")
        let mentionsHW = lower.contains("videotoolbox") || lower.contains("video toolbox")
            || lower.contains("hardware") || lower.contains("hwaccel")
            || lower.contains("hw decoding") || lower.contains("fall back") || lower.contains("fallback")
        guard picksDecoder || mentionsHW else { return }

        let objID = context.map { "0x" + String($0.objectId, radix: 16) } ?? "?"
        // De-dup per (object, message) so we don't spam repeats.
        let key = objID + "|" + message
        lock.lock()
        let isNew = seen.insert(key).inserted
        if seen.count > 2000 { seen.removeAll(keepingCapacity: true) }
        lock.unlock()
        guard isNew else { return }

        let mod = module.isEmpty ? "vlc" : module
        appLog("VLC decoder [\(mod)#\(objID)]: \(message)", .info)

        // Emit a plain-English summary for the decoder-selection line so the log
        // is skimmable ("videotoolbox" = hardware, "avcodec" = software).
        if picksDecoder {
            if lower.contains("videotoolbox") {
                appLog("VLC decoder [#\(objID)]: using HARDWARE decoding (VideoToolbox)", .info)
            } else if lower.contains("avcodec") {
                appLog("VLC decoder [#\(objID)]: using SOFTWARE decoding (avcodec)", .info)
            }
        }
    }
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
        var online = true
        var hardwareDecoding = true
        // Watchdog bookkeeping.
        var startedAt = Date()
        var lastHealthyAt = Date.distantPast
        var recoveryAttempts = 0
        var nextRecoveryAllowedAt = Date.distantPast
        var announcedPlaying = false
        /// Whether we've already asked the app to confirm this failure episode.
        var reportedFailure = false
        /// When the player was stopped while off-screen (for memory eviction).
        var idleSince: Date?
        init(id: String) {
            self.id = id
            controlQueue = DispatchQueue(label: "com.unifiprotectviewer.vlc.\(id)")
        }
    }

    private var entries: [String: Entry] = [:]
    /// Called (on the main thread) when a hosted, online camera's stream has
    /// been failing to play for a while — so the app can check the controller
    /// to distinguish "camera offline" from a transient stream problem.
    var onPersistentFailure: ((String) -> Void)?
    /// Keep a stopped stream warm this long after it leaves the screen so quick
    /// back-and-forth resumes instantly.
    private let graceSeconds: TimeInterval = 10
    private var watchdog: Timer?
    private let watchdogInterval: TimeInterval = 4
    /// How long a stream may stay failed (error/stopped/ended) before recovery.
    private let failGrace: TimeInterval = 6
    /// Never recover more than this many streams in a single tick — prevents a
    /// network blip from triggering a thundering herd of simultaneous restarts.
    private let maxRecoveriesPerTick = 3
    /// Stagger (re)starts so we never hit the controller with a connection storm.
    private var nextStartAt = Date()
    private let startStagger: TimeInterval = 0.25
    /// Fully release (deallocate) a player that has been off-screen this long,
    /// to free its decoder/network buffers — important on low-RAM machines.
    private let evictionSeconds: TimeInterval = 60
    /// Captures libvlc's log so we can report the actual decoder per stream.
    /// Held strongly here (the singleton lives for the app's lifetime).
    private let vlcLogger = VLCDecodeLogger()
    private var vlcLoggerInstalled = false
    /// Watches system memory pressure so we can shed off-screen decoders before
    /// macOS resorts to killing us (jetsam) — the biggest crash risk on 8 GB.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    /// Called (main thread) on a memory-pressure warning/critical event so the
    /// app can log it / react. `true` = critical.
    var onMemoryPressure: ((Bool) -> Void)?

    override init() {
        super.init()
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        installMemoryPressureMonitor()
    }

    // MARK: Memory pressure

    private func installMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let critical = source.data.contains(.critical)
            self.handleMemoryPressure(critical: critical)
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Free every off-screen player immediately (don't wait for the idle timer),
    /// so the OS reclaims that RAM instead of killing the process.
    private func handleMemoryPressure(critical: Bool) {
        let offscreen = entries.values.filter { $0.hostedIn == nil }.map { $0.id }
        for id in offscreen { evict(id) }
        let mem = SystemStats.memoryFootprintMB()
        appLog(String(format: "Memory pressure %@ — evicted %d off-screen stream(s) to free RAM (footprint %.0fMB)",
                      critical ? "CRITICAL" : "warning", offscreen.count, mem),
               critical ? .error : .warn)
        onMemoryPressure?(critical)
    }

    // MARK: Public API (main thread)

    func status(for id: String) -> CameraPlaybackStatus {
        entry(for: id).status
    }

    func attach(cameraID id: String, to host: NSView, url: URL, caching: Int, muted: Bool, online: Bool, hardwareDecoding: Bool) {
        let e = entry(for: id)
        e.stopWork?.cancel(); e.stopWork = nil
        e.idleSince = nil
        e.caching = caching
        e.muted = muted
        e.hardwareDecoding = hardwareDecoding

        if e.surface.superview !== host {
            e.surface.removeFromSuperview()
            e.surface.frame = host.bounds
            e.surface.autoresizingMask = [.width, .height]
            host.addSubview(e.surface)
        }
        e.hostedIn = host

        // Camera is offline: don't start/retry — just show the offline state and
        // free any running player. We resume automatically when it comes back.
        if !online {
            let wasOnline = e.online
            e.online = false
            e.requestedURL = url
            e.activeURL = url
            setStatus(e, .offline)
            if wasOnline { e.controlQueue.async { e.player.stop() } }
            return
        }

        let cameBackOnline = !e.online
        e.online = true

        if e.requestedURL != url || cameBackOnline {
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

    /// Counts of currently on-screen players by state (for diagnostics).
    func playbackSummary() -> String {
        var playing = 0, buffering = 0, opening = 0, error = 0, other = 0
        for e in entries.values where e.hostedIn != nil {
            switch e.player.state {
            case .playing, .esAdded: playing += 1
            case .buffering: buffering += 1
            case .opening: opening += 1
            case .error: error += 1
            default: other += 1
            }
        }
        return "streams on-screen: playing=\(playing) buffering=\(buffering) opening=\(opening) error=\(error) other=\(other)"
    }

    // MARK: Internals

    private func entry(for id: String) -> Entry {
        if let e = entries[id] { return e }
        let e = Entry(id: id)
        e.surface.wantsLayer = true
        e.surface.layer?.backgroundColor = NSColor.black.cgColor
        e.player.drawable = e.surface
        e.player.delegate = self
        // Route libvlc's log through our bridge once, so the app log records the
        // actual decoder each stream selects (hardware vs. software).
        if !vlcLoggerInstalled {
            e.player.libraryInstance.loggers = [vlcLogger]
            vlcLoggerInstalled = true
            appLog("VLC decoder logging enabled — actual decode module per stream will be logged", .debug)
        }
        entries[id] = e
        return e
    }

    private func resetHealth(_ e: Entry) {
        let now = Date()
        e.startedAt = now
        e.recoveryAttempts = 0
        e.nextRecoveryAllowedAt = now
        e.reportedFailure = false
    }

    private func makeMedia(url: URL, caching: Int, hardwareDecoding: Bool) -> VLCMedia {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(caching)")
        media.addOption(":live-caching=\(caching)")
        media.addOption(":rtsp-tcp")
        media.addOption(":rtsp-frame-buffer-size=1000000")
        media.addOption(":no-audio")
        // Hardware decoding: offload H.264/H.265 decode to Apple's VideoToolbox
        // (dedicated silicon) instead of the CPU. Cuts CPU load and the memory
        // used by software decode buffers — the main win on low-RAM Macs.
        //
        // When enabled we let libvlc try the VideoToolbox decoder module first
        // and **fall back to software automatically** if a particular stream
        // can't be hardware-decoded (unsupported codec/profile, or the decoder
        // errors out) — a seamless per-stream switch, no user action needed.
        // When disabled we turn the VideoToolbox module off and force plain
        // software (avcodec) decoding.
        if hardwareDecoding {
            media.addOption(":videotoolbox=1")
            media.addOption(":avcodec-hw=any")
        } else {
            media.addOption(":videotoolbox=0")
            media.addOption(":avcodec-hw=none")
        }
        return media
    }

    private func start(_ e: Entry) {
        let decode = e.hardwareDecoding ? "hardware (VideoToolbox, auto-fallback to software)" : "software"
        appLog("Player[\(e.id)]: start \(e.activeURL?.absoluteString ?? "") [decode requested: \(decode)]", .debug)
        launch(e, stopFirst: false)
    }

    /// Start (or restart) playback. VLC calls run on the **main thread**
    /// (required for video output on macOS), staggered globally so simultaneous
    /// starts don't storm the controller. When `stopFirst` is set the existing
    /// player is stopped on its background queue first (clean recovery).
    private func launch(_ e: Entry, stopFirst: Bool) {
        guard let url = e.activeURL else { return }
        setStatus(e, .buffering)
        let now = Date()
        e.startedAt = now
        e.announcedPlaying = false
        let caching = e.caching
        let hardwareDecoding = e.hardwareDecoding
        // Global stagger.
        let at = max(now, nextStartAt)
        nextStartAt = at.addingTimeInterval(startStagger)
        let delay = max(0, at.timeIntervalSince(now))

        let play: () -> Void = { [weak self, weak e] in
            guard let self = self, let e = e, e.hostedIn != nil else { return }
            e.player.media = self.makeMedia(url: url, caching: caching, hardwareDecoding: hardwareDecoding)
            e.player.play()
        }

        if stopFirst {
            e.controlQueue.async { [weak e] in
                e?.player.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: play)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: play)
        }
    }

    private func stop(_ e: Entry) {
        setStatus(e, .idle)
        e.idleSince = Date()
        e.controlQueue.async {
            e.player.stop()
            // Release the media so its demux/decoder/network buffers are freed
            // while the camera is off-screen (frees RAM on the wall).
            e.player.media = nil
        }
    }

    /// Fully release an off-screen player to reclaim its memory.
    private func evict(_ id: String) {
        guard let e = entries[id] else { return }
        e.stopWork?.cancel(); e.stopWork = nil
        e.player.delegate = nil
        e.player.drawable = nil
        entries.removeValue(forKey: id)
        let p = e.player
        e.controlQueue.async {
            p.stop()
            p.media = nil
        }
        appLog("Player[\(id)]: evicted (idle \(Int(evictionSeconds))s) to free memory", .debug)
    }

    // MARK: Watchdog

    /// Recover only genuinely-failed or hung streams. Streams that are still
    /// opening/buffering are given a long startup grace so we never kill a
    /// stream that's simply taking a while to connect.
    private func checkHealth() {
        let now = Date()
        var budget = maxRecoveriesPerTick
        for e in entries.values where e.hostedIn != nil && e.online {
            switch e.player.state {
            case .playing, .esAdded:
                e.lastHealthyAt = now
                e.recoveryAttempts = 0
                e.nextRecoveryAllowedAt = now
            case .error, .stopped, .ended:
                // Hard failure — recover (with backoff). We deliberately do NOT
                // recover `opening`/`buffering`: those mean the stream is still
                // working on it, and restarting mid-connect just adds load and
                // prevents it from ever stabilizing (a death spiral under load).
                let reference = max(e.lastHealthyAt, e.startedAt)
                guard now.timeIntervalSince(reference) >= failGrace,
                      now >= e.nextRecoveryAllowedAt,
                      budget > 0 else { continue }
                budget -= 1
                recover(e, now: now)
            default:
                break // opening / buffering / paused — leave it alone
            }
        }

        // Evict players that have been off-screen long enough, to free memory.
        let stale = entries.values.filter { $0.hostedIn == nil }
            .filter { ($0.idleSince.map { now.timeIntervalSince($0) > evictionSeconds }) ?? false }
            .map { $0.id }
        for id in stale { evict(id) }
    }

    private func recover(_ e: Entry, now: Date) {
        if applyFallback(e) { return } // rtsps→rtsp, counts as the recovery
        e.recoveryAttempts += 1
        // Backoff so a permanently-offline camera settles to infrequent retries
        // instead of thrashing the whole app.
        let backoff = min(15.0 * Double(e.recoveryAttempts), 300.0)
        e.nextRecoveryAllowedAt = now.addingTimeInterval(backoff)
        appLog("Player[\(e.id)]: recovering (attempt \(e.recoveryAttempts), next try in \(Int(backoff))s)", .warn)
        // After a couple of failed attempts, ask the app to confirm whether the
        // camera is actually offline (vs a transient stream problem).
        if e.recoveryAttempts >= 2, !e.reportedFailure {
            e.reportedFailure = true
            onPersistentFailure?(e.id)
        }
        launch(e, stopFirst: true)
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
        launch(e, stopFirst: true)
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
            e.reportedFailure = false
            if !e.announcedPlaying {
                e.announcedPlaying = true
                let decode = e.hardwareDecoding ? "hardware (VideoToolbox, auto-fallback to software)" : "software"
                appLog("Player[\(e.id)]: PLAYING [decode requested: \(decode)] — see 'VLC decoder' lines for the actual module", .debug)
            }
            setStatus(e, .playing)
        case .buffering, .opening:
            setStatus(e, .buffering)
        case .error:
            appLog("Player[\(e.id)]: ERROR \(e.activeURL?.absoluteString ?? "")", .error)
            e.announcedPlaying = false
            setStatus(e, .error)
            // checkHealth() will recover after failGrace (respecting backoff).
        case .ended, .stopped:
            if e.hostedIn != nil { setStatus(e, .buffering) }
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
    var online: Bool = true
    var hardwareDecoding: Bool = true

    func makeNSView(context: Context) -> HostView {
        let host = HostView()
        host.configure(cameraID: cameraID, url: url, caching: caching, muted: muted, online: online, hardwareDecoding: hardwareDecoding)
        return host
    }

    func updateNSView(_ host: HostView, context: Context) {
        host.configure(cameraID: cameraID, url: url, caching: caching, muted: muted, online: online, hardwareDecoding: hardwareDecoding)
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
    private var online = true
    private var hardwareDecoding = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    // Let mouse clicks fall through to SwiftUI's gesture layer (so tapping a
    // tile or the fullscreen video is reliably received).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(cameraID: String, url: URL, caching: Int, muted: Bool, online: Bool, hardwareDecoding: Bool) {
        if self.cameraID != cameraID, !self.cameraID.isEmpty {
            CameraPlayerManager.shared.detach(cameraID: self.cameraID, from: self)
        }
        self.cameraID = cameraID
        self.url = url
        self.caching = caching
        self.muted = muted
        self.online = online
        self.hardwareDecoding = hardwareDecoding
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
        CameraPlayerManager.shared.attach(cameraID: cameraID, to: self, url: url, caching: caching, muted: muted, online: online, hardwareDecoding: hardwareDecoding)
    }
}

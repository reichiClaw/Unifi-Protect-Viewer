import SwiftUI
import AppKit
import VLCKitSPM

/// SwiftUI wrapper around a VLCKit `VLCMediaPlayer` for RTSP/RTSPS playback.
///
/// Each instance owns one player drawing into a layer-backed `NSView`. Stream
/// state is surfaced through `PlaybackStatus` so the tile UI can show buffering
/// / error overlays, and the coordinator auto-retries on stream errors.
struct VLCPlayerView: NSViewRepresentable {
    let url: URL
    /// Lower latency at the cost of a bit more CPU. ~150–500ms network cache.
    var networkCachingMs: Int = 300
    var muted: Bool = true
    @Binding var status: PlaybackStatus

    enum PlaybackStatus: Equatable {
        case idle, buffering, playing, error
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status)
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let container = PlayerContainerView()
        let coordinator = context.coordinator
        // VLC draws into a dedicated, autoresizing subview to avoid layer /
        // background conflicts that can cause a black image.
        coordinator.attach(to: container.videoView)
        // Start playback only once the view is in a window and has a real
        // surface — starting in makeNSView (zero frame, no window) yields a
        // black image with VLCKit on macOS.
        let cachingMs = networkCachingMs
        let isMuted = muted
        let streamURL = url
        container.onMoveToWindow = { [weak coordinator] in
            coordinator?.play(url: streamURL, networkCaching: cachingMs, muted: isMuted)
        }
        return container
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        // Restart only if the URL changed (and only when on-screen).
        if nsView.window != nil {
            context.coordinator.play(url: url, networkCaching: networkCachingMs, muted: muted)
        }
    }

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private let player = VLCMediaPlayer()
        /// What SwiftUI asked us to play (used to dedupe restarts).
        private var requestedURL: URL?
        /// What we are actually playing (may differ after an RTSPS→RTSP fallback).
        private var activeURL: URL?
        private var triedRTSPFallback = false
        private var retryWorkItem: DispatchWorkItem?
        private var retryCount = 0
        private let statusBinding: Binding<PlaybackStatus>

        private weak var drawableView: NSView?
        private var lastCachingMs = 300
        private var lastMuted = true

        init(status: Binding<PlaybackStatus>) {
            self.statusBinding = status
            super.init()
            player.delegate = self
        }

        func attach(to view: NSView) {
            drawableView = view
            player.drawable = view
        }

        func play(url: URL, networkCaching: Int, muted: Bool) {
            // Only (re)start when the requested URL actually changes; otherwise
            // SwiftUI updates would interrupt a live stream while it buffers.
            if requestedURL == url { return }
            requestedURL = url
            activeURL = url
            triedRTSPFallback = false
            lastCachingMs = networkCaching
            lastMuted = muted
            retryCount = 0
            appLog("Player: start \(url.absoluteString)")
            startPlayback(networkCaching: networkCaching, muted: muted)
        }

        private func startPlayback(networkCaching: Int, muted: Bool) {
            guard let url = activeURL else { return }
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=\(networkCaching)")
            media.addOption(":rtsp-tcp")          // force TCP for reliability over wifi
            media.addOption(":rtsp-frame-buffer-size=500000")
            media.addOption(":clock-jitter=0")
            media.addOption(":clock-synchro=0")
            if muted {
                media.addOption(":no-audio")
            }
            player.media = media
            updateStatus(.buffering)
            player.play()
        }

        /// Serial queue used to tear players down off the main thread.
        /// `VLCMediaPlayer.stop()` is synchronous and can block for a while
        /// while the RTSP session closes; doing that for every tile on the main
        /// thread (e.g. when the grid is replaced by fullscreen) freezes the UI.
        private static let teardownQueue = DispatchQueue(label: "com.unifiprotectviewer.vlc.teardown")

        func stop() {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            player.delegate = nil          // no more state callbacks
            player.drawable = nil          // detach the view (fast, main thread)
            let p = player                 // keep the player alive until stop completes
            Coordinator.teardownQueue.async {
                p.stop()
            }
        }

        /// UniFi RTSPS (port 7441, TLS + SRTP) is not reliably supported by
        /// libvlc due to the controller's self-signed certificate. The same
        /// stream is available unencrypted via RTSP on port 7447, so on failure
        /// we transparently switch to it.
        private func rtspFallback(for url: URL) -> URL? {
            guard url.scheme?.lowercased() == "rtsps" else { return nil }
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            comps.scheme = "rtsp"
            comps.port = 7447
            comps.query = nil // drop ?enableSrtp
            return comps.url
        }

        /// Returns true if a fallback was applied and playback (re)started.
        private func applyRTSPFallbackIfPossible() -> Bool {
            guard !triedRTSPFallback, let active = activeURL, let fb = rtspFallback(for: active) else {
                return false
            }
            triedRTSPFallback = true
            activeURL = fb
            retryCount = 0
            appLog("Player: RTSPS failed — falling back to \(fb.absoluteString)", .warn)
            startPlayback(networkCaching: lastCachingMs, muted: lastMuted)
            return true
        }

        private func scheduleRetry() {
            retryWorkItem?.cancel()
            retryCount += 1
            // Back off: 1s, 2s, 4s … capped at 10s.
            let delay = min(pow(2.0, Double(retryCount - 1)), 10.0)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                appLog("Player: retry #\(self.retryCount) \(self.activeURL?.absoluteString ?? "")", .warn)
                self.startPlayback(networkCaching: self.lastCachingMs, muted: self.lastMuted)
            }
            retryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func updateStatus(_ status: PlaybackStatus) {
            DispatchQueue.main.async {
                if self.statusBinding.wrappedValue != status {
                    self.statusBinding.wrappedValue = status
                }
            }
        }

        // MARK: VLCMediaPlayerDelegate

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            let url = activeURL?.absoluteString ?? ""
            switch player.state {
            case .playing:
                retryCount = 0
                let size = drawableView?.bounds.size ?? .zero
                appLog("Player: PLAYING \(url) (view \(Int(size.width))x\(Int(size.height)))")
                updateStatus(.playing)
            case .buffering, .opening:
                appLog("Player: \(stateName) \(url)", .debug)
                updateStatus(.buffering)
            case .error:
                appLog("Player: ERROR \(url)", .error)
                updateStatus(.buffering)
                if applyRTSPFallbackIfPossible() { return }
                updateStatus(.error)
                scheduleRetry()
            case .ended, .stopped:
                // Live streams should not "end"; treat as a drop and retry.
                if requestedURL != nil {
                    if applyRTSPFallbackIfPossible() { return }
                    appLog("Player: \(stateName) \(url) — will retry", .warn)
                    updateStatus(.buffering)
                    scheduleRetry()
                }
            default:
                break
            }
        }

        private var stateName: String {
            switch player.state {
            case .stopped: return "STOPPED"
            case .opening: return "OPENING"
            case .buffering: return "BUFFERING"
            case .ended: return "ENDED"
            case .error: return "ERROR"
            case .playing: return "PLAYING"
            case .paused: return "PAUSED"
            default: return "STATE(\(player.state.rawValue))"
            }
        }
    }
}

/// NSView that hosts VLCKit's video output in a dedicated subview and notifies
/// when it becomes part of a window, so playback can start against a valid
/// drawing surface.
final class PlayerContainerView: NSView {
    /// The view VLC renders into. Tracks the container's bounds.
    let videoView = NSView()
    var onMoveToWindow: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true
        videoView.wantsLayer = true
        videoView.translatesAutoresizingMaskIntoConstraints = true
        videoView.autoresizingMask = [.width, .height]
        videoView.frame = bounds
        addSubview(videoView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }
}

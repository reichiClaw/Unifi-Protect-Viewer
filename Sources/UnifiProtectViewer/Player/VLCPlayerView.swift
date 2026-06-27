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
        private var currentURL: URL?
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
            // Only (re)start when the URL actually changes; otherwise SwiftUI
            // updates would interrupt a live stream while it buffers.
            if currentURL == url { return }
            currentURL = url
            lastCachingMs = networkCaching
            lastMuted = muted
            retryCount = 0
            appLog("Player: start \(url.absoluteString)")
            startPlayback(networkCaching: networkCaching, muted: muted)
        }

        private func startPlayback(networkCaching: Int, muted: Bool) {
            guard let url = currentURL else { return }
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

        func stop() {
            retryWorkItem?.cancel()
            retryWorkItem = nil
            if player.isPlaying { player.stop() }
            player.drawable = nil
        }

        private func scheduleRetry() {
            retryWorkItem?.cancel()
            retryCount += 1
            // Back off: 1s, 2s, 4s … capped at 10s.
            let delay = min(pow(2.0, Double(retryCount - 1)), 10.0)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                appLog("Player: retry #\(self.retryCount) \(self.currentURL?.absoluteString ?? "")", .warn)
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
            let url = currentURL?.absoluteString ?? ""
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
                updateStatus(.error)
                scheduleRetry()
            case .ended, .stopped:
                // Live streams should not "end"; treat as a drop and retry.
                if currentURL != nil {
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

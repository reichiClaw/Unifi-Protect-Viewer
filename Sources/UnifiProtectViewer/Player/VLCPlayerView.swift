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

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(to: container)
        context.coordinator.play(url: url, networkCaching: networkCachingMs, muted: muted)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.play(url: url, networkCaching: networkCachingMs, muted: muted)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private let player = VLCMediaPlayer()
        private var currentURL: URL?
        private var retryWorkItem: DispatchWorkItem?
        private var retryCount = 0
        private let statusBinding: Binding<PlaybackStatus>

        init(status: Binding<PlaybackStatus>) {
            self.statusBinding = status
            super.init()
            player.delegate = self
        }

        func attach(to view: NSView) {
            player.drawable = view
        }

        func play(url: URL, networkCaching: Int, muted: Bool) {
            // Only (re)start when the URL actually changes; otherwise SwiftUI
            // updates would interrupt a live stream while it buffers.
            if currentURL == url { return }
            currentURL = url
            retryCount = 0
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
                self.startPlayback(networkCaching: 300, muted: true)
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
            switch player.state {
            case .playing:
                retryCount = 0
                updateStatus(.playing)
            case .buffering, .opening:
                updateStatus(.buffering)
            case .error:
                updateStatus(.error)
                scheduleRetry()
            case .ended, .stopped:
                // Live streams should not "end"; treat as a drop and retry.
                if currentURL != nil {
                    updateStatus(.buffering)
                    scheduleRetry()
                }
            default:
                break
            }
        }
    }
}

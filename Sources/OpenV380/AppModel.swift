import Foundation
import V380

/// Shared state for the camera window: which mode is showing and whether sound is on.
final class AppModel: ObservableObject {
    enum Mode: String { case live, recordings }

    @Published private(set) var mode: Mode = .live
    @Published private(set) var muted = true
    /// True once we've determined this camera's audio can't be decoded (encrypted) for the current mode.
    @Published private(set) var audioUnavailable = false

    let live = LiveController()
    let playback = PlaybackController()
    var config: CameraConfig? {
        didSet { playback.config = config }
    }

    init(config: CameraConfig?) {
        self.config = config
        playback.config = config
        live.audio.onNoiseDetected = { [weak self] in
            guard self?.mode == .live else { return }
            self?.audioUnavailable = true
        }
        playback.audio.onNoiseDetected = { [weak self] in
            guard self?.mode == .recordings else { return }
            self?.audioUnavailable = true
        }
    }

    /// Only one stream at a time, so the camera's Wi-Fi is not split between live and playback.
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        audioUnavailable = false
        switch newMode {
        case .live:
            playback.stop()
            if let config { live.start(config) }
        case .recordings:
            live.stop()
            if playback.segments.isEmpty { playback.reloadList() }
        }
    }

    func setMuted(_ value: Bool) {
        muted = value
        live.setMuted(value)
        playback.audio.muted = value
    }

    func windowOpened() {
        guard let config else { return }
        if mode == .live, !live.isRunning { live.start(config) }
        if mode == .recordings, playback.segments.isEmpty, playback.listState == .idle { playback.reloadList() }
    }

    /// Closing the window drops every connection and returns to muted.
    func windowClosed() {
        live.stop()
        playback.stop()
        setMuted(true)
    }

    func reconnect() {
        guard let config else { return }
        switch mode {
        case .live: live.start(config)
        case .recordings: playback.reloadList()
        }
    }
}

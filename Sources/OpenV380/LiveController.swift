import Foundation
import V380

/// Owns the camera connection: connects, reconnects on drops, and feeds video to the renderer.
final class LiveController: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting(String)
        case live
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var detail = ""
    @Published private(set) var fps = 0
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var muted = true
    @Published private(set) var talk: TalkState = .off

    enum TalkState: Equatable {
        case off
        case connecting
        case on
        case failed(String)
    }

    let renderer = VideoRenderer()
    let audio = AudioPlayer()
    private var session: V380Session?
    private var generation = 0
    private let lock = NSLock()

    private let microphone = MicrophoneCapture()
    private let talkQueue = DispatchQueue(label: "openv380.talk")
    private var talkChannel: V380TalkChannel? // only touched on talkQueue
    private var talkGeneration = 0            // main queue
    private var talkBacklog = 0               // guarded by lock

    /// The config of the stream that was last started and not stopped since. Main queue only.
    private(set) var activeConfig: CameraConfig?

    func start(_ config: CameraConfig) {
        stop()
        activeConfig = config
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        setState(.connecting("Connecting…"), gen: gen)

        let thread = Thread { [weak self] in self?.run(config, gen: gen) }
        thread.name = "camview.live"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        stopTalk()
        activeConfig = nil
        lock.lock()
        generation += 1
        let s = session; session = nil
        lock.unlock()
        s?.cancel()
        renderer.clear()
        DispatchQueue.main.async { self.state = .idle; self.fps = 0 }
    }

    func setMuted(_ value: Bool) {
        audio.muted = value
        muted = value
    }

    /// Toggles the camera's white light (only works while streaming).
    func setTorch(_ on: Bool) {
        lock.lock(); let s = session; lock.unlock()
        s?.setLight(on ? .on : .off)
    }

    /// Moves the camera (pass nil to stop). Only works while streaming, and only if the camera has motors.
    func ptz(_ direction: V380Session.PTZ?) {
        lock.lock(); let s = session; lock.unlock()
        if let direction { s?.ptzMove(direction) } else { s?.ptzStop() }
    }

    var isTalking: Bool { talk == .on || talk == .connecting }

    /// Starts or stops sending the Mac's microphone to the camera's speaker. Main queue only.
    func setTalking(_ on: Bool) {
        on ? startTalk() : stopTalk()
    }

    private func startTalk() {
        guard state == .live, talk != .connecting, talk != .on else { return }
        lock.lock(); let s = session; lock.unlock()
        guard let s else { return }
        talkGeneration += 1
        let gen = talkGeneration
        talk = .connecting

        MicrophoneCapture.requestAccess { [weak self] granted in
            guard let self, gen == self.talkGeneration else { return }
            guard granted else {
                self.talk = .failed("Microphone access is off. Allow OpenV380 in System Settings → Privacy & Security → Microphone.")
                return
            }
            self.talkQueue.async {
                do {
                    let channel = try s.openTalk()
                    DispatchQueue.main.async { self.talkOpened(channel, gen: gen) }
                } catch {
                    Diag.log("talk open failed: \(error)")
                    DispatchQueue.main.async {
                        guard gen == self.talkGeneration else { return }
                        self.talk = .failed("The camera didn't accept talk (\(error)).")
                    }
                }
            }
        }
    }

    private func talkOpened(_ channel: V380TalkChannel, gen: Int) {
        guard gen == talkGeneration, state == .live else {
            talkQueue.async { channel.close() }
            return
        }
        talkQueue.async { self.talkChannel = channel }
        do {
            try microphone.start(blockSize: V380TalkChannel.samplesPerBlock) { [weak self] block in
                guard let self else { return }
                // On a slow link, drop audio rather than let the voice fall further and further behind.
                self.lock.lock()
                let backlog = self.talkBacklog
                if backlog < 16 { self.talkBacklog += 1 }
                self.lock.unlock()
                guard backlog < 16 else { return }
                self.talkQueue.async {
                    defer { self.lock.lock(); self.talkBacklog -= 1; self.lock.unlock() }
                    guard let channel = self.talkChannel else { return }
                    do {
                        try channel.send(block)
                    } catch {
                        Diag.log("talk send failed: \(error)")
                        self.talkChannel = nil
                        channel.close()
                        DispatchQueue.main.async { self.talkEnded(gen: gen, message: "Talk connection dropped.") }
                    }
                }
            }
        } catch {
            Diag.log("microphone failed: \(error)")
            talkEnded(gen: gen, message: "Couldn't start the microphone.")
            return
        }
        // The camera's microphone would pick up its own speaker; the V380 app pauses playback the same way.
        audio.suppressed = true
        talk = .on
    }

    private func talkEnded(gen: Int, message: String) {
        guard gen == talkGeneration else { return }
        stopTalk()
        talk = .failed(message)
    }

    private func stopTalk() {
        talkGeneration += 1
        microphone.stop()
        talkQueue.async {
            self.talkChannel?.close()
            self.talkChannel = nil
        }
        audio.suppressed = false
        if talk != .off { talk = .off }
    }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return gen == generation }

    private func setState(_ s: State, gen: Int, detail: String? = nil) {
        DispatchQueue.main.async {
            guard self.current(gen) else { return }
            self.state = s
            if let detail { self.detail = detail }
        }
    }

    private func run(_ config: CameraConfig, gen: Int) {
        var attempt = 0
        while current(gen) {
            let s = V380Session(config: config)
            s.log = { Diag.log("live \($0)") }
            lock.lock()
            guard gen == generation else { lock.unlock(); return }
            session = s
            lock.unlock()

            do {
                try s.authenticateAnywhere(shouldStop: { !self.current(gen) })
                guard current(gen) else { break }
                setState(.connecting("Starting video…"), gen: gen)
                let info = try s.startLive()
                audio.label = "live"
                audio.resetStream()
                DispatchQueue.main.async {
                    if self.current(gen) { self.videoSize = CGSize(width: info.width, height: info.height) }
                }
                var frames = 0, seconds = 0, window = Date(), gotFirst = false
                try s.receiveFrames { [weak self] frame in
                    guard let self else { return }
                    guard frame.kind == .video else { self.audio.enqueue(frame, session: s); return }
                    self.renderer.enqueue(frame.payload, isKeyFrame: frame.isKeyFrame)
                    frames += 1
                    if !gotFirst {
                        gotFirst = true; attempt = 0
                        self.setState(.live, gen: gen, detail: "\(info.width)×\(info.height)")
                    }
                    let now = Date()
                    if now.timeIntervalSince(window) >= 1 {
                        let f = frames; frames = 0; window = now
                        let codec = self.renderer.codecName.map { " · \($0)" } ?? ""
                        seconds += 1
                        if seconds % 5 == 1 {
                            Diag.log("live \(info.width)x\(info.height)\(codec) fps=\(f) layer=\(self.renderer.statusDescription)")
                        }
                        DispatchQueue.main.async {
                            guard self.current(gen) else { return }
                            self.fps = f
                            self.detail = "\(info.width)×\(info.height)\(codec)"
                        }
                    }
                }
            } catch let error as V380Error where error.isCredentialError {
                // Only wrong username/password/device ID is worth stopping for; everything else can recover.
                setState(.failed(error.description.capitalizedFirst), gen: gen)
                break
            } catch {
                // Offline / 1002 / dropped stream: keep retrying so it reconnects on its own.
                guard current(gen) else { break }
                DispatchQueue.main.async { if self.current(gen) { self.stopTalk() } }
                attempt += 1
                Diag.log("live connection error: \(error)")
                setState(.connecting(Self.friendlyMessage(error, attempt: attempt)), gen: gen)
            }
            s.close()
            guard current(gen) else { break }
            Thread.sleep(forTimeInterval: min(Double(attempt) * 2, 10))
        }
        lock.lock(); if gen == generation { session = nil }; lock.unlock()
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension LiveController {
    /// Turns raw socket errors into something a person can act on. The camera's Wi-Fi drops often.
    static func friendlyMessage(_ error: Error, attempt: Int) -> String {
        if case SocketError.connectFailed = error {
            let waited = attempt > 3 ? " (offline for a while — check it's powered on)" : ""
            return "Camera offline — waiting for it to come back\(waited)"
        }
        if case SocketError.timeout = error { return "Camera is slow to respond — retrying…" }
        if error is SocketError { return "Connection dropped — reconnecting…" }
        if case V380Error.loginFailed(1002) = error {
            return "Camera busy or offline — retrying…\(attempt > 2 ? " (close it in the V380 Pro app if it's open there)" : "")"
        }
        if case V380Error.streamRefused = error { return "Camera busy — retrying…" }
        return "Reconnecting…"
    }
}

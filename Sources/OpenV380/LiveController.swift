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

    let renderer = VideoRenderer()
    let audio = AudioPlayer()
    private var session: V380Session?
    private var generation = 0
    private let lock = NSLock()

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }

    func start(_ config: CameraConfig) {
        stop()
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        setState(.connecting("Connecting…"), gen: gen)

        let thread = Thread { [weak self] in self?.run(config, gen: gen) }
        thread.name = "camview.live"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
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
                do {
                    try s.authenticateAnywhere(shouldStop: { !self.current(gen) })
                } catch let error as V380Error {
                    // The camera answered and refused; retrying the same login only hammers it.
                    Diag.log("live login refused: \(error)")
                    setState(.failed(error.description.capitalizedFirst), gen: gen)
                    break
                }
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
            } catch let error as V380Error where error.isFatal {
                setState(.failed(error.description.capitalizedFirst), gen: gen)
                break
            } catch {
                guard current(gen) else { break }
                attempt += 1
                Diag.log("live connection error: \(error)")
                setState(.connecting(Self.friendlyMessage(error, attempt: attempt)), gen: gen)
            }
            s.close()
            guard current(gen) else { break }
            Thread.sleep(forTimeInterval: min(Double(attempt), 5))
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
        return "Reconnecting…"
    }
}

import AVFoundation
import V380

/// IMA ADPCM, high nibble first, state carried across frames (FFmpeg's adpcm_ima_ws without VQA extradata).
struct IMAADPCMDecoder {
    private static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexTable: [Int32] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    private var predictor: Int32 = 0
    private var stepIndex: Int32 = 0

    mutating func reset() { predictor = 0; stepIndex = 0 }

    private mutating func expand(_ nibble: UInt8) -> Int16 {
        let step = Self.stepTable[Int(stepIndex)]
        stepIndex = min(max(stepIndex + Self.indexTable[Int(nibble)], 0), 88)
        let diff = ((2 * Int32(nibble & 7) + 1) * step) >> 3
        predictor += (nibble & 8) != 0 ? -diff : diff
        predictor = min(max(predictor, -32768), 32767)
        return Int16(predictor)
    }

    mutating func decode(_ bytes: [UInt8]) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(expand(b >> 4))
            out.append(expand(b & 0x0F))
        }
        return out
    }
}

enum ALaw {
    private static let table: [Int16] = (0..<256).map { i in
        var a = UInt8(i) ^ 0x55
        let sign = a & 0x80
        a &= 0x7F
        let exponent = Int(a >> 4)
        var mantissa = Int(a & 0x0F) << 4 + 8
        if exponent > 0 { mantissa = (mantissa + 0x100) << (exponent - 1) }
        return Int16(sign != 0 ? mantissa : -mantissa)
    }

    static func decode(_ bytes: [UInt8]) -> [Int16] { bytes.map { table[Int($0)] } }
}

/// Plays camera audio (8 kHz mono). While muted nothing is decoded and the audio engine is stopped.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var queuedSeconds: Double = 0
    private var adpcm = IMAADPCMDecoder()
    private var running = false
    private var _muted = true
    private var _suppressed = false

    // Undecodable (encrypted) audio decodes to full-scale noise; detect that and stay silent.
    private var railedSamples = 0
    private var totalSamples = 0
    private var noise = false

    var label = "audio"
    /// Called on the main queue when the stream's audio turns out to be undecodable noise.
    var onNoiseDetected: (() -> Void)?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set {
            lock.lock()
            _muted = newValue
            adpcm.reset()
            lock.unlock()
            newValue ? stopEngine() : startEngine()
        }
    }

    /// Drops incoming audio without changing the mute setting (used while talking, to avoid echo).
    var suppressed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _suppressed }
        set { lock.lock(); _suppressed = newValue; lock.unlock() }
    }

    /// Call when a new stream starts (the ADPCM decoder carries state that must not cross streams).
    func resetStream() {
        lock.lock()
        adpcm.reset(); railedSamples = 0; totalSamples = 0; noise = false
        lock.unlock()
        node.stop()
        lock.lock(); queuedSeconds = 0; lock.unlock()
        if running { node.play() }
    }

    /// `frame.payload` is already decrypted by the protocol layer.
    func enqueue(_ frame: MediaFrame, session: V380Session) {
        lock.lock()
        guard !_muted, !_suppressed, !noise, let codec = frame.audioCodec else { lock.unlock(); return }
        // Drop audio rather than fall ever further behind the picture on a slow link.
        if queuedSeconds > 0.8 { lock.unlock(); return }

        var samples: [Int16]
        switch codec {
        case .alaw:
            samples = ALaw.decode(frame.payload)
        case .pcm16:
            samples = frame.payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        case .imaADPCM:
            samples = adpcm.decode(frame.payload)
        case .unsupported:
            lock.unlock(); return
        }

        // Watchdog: encrypted/undecodable audio pins to the rails; real audio rarely does.
        railedSamples += samples.reduce(0) { $0 + (abs(Int($1)) >= 32000 ? 1 : 0) }
        totalSamples += samples.count
        if totalSamples >= 8000, Double(railedSamples) / Double(totalSamples) > 0.2 {
            noise = true
            Diag.log("\(label) audio is undecodable (encrypted); staying silent")
            lock.unlock()
            DispatchQueue.main.async { self.onNoiseDetected?() }
            return
        }
        lock.unlock()
        schedule(samples)
    }

    private func schedule(_ samples: [Int16]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let out = buffer.floatChannelData![0]
        for i in 0..<samples.count { out[i] = Float(samples[i]) / 32768 }
        let seconds = Double(samples.count) / 8000
        lock.lock(); queuedSeconds += seconds; lock.unlock()
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedSeconds = max(0, self.queuedSeconds - seconds); self.lock.unlock()
        }
    }

    private func startEngine() {
        guard !running else { return }
        do {
            try engine.start()
            node.play()
            running = true
        } catch {
            Diag.log("\(label) audio engine failed: \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        guard running else { return }
        node.stop()
        engine.stop()
        running = false
        lock.lock(); queuedSeconds = 0; lock.unlock()
    }
}

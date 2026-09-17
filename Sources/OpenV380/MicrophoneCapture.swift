import AVFoundation

/// Captures the default microphone as 8 kHz mono 16-bit samples, delivered in fixed-size blocks on the audio thread.
final class MicrophoneCapture {
    enum CaptureError: Error { case noInput }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!
    private var pending: [Int16] = []
    private var running = false

    /// Asks for microphone access the first time; calls back on the main queue.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
        default: done(false)
        }
    }

    func start(blockSize: Int, onBlock: @escaping ([Int16]) -> Void) throws {
        stop()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: format) else { throw CaptureError.noInput }
        pending.removeAll()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.format.sampleRate / inputFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: capacity) else { return }
            // Hand the tap's buffer over once; the converter keeps its resampling state between taps.
            var supplied = false
            _ = converter.convert(to: out, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            self.pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
            while self.pending.count >= blockSize {
                onBlock(Array(self.pending.prefix(blockSize)))
                self.pending.removeFirst(blockSize)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

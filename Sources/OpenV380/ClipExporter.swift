import AVFoundation
import Foundation
import V380

/// Downloads a time range of an SD-card recording and muxes it into a playable .mp4 (video only —
/// this camera's recorded audio is silence). No re-encoding: the camera's H.264/H.265 is copied through.
final class ClipExporter {
    private let session: V380Session
    private let converter = AnnexBConverter()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var cancelled = false
    private var reachedEnd = false
    private var destinationURL: URL!

    // One-frame delay so each sample gets a real duration (next PTS − this PTS).
    private var heldPayload: [UInt8]?
    private var heldKey = false
    private var heldPTS = CMTime.zero

    init(config: CameraConfig) { session = V380Session(config: config) }

    func cancel() { cancelled = true; session.cancel() }

    /// Exports `[start, end)` (camera wall-clock seconds) of `segment` to `url`. Blocks; run off the main thread.
    /// `progress` is 0…1; both callbacks fire on the main queue.
    func export(_ segment: RecordingSegment, from start: UInt32, to end: UInt32, url: URL,
                progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        destinationURL = url
        let total = max(1, Double(end) - Double(start))
        var firstTS: UInt64?
        var lastReported = Date.distantPast

        func finish(_ result: Result<URL, Error>) {
            DispatchQueue.main.async { completion(result) }
        }

        do {
            session.log = { Diag.log("export \($0)") }
            try session.authenticateAnywhere(shouldStop: { self.cancelled })
            guard !cancelled else { try? FileManager.default.removeItem(at: url); return }
            _ = try session.startPlayback(segment, from: start)

            try? FileManager.default.removeItem(at: url)

            try session.receivePlayback { [self] frame in
                guard !cancelled, frame.kind == .video else { return }
                let seconds = UInt32(clamping: frame.timestamp / 1000)
                // Stop once we've passed the requested end (timestamps are wall-clock).
                if seconds >= end && firstTS != nil { reachedEnd = true; session.cancel(); return }
                if firstTS == nil { firstTS = frame.timestamp }
                let pts = CMTime(value: Int64(frame.timestamp &- firstTS!), timescale: 1000)

                flushHeld(nextPTS: pts)
                heldPayload = frame.payload; heldKey = frame.isKeyFrame; heldPTS = pts

                let done = min(1, Double(seconds >= start ? seconds - start : 0) / total)
                if Date().timeIntervalSince(lastReported) > 0.2 {
                    lastReported = Date()
                    DispatchQueue.main.async { progress(done) }
                }
            }
        } catch {
            // Cancelling the session to stop at `end` surfaces as a socket error — that's a normal finish.
            if !reachedEnd && !cancelled {
                try? FileManager.default.removeItem(at: url)
                finish(.failure(error))
                return
            }
        }

        if cancelled { try? FileManager.default.removeItem(at: url); return }
        flushHeld(nextPTS: nil) // write the final frame

        guard let writer, let input, writer.status == .writing else {
            try? FileManager.default.removeItem(at: url)
            finish(.failure(ExportError("No video was received for that range.")))
            return
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status == .completed {
            DispatchQueue.main.async { progress(1) }
            finish(.success(url))
        } else {
            try? FileManager.default.removeItem(at: url)
            finish(.failure(writer.error ?? ExportError("Writing the .mp4 failed.")))
        }
    }

    /// Appends the previously-held frame now that we know its duration (or a default for the last one).
    private func flushHeld(nextPTS: CMTime?) {
        guard let payload = heldPayload else { return }
        heldPayload = nil
        let duration = nextPTS.map { $0 - heldPTS } ?? CMTime(value: 1, timescale: 15)
        let timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: heldPTS, decodeTimeStamp: .invalid)
        guard let sample = converter.sampleBuffer(from: payload, isKeyFrame: heldKey, timing: timing) else { return }

        if writer == nil { setUpWriter() }
        guard let input, let writer, writer.status == .writing else { return }
        while !input.isReadyForMoreMediaData && !cancelled { Thread.sleep(forTimeInterval: 0.01) }
        if !cancelled { input.append(sample) }
    }

    private func setUpWriter() {
        guard let format = converter.formatDescription,
              let w = try? AVAssetWriter(outputURL: destinationURL, fileType: .mp4) else { return }
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        i.expectsMediaDataInRealTime = false
        guard w.canAdd(i) else { return }
        w.add(i)
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: .zero)
        writer = w; input = i
    }

    struct ExportError: Error, LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

import Foundation
import V380

/// Browses and plays SD-card recordings.
final class PlaybackController: ObservableObject {
    enum State: Equatable {
        case idle
        case loading(String)
        case playing
        case paused
        case ended
        case failed(String)
    }

    @Published var day = Calendar.current.startOfDay(for: Date())
    @Published private(set) var segments: [RecordingSegment] = []
    @Published private(set) var listState: State = .idle
    @Published private(set) var state: State = .idle
    @Published private(set) var current: RecordingSegment?
    /// Camera wall-clock seconds of the frame on screen.
    @Published private(set) var position: UInt32 = 0
    @Published private(set) var speed: Double = 1

    enum ExportState: Equatable {
        case idle
        case running(Double)          // 0…1 progress
        case done(URL)
        case failed(String)
    }
    @Published private(set) var exportState: ExportState = .idle

    enum BulkState: Equatable {
        case idle
        case running(done: Int, total: Int, label: String, fileProgress: Double)
        case finished(count: Int, folder: URL)
        case failed(String)
    }
    @Published private(set) var bulkState: BulkState = .idle
    private var bulkCancelled = false
    private var bulkExporter: ClipExporter?

    /// yyyy-MM-dd HH-mm-ss in UTC (camera times are wall-clock stored as UTC) — safe for filenames.
    static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX") // true 24-hour, no AM/PM in filenames
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    let renderer = VideoRenderer()
    let audio = AudioPlayer()
    var config: CameraConfig?
    private var exporter: ClipExporter?

    private let lock = NSLock()
    private var generation = 0
    private var session: V380Session?
    private var activeQueue: FrameQueue?
    private var paused = false
    private var rebaseClock = false
    private var listGeneration = 0

    /// Camera times are local wall-clock values stored as UTC, so format them in UTC.
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func timeString(_ seconds: UInt32) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Midnight of `day` expressed in camera wall-clock seconds.
    var dayStart: UInt32 {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return UInt32(utc.date(from: c)?.timeIntervalSince1970 ?? 0)
    }

    // MARK: - Listing

    func loadDay(_ newDay: Date) {
        day = Calendar.current.startOfDay(for: newDay)
        reloadList()
    }

    func reloadList() {
        guard let config else { return }
        lock.lock(); listGeneration += 1; let gen = listGeneration; lock.unlock()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        listState = .loading("Reading SD card…")
        segments = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: Result<[RecordingSegment], Error> = .success([])
            // The camera's Wi-Fi drops connections now and then; a couple of quick retries hide that.
            for attempt in 1...3 {
                let s = V380Session(config: config)
                s.log = { Diag.log("rec \($0)") }
                do {
                    try s.authenticateAnywhere()
                    result = .success(try s.listRecordings(year: c.year!, month: c.month!, day: c.day!))
                    break
                } catch let error as SocketError where attempt < 3 {
                    Diag.log("rec list attempt \(attempt) failed: \(error)")
                    Thread.sleep(forTimeInterval: 1)
                } catch {
                    result = .failure(error)
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lock.lock(); let stale = gen != self.listGeneration; self.lock.unlock()
                guard !stale else { return }
                switch result {
                case .success(let list):
                    Diag.log("rec \(list.count) recordings on \(c.year!)-\(c.month!)-\(c.day!)")
                    self.segments = list
                    self.listState = .idle
                case .failure(let error):
                    Diag.log("rec list failed: \(error)")
                    self.listState = .failed("\(error)".capitalizedFirst)
                }
            }
        }
    }

    // MARK: - Transport

    /// Plays the recording covering `time`, or the next one after it.
    func play(at time: UInt32) {
        if let seg = segments.first(where: { time >= $0.start && time < $0.end }) {
            play(seg, from: time)
        } else if let next = segments.first(where: { $0.start > time }) {
            play(next, from: next.start)
        }
    }

    func play(_ segment: RecordingSegment, from time: UInt32? = nil) {
        guard let config else { return }
        stopThread()
        lock.lock(); generation += 1; let gen = generation; paused = false; lock.unlock()
        current = segment
        let start = min(max(time ?? segment.start, segment.start), segment.end > 0 ? segment.end - 1 : segment.start)
        position = start
        state = .loading("Loading \(Self.timeString(start))…")
        renderer.clear()
        audio.label = "rec"
        audio.resetStream()

        let thread = Thread { [weak self] in self?.run(config, segment: segment, from: start, gen: gen) }
        thread.name = "camview.playback"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func togglePause() {
        switch state {
        case .playing:
            lock.lock(); paused = true; lock.unlock()
            state = .paused
        case .paused:
            lock.lock(); paused = false; rebaseClock = true; let alive = session != nil; lock.unlock()
            if alive { state = .playing } else if let seg = current { play(seg, from: position) }
        case .ended, .failed:
            if let seg = current { play(seg, from: position) }
        default:
            break
        }
    }

    func seek(to time: UInt32) {
        guard let seg = current, time >= seg.start, time < seg.end else { play(at: time); return }
        play(seg, from: time)
    }

    func skip(_ seconds: Int) {
        let target = Int(position) + seconds
        seek(to: UInt32(max(0, target)))
    }

    func setSpeed(_ value: Double) {
        lock.lock(); speed = value; rebaseClock = true; lock.unlock()
    }

    func stop() {
        stopThread()
        lock.lock(); generation += 1; lock.unlock()
        renderer.clear()
        state = .idle
    }

    // MARK: - Export a clip

    /// Saves `[start, start+duration)` of the current recording to `url` as an .mp4.
    func exportClip(from start: UInt32, duration: UInt32, to url: URL) {
        guard let config, let segment = current else { return }
        let end = min(start &+ duration, segment.end)
        guard end > start else { return }
        stop() // free the camera's connection slot for the export

        exportState = .running(0)
        let exp = ClipExporter(config: config)
        exporter = exp
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            exp.export(segment, from: start, to: end, url: url,
                       progress: { p in self?.exportState = .running(p) },
                       completion: { result in
                           switch result {
                           case .success(let saved): self?.exportState = .done(saved)
                           case .failure(let error): self?.exportState = .failed(error.localizedDescription)
                           }
                           self?.exporter = nil
                       })
        }
    }

    /// Exports a specific segment (sets it current first). Used by the UI's "export from here" and tests.
    func exportSegment(_ segment: RecordingSegment, from start: UInt32, duration: UInt32, to url: URL) {
        current = segment
        exportClip(from: start, duration: duration, to: url)
    }

    func cancelExport() {
        exporter?.cancel(); exporter = nil
        exportState = .idle
    }

    func dismissExport() { exportState = .idle }

    // MARK: - Bulk download (a whole date range)

    /// Downloads every recording between `fromDay` and `toDay` (inclusive) into `folder`, one .mp4 each.
    func bulkDownload(fromDay: Date, toDay: Date, into folder: URL) {
        guard let config else { return }
        stop()
        bulkCancelled = false
        bulkState = .running(done: 0, total: 0, label: "Listing recordings…", fileProgress: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runBulk(config: config, fromDay: fromDay, toDay: toDay, folder: folder)
        }
    }

    func cancelBulk() {
        bulkCancelled = true
        bulkExporter?.cancel()
    }

    func dismissBulk() { bulkState = .idle }

    private func setBulk(_ s: BulkState) { DispatchQueue.main.async { self.bulkState = s } }

    private func runBulk(config: CameraConfig, fromDay: Date, toDay: Date, folder: URL) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let last = cal.startOfDay(for: toDay)

        // 1. Collect every segment across the day range.
        var all: [RecordingSegment] = []
        var day = cal.startOfDay(for: fromDay)
        while day <= last && !bulkCancelled {
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let s = V380Session(config: config)
            s.log = { Diag.log("bulk \($0)") }
            do {
                try s.authenticateAnywhere(shouldStop: { self.bulkCancelled })
                all += try s.listRecordings(year: c.year!, month: c.month!, day: c.day!)
            } catch {
                Diag.log("bulk list \(c.year!)-\(c.month!)-\(c.day!) failed: \(error)")
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? last.addingTimeInterval(1)
        }
        if bulkCancelled { setBulk(.idle); return }
        let total = all.count
        guard total > 0 else { setBulk(.failed("No recordings found in that date range.")); return }

        // 2. Download each segment in order.
        var done = 0
        for segment in all {
            if bulkCancelled { break }
            let name = "OpenV380 \(Self.fileStampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(segment.start)))).mp4"
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { done += 1; continue } // resume-friendly

            let exp = ClipExporter(config: config)
            bulkExporter = exp
            let label = PlaybackController.timeString(segment.start)
            setBulk(.running(done: done, total: total, label: label, fileProgress: 0))
            exp.export(segment, from: segment.start, to: segment.end, url: url,
                       progress: { p in self.setBulk(.running(done: done, total: total, label: label, fileProgress: p)) },
                       completion: { _ in })
            // export() blocks until the file is finished, so it's safe to continue here.
            done += 1
        }
        bulkExporter = nil
        if bulkCancelled { setBulk(.idle) } else { setBulk(.finished(count: done, folder: folder)) }
    }

    private func stopThread() {
        lock.lock()
        let s = session, q = activeQueue
        session = nil; activeQueue = nil
        lock.unlock()
        q?.cancel()
        s?.cancel()
    }

    private func isCurrent(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return gen == generation }

    private func publish(_ gen: Int, _ update: @escaping (PlaybackController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            update(self)
        }
    }

    // MARK: - Playback threads

    /// A reader thread keeps pulling packets (so acknowledgements go out on time) into this queue,
    /// while the player thread paces frames out of it by timestamp.
    final class FrameQueue {
        private var frames: [MediaFrame] = []
        private var head = 0
        private var bytes = 0
        private let cond = NSCondition()
        private var finished = false
        private var cancelled = false
        private(set) var error: Error?
        private let maxBytes = 96 << 20

        var stats: (frames: Int, megabytes: Int) {
            cond.lock(); defer { cond.unlock() }
            return (frames.count - head, bytes >> 20)
        }

        func push(_ frame: MediaFrame) {
            cond.lock()
            while bytes > maxBytes && !cancelled { cond.wait(until: Date().addingTimeInterval(0.2)) }
            if !cancelled {
                frames.append(frame)
                bytes += frame.payload.count
                cond.signal()
            }
            cond.unlock()
        }

        /// Next frame, or nil once the stream has ended (or was cancelled) and everything was played.
        func pop() -> MediaFrame? {
            cond.lock(); defer { cond.unlock() }
            while head == frames.count && !finished && !cancelled { cond.wait(until: Date().addingTimeInterval(0.2)) }
            guard !cancelled, head < frames.count else { return nil }
            let f = frames[head]
            head += 1
            bytes -= f.payload.count
            if head > 512 { frames.removeFirst(head); head = 0 }
            cond.broadcast()
            return f
        }

        func finish(_ error: Error?) {
            cond.lock(); finished = true; self.error = error; cond.broadcast(); cond.unlock()
        }

        func cancel() {
            cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
        }
    }

    private func run(_ config: CameraConfig, segment: RecordingSegment, from start: UInt32, gen: Int) {
        var resumeFrom = start
        var reconnects = 0
        var position = start

        while isCurrent(gen) {
            let s = V380Session(config: config)
            s.log = { Diag.log("rec \($0)") }
            let queue = FrameQueue()
            lock.lock()
            guard gen == generation else { lock.unlock(); return }
            session = s
            activeQueue = queue
            lock.unlock()

            do {
                try authenticateWithRetry(s, gen: gen)
                guard isCurrent(gen) else { break }
                _ = try s.startPlayback(segment, from: resumeFrom)
            } catch {
                s.stopPlayback()
                guard isCurrent(gen) else { break }
                Diag.log("rec playback start failed: \(error)")
                publish(gen) { $0.state = .failed("\(error)".capitalizedFirst) }
                break
            }

            let reader = Thread {
                do {
                    try s.receivePlayback { frame in queue.push(frame) }
                    queue.finish(nil)
                } catch {
                    queue.finish(error)
                }
            }
            reader.name = "camview.playback.reader"
            reader.qualityOfService = .userInitiated
            reader.start()

            let played = playFrames(from: queue, session: s, segment: segment, gen: gen, position: &position)
            s.stopPlayback()
            guard isCurrent(gen) else { break }

            if queue.error == nil {
                // Segment finished: continue with the next recording, if any.
                DispatchQueue.main.async {
                    guard self.isCurrent(gen) else { return }
                    if let idx = self.segments.firstIndex(of: segment), idx + 1 < self.segments.count {
                        self.play(self.segments[idx + 1])
                    } else {
                        self.position = segment.end
                        self.state = .ended
                    }
                }
                break
            }

            // The connection dropped mid-recording: pick up where the picture stopped.
            if played > 0 { reconnects = 0 }
            reconnects += 1
            Diag.log("rec connection lost after \(played) frames at \(Self.timeString(position)): \(queue.error!) (retry \(reconnects))")
            guard reconnects <= 3, position + 1 < segment.end else {
                publish(gen) { $0.state = .failed("\(queue.error!)".capitalizedFirst) }
                break
            }
            resumeFrom = max(segment.start, position)
            publish(gen) { $0.state = .loading("Reconnecting…") }
            renderer.clear()
            Thread.sleep(forTimeInterval: 0.5)
        }

        lock.lock()
        if gen == generation { session = nil; activeQueue = nil }
        lock.unlock()
    }

    private func authenticateWithRetry(_ s: V380Session, gen: Int) throws {
        var attempt = 0
        while true {
            do {
                attempt += 1
                try s.authenticateAnywhere(shouldStop: { !self.isCurrent(gen) })
                return
            } catch let error as SocketError where attempt < 3 {
                Diag.log("rec playback login attempt \(attempt) failed: \(error)")
                Thread.sleep(forTimeInterval: 1)
                guard isCurrent(gen) else { throw error }
            }
        }
    }

    /// Plays queued frames at their recorded pace. Returns the number of video frames shown.
    private func playFrames(from queue: FrameQueue, session s: V380Session, segment: RecordingSegment,
                            gen: Int, position: inout UInt32) -> Int {
        var baseTimestamp: UInt64?
        var baseClock = Date()
        var lastPublished = Date.distantPast
        var lastStats = Date()
        var shown = 0

        while let frame = queue.pop() {
            guard isCurrent(gen) else { break }

            while true {
                lock.lock(); let p = paused; lock.unlock()
                guard p, isCurrent(gen) else { break }
                Thread.sleep(forTimeInterval: 0.05)
            }

            lock.lock()
            let speed = self.speed
            if rebaseClock { baseTimestamp = nil; rebaseClock = false }
            lock.unlock()

            // At 16×+ the network can't deliver every frame fast enough, so scan by keyframes only:
            // skip P-frames (which also spares the decoder) and don't pace — jump through the recording.
            let keyframeScan = speed >= 16
            if keyframeScan, frame.kind == .video, !frame.isKeyFrame {
                let seconds = UInt32(clamping: frame.timestamp / 1000)
                if seconds + 86400 > segment.start && seconds < segment.end + 86400 { position = seconds }
                continue
            }

            let ts = frame.timestamp
            if baseTimestamp == nil || ts < baseTimestamp! { baseTimestamp = ts; baseClock = Date() }
            if !keyframeScan {
                let wait = baseClock.addingTimeInterval(Double(ts - baseTimestamp!) / 1000 / speed).timeIntervalSinceNow
                if wait > 3 || wait < -1 {
                    baseTimestamp = ts; baseClock = Date()   // gap or fell behind: resync instead of stalling
                } else if wait > 0.002 {
                    Thread.sleep(forTimeInterval: wait)
                }
            }

            if frame.kind == .video {
                if shown == 0 {
                    Diag.log("rec first frame ts=\(ts) key=\(frame.isKeyFrame)")
                    publish(gen) { $0.state = .playing }
                }
                shown += 1
                renderer.enqueue(frame.payload, isKeyFrame: frame.isKeyFrame)

                // Timestamps are the camera's wall clock in milliseconds.
                let seconds = UInt32(clamping: ts / 1000)
                if seconds + 86400 > segment.start && seconds < segment.end + 86400 { position = seconds }
                if Date().timeIntervalSince(lastPublished) > 0.25 {
                    lastPublished = Date()
                    let pos = position
                    publish(gen) { c in
                        c.position = pos
                        if case .loading = c.state { c.state = .playing }
                    }
                }
            } else if speed == 1 {
                audio.enqueue(frame, session: s)
            }

            if Date().timeIntervalSince(lastStats) > 10 {
                lastStats = Date()
                let q = queue.stats
                Diag.log("rec playing \(Self.timeString(position)) shown=\(shown) buffered=\(q.frames) frames/\(q.megabytes)MB layer=\(renderer.statusDescription)")
            }
        }
        return shown
    }
}

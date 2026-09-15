import Foundation

/// One continuous recording on the camera's SD card.
public struct RecordingSegment: Identifiable, Hashable {
    public enum Kind: UInt8 {
        case normal = 1, motion = 2, alarm = 3
    }

    public let id: UInt32
    public let rawType: UInt8
    /// Seconds since 1970 of the camera's local wall-clock time (the camera stores local time as if it were UTC).
    public let start: UInt32
    public let end: UInt32

    public var kind: Kind? { Kind(rawValue: rawType) }
    public var duration: TimeInterval { TimeInterval(end >= start ? end - start : 0) }
}

/// SD-card recording search and playback ("segment" protocol, device version >= 3).
/// Layouts follow Macrovideo SDK 6.0 RecordFileHelper.getRecordSegmentFromServerCallBack and
/// libglesplayer GetPlayBackSegmentFromDevice / PlayBackSegmentDataCtrlThreadFunc.
extension V380Session {

    // MARK: - Search (361 -> 461, 362 -> 462...)

    /// Lists recordings for one calendar day (camera local time). Call `authenticate()` first.
    public func listRecordings(year: Int, month: Int, day: Int) throws -> [RecordingSegment] {
        let s = try TCPSocket(host: relayIP, port: config.port, timeout: 5)
        defer { s.close() }

        // Cloud relay layout (SDK getRecordSegmentFromMRServer): 256 bytes, phoneType 1012, routing domain.
        var cmd = [UInt8](repeating: 0, count: 256)
        cmd.putU32(361, at: 0)
        cmd.putU32(1012, at: 4)
        cmd.putASCII(cloudHostname, at: 8, max: 50)
        cmd.putU32(UInt32(config.port), at: 58)
        cmd.putU32(config.deviceId, at: 62)
        cmd.putU32(ticket, at: 66)
        cmd[70] = 0 // channel
        cmd[71] = 0 // all types
        for (base, h, m, sec) in [(72, 0, 0, 0), (92, 23, 59, 59)] {
            cmd.putU16(UInt16(year), at: base)
            cmd.putU16(UInt16(month), at: base + 2)
            cmd.putU16(UInt16(day), at: base + 4)
            cmd.putU16(UInt16(h), at: base + 6)
            cmd.putU16(UInt16(m), at: base + 8)
            cmd.putU16(UInt16(sec), at: base + 10)
        }
        try s.write(cmd)

        var head = [UInt8](repeating: 0, count: 32)
        try s.readExact(into: &head, count: 32, timeout: 8)
        // The relay sends 2000 keep-alives until the device answers; wait for the real reply.
        while head.u32(0) == 2000 { try s.readExact(into: &head, count: 32, timeout: 8) }
        let command = Int32(bitPattern: head.u32(0))
        let result = Int32(bitPattern: head.u32(4))
        log("[rec] search reply cmd=\(command) result=\(result) count=\(head.u16(8))")
        guard command == 461 || result == 1 else {
            throw V380Error.badResponse("recording search refused (\(command)/\(result))")
        }
        if result < 0 { throw V380Error.badResponse("recording search failed (\(result))") }
        // The SDK ignores the count here and always asks for the blocks; some firmware reports 0.

        var ask = [UInt8](repeating: 0, count: 32)
        ask.putU32(362, at: 0)
        try s.write(ask)

        var segments: [RecordingSegment] = []
        var block = [UInt8](repeating: 0, count: 512)
        while !isCancelled {
            do {
                try s.readExact(into: &block, count: 512, timeout: 8)
            } catch SocketError.timeout where segments.isEmpty {
                log("[rec] no list blocks before timeout")
                break
            }
            let c = block.u32(0)
            if c == 460 { break }
            if c == 2000 { continue } // relay keep-alive while the device streams the list
            guard c == 462 else { continue }
            let flag = block.u16(4)
            let n = min(Int(block.u16(6)), (512 - 8) / 13)
            for i in 0..<n {
                let o = 8 + 13 * i
                let id = block.u32(o)
                guard Int32(bitPattern: id) > 0 else { continue }
                segments.append(RecordingSegment(id: id, rawType: block[o + 4], start: block.u32(o + 5), end: block.u32(o + 9)))
            }
            if flag == 12 { break }
        }
        return segments.sorted { $0.start < $1.start }
    }

    // MARK: - Playback (363 -> 463, 364 start/ack/stop)

    public struct PlaybackInfo {
        public var width: Int
        public var height: Int
    }

    /// Starts sending `segment` from `time` (camera wall-clock seconds). Frames are read with `receivePlayback`.
    public func startPlayback(_ segment: RecordingSegment, from time: UInt32) throws -> PlaybackInfo {
        let s = try TCPSocket(host: relayIP, port: config.port, timeout: 5)
        lock.lock(); socket = s; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { s.shutdown() }

        // The official player sends a session tag here, but this firmware tags every reply with 0, so match it.
        playbackNote = 0
        playbackSegment = segment.id
        lastPlaybackFrameId = 0
        lastPlaybackPacket = 0
        let clock = Self.wallClock(time)

        // Cloud routing (same shape as the 361/301 cloud variants): domain@8, port@58, then segment + clock.
        var req = [UInt8](repeating: 0, count: 256)
        req.putU32(363, at: 0)
        req.putU32(1012, at: 4)
        req.putASCII(cloudHostname, at: 8, max: 50)
        req.putU32(UInt32(config.port), at: 58)
        req.putU32(config.deviceId, at: 62)
        req.putU32(ticket, at: 66)
        req.putU32(segment.id, at: 70)
        Self.putClock(clock, into: &req, at: 74)
        try s.write(req)

        var resp = [UInt8](repeating: 0, count: 64)
        try s.readExact(into: &resp, count: 64, timeout: 8)
        while resp.u32(0) == 2000 { try s.readExact(into: &resp, count: 64, timeout: 8) }
        let command = resp.u32(0)
        let result = Int32(bitPattern: resp.u32(4))
        log("[rec] playback reply cmd=\(command) result=\(result)")
        guard command == 463, result == 1000 else {
            throw V380Error.badResponse("camera refused playback (\(command)/\(result))")
        }
        let info = PlaybackInfo(width: Int(Int16(bitPattern: resp.u16(14))), height: Int(Int16(bitPattern: resp.u16(16))))

        var start = [UInt8](repeating: 0, count: 32)
        start.putU32(364, at: 0)
        start[4] = 1
        start[5] = playbackNote
        start.putU16(200, at: 6)
        start.putU32(0, at: 8)
        start.putU32(segment.id, at: 12)
        Self.putClock(clock, into: &start, at: 16)
        start.putU16(0, at: 23)
        try s.write(start)
        return info
    }

    /// Blocks, delivering recorded frames. Returns normally when the segment ends.
    public func receivePlayback(_ onFrame: (MediaFrame) -> Void) throws {
        guard let s = socket else { throw SocketError.closed }
        var header = [UInt8](repeating: 0, count: 8)
        var chunk = [UInt8](repeating: 0, count: 65536)
        var pending: [UInt8] = []
        pending.reserveCapacity(1 << 20)
        var packetsSinceAck = 0

        while !isCancelled {
            try s.readExact(into: &header, count: 8, timeout: 12)
            let type = header[0], note = header[1]
            let packet = header.u16(2)
            let size = Int(header.u16(4))
            if size > 0 {
                if chunk.count < size { chunk = [UInt8](repeating: 0, count: size) }
                try s.readExact(into: &chunk, count: size, timeout: 12)
            }

            switch type {
            case 0x7F:
                playbackNote = note
                lastPlaybackPacket = packet
                pending.append(contentsOf: chunk[0..<size])
                packetsSinceAck += 1
                try drainFrames(&pending, onFrame)
                if packetsSinceAck >= 200 { try sendAck(s); packetsSinceAck = 0 }
            case 0x6F: // camera waits for an acknowledgement
                try sendAck(s); packetsSinceAck = 0
            case 0xEF:
                log("[rec] segment finished")
                return
            case 0x1F:
                continue
            default:
                throw V380Error.badResponse("playback packet type 0x\(String(type, radix: 16))")
            }
        }
    }

    /// Tells the camera to stop sending and closes the playback socket.
    public func stopPlayback() {
        lock.lock(); let s = socket; socket = nil; lock.unlock()
        guard let s else { return }
        var stop = [UInt8](repeating: 0, count: 32)
        stop.putU32(364, at: 0)
        stop[4] = 3
        try? s.write(stop)
        s.close()
    }

    private func sendAck(_ s: TCPSocket) throws {
        var ack = [UInt8](repeating: 0, count: 32)
        ack.putU32(364, at: 0)
        ack[4] = 2
        ack[5] = playbackNote
        ack.putU16(200, at: 6)
        ack.putU16(UInt16(truncatingIfNeeded: lastPlaybackFrameId), at: 8)
        ack.putU32(playbackSegment, at: 12)
        ack.putU16(lastPlaybackPacket, at: 23)
        try s.write(ack)
    }

    /// Frames inside the data packets: 22-byte header (id, type, ?, ?, timestamp ms, size) then the payload.
    private func drainFrames(_ buf: inout [UInt8], _ onFrame: (MediaFrame) -> Void) throws {
        var offset = 0
        defer { if offset > 0 { buf.removeFirst(offset) } }
        while buf.count - offset >= 22 {
            let frameId = buf.u32(offset)
            let type = buf.u16(offset + 4)
            let timestamp = buf.u64(offset + 10)
            let size = Int(buf.u32(offset + 18))
            guard size <= 0x80000 else { throw V380Error.badResponse("recorded frame too large (\(size))") }
            guard buf.count - offset >= 22 + size else { return }
            let body = Array(buf[(offset + 22)..<(offset + 22 + size)])
            offset += 22 + size
            lastPlaybackFrameId = frameId

            switch type {
            case 0, 1, 40, 41, 50, 51, 52, 53:
                var payload = body
                // Recorded media on this firmware is AES-encrypted with the session key, same as the live stream.
                if Self.findStartCode(payload) == nil, usesEncryptedMedia { decryptVideo(&payload) }
                guard let sc = Self.findStartCode(payload) else {
                    log("[rec] video frame type \(type) without start code, len=\(size)"); continue
                }
                if sc > 0 { payload.removeFirst(sc) }
                let key = [0, 40, 50, 52].contains(type)
                onFrame(MediaFrame(kind: .video, isKeyFrame: key, timestamp: timestamp, frameRate: 0, payload: payload))
            case 21:
                onFrame(MediaFrame(kind: .audio, audioCodec: .pcm16, isKeyFrame: false, timestamp: timestamp, frameRate: 0, payload: decryptMedia(body)))
            case 22:
                onFrame(MediaFrame(kind: .audio, audioCodec: .imaADPCM, isKeyFrame: false, timestamp: timestamp, frameRate: 0, payload: decryptMedia(body)))
            case 24, 25, 26:
                onFrame(MediaFrame(kind: .audio, audioCodec: .unsupported(type), isKeyFrame: false, timestamp: timestamp, frameRate: 0, payload: body))
            default:
                log("[rec] unknown frame type \(type) len=\(size)")
            }
        }
    }

    // MARK: - Wall clock helpers

    typealias Clock = (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)

    static func wallClock(_ seconds: UInt32) -> Clock {
        var t = time_t(seconds)
        var tm = tm()
        gmtime_r(&t, &tm)
        return (Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1, Int(tm.tm_mday), Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec))
    }

    /// u16 year, u8 month, u8 day, u8 hour, u8 minute, u8 second.
    static func putClock(_ c: Clock, into buf: inout [UInt8], at o: Int) {
        buf.putU16(UInt16(c.year), at: o)
        buf[o + 2] = UInt8(c.month)
        buf[o + 3] = UInt8(c.day)
        buf[o + 4] = UInt8(c.hour)
        buf[o + 5] = UInt8(c.minute)
        buf[o + 6] = UInt8(c.second)
    }
}

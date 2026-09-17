import CommonCrypto
import Foundation

/// Two-way audio ("talk"): plays microphone audio on the camera's speaker, through the cloud relay.
/// Layouts follow V380 Pro 2.2.81 libhsMediaLibrary HSLiveDataV2Transmitter::sendSpeakAudioToServer,
/// the talk counterpart of the 301 live stream.
public final class V380TalkChannel {
    /// Audio is 8 kHz mono; each block of this many samples becomes one 256-byte IMA ADPCM frame (~63 ms).
    public static let samplesPerBlock = 505

    private let socket: TCPSocket
    private let mediaKey: [UInt8]?
    private let lock = NSLock()
    private var encoder = IMAADPCMEncoder()
    private var frameId: UInt8 = 0
    private var lastKeepAlive = Date()
    private var closed = false

    fileprivate init(socket: TCPSocket, mediaKey: [UInt8]?) {
        self.socket = socket
        self.mediaKey = mediaKey
    }

    /// Sends one block of `samplesPerBlock` 16-bit samples. Throws once the relay connection is gone.
    public func send(_ samples: [Int16]) throws {
        precondition(samples.count == Self.samplesPerBlock)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw SocketError.closed }

        // The app pings every 3 s on this socket, even while audio is flowing.
        if Date().timeIntervalSince(lastKeepAlive) >= 3 {
            var alive = [UInt8](repeating: 0, count: 16)
            alive.putU32(188, at: 0)
            try socket.write(alive)
            lastKeepAlive = Date()
            // The relay's replies are never needed; drain them so its buffers don't fill.
            while (try? socket.waitReadable(0)) == true, (try? socket.readSome(max: 4096, timeout: 0)) != nil {}
        }

        var payload = encoder.encode(samples)
        if let mediaKey {
            aesECB(CCOperation(kCCEncrypt), key: mediaKey, data: &payload, offset: 0, count: payload.count / 16 * 16)
        }

        // Frames larger than 496 bytes are split; an ADPCM block (256 bytes) always fits in one packet.
        let chunk = 496
        let count = (payload.count + chunk - 1) / chunk
        for index in 0..<count {
            let body = payload[(index * chunk)..<min(payload.count, (index + 1) * chunk)]
            var packet = [UInt8](repeating: 0, count: 16)
            packet.putU32(1013, at: 0)
            packet[4] = UInt8(count)
            packet[5] = UInt8(index)
            packet[6] = 0x16 // IMA ADPCM
            packet.putU16(UInt16(body.count), at: 13)
            packet[15] = frameId
            try socket.write(packet + body)
        }
        frameId &+= 1
    }

    public func close() {
        lock.lock(); closed = true; lock.unlock()
        socket.shutdown()
        socket.close()
    }
}

extension V380Session {
    /// Opens the talk channel for the logged-in device. Call `authenticateAnywhere()` first.
    public func openTalk() throws -> V380TalkChannel {
        let s = try TCPSocket(host: relayIP, port: config.port, timeout: 5)
        do {
            var cmd = [UInt8](repeating: 0, count: 256)
            cmd.putU32(377, at: 0)
            cmd.putU32(1002, at: 4)
            cmd.putASCII(cloudHostname, at: 8, max: 50)
            cmd.putU32(UInt32(config.port), at: 58)
            cmd.putU32(config.deviceId, at: 62)
            cmd.putU32(ticket, at: 66)
            cmd.putU32(sessionId, at: 70)
            cmd.putU32(config.hd ? 1 : 0, at: 74)
            try s.write(cmd)

            var head = [UInt8](repeating: 0, count: 32)
            try s.readExact(into: &head, count: 32, timeout: 8)
            // The relay sends 2000 keep-alives until the device answers.
            while head.u32(0) == 2000 { try s.readExact(into: &head, count: 32, timeout: 8) }
            let command = Int32(bitPattern: head.u32(0)), result = Int32(bitPattern: head.u32(4))
            log("[talk] reply cmd=\(command) result=\(result)")
            guard command == 477, result == 1000 else {
                throw V380Error.badResponse("camera refused talk (\(command)/\(result))")
            }
            s.setSendTimeout(2)
            return V380TalkChannel(socket: s, mediaKey: usesEncryptedMedia ? mediaKey : nil)
        } catch {
            s.close()
            throw error
        }
    }
}

/// IMA ADPCM in the camera's 256-byte block: first sample (Int16 LE), step index, a zero byte, then the
/// remaining 504 samples as nibbles, low nibble first. The step index carries over from block to block.
struct IMAADPCMEncoder {
    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    private var stepIndex = 0

    mutating func encode(_ samples: [Int16]) -> [UInt8] {
        let nibbles = samples.count - 1
        var out = [UInt8](repeating: 0, count: 4 + (nibbles + 1) / 2)
        out.putU16(UInt16(bitPattern: samples[0]), at: 0)
        out[2] = UInt8(stepIndex)
        var predictor = Int(samples[0])

        for i in 1..<samples.count {
            let step = Self.stepTable[stepIndex]
            var diff = Int(samples[i]) - predictor
            var code = 0
            if diff < 0 { code = 8; diff = -diff }
            // Standard bit-by-bit quantizer, so the reconstruction matches the camera's decoder exactly.
            var delta = step >> 3
            if diff >= step { code |= 4; diff -= step; delta += step }
            if diff >= step >> 1 { code |= 2; diff -= step >> 1; delta += step >> 1 }
            if diff >= step >> 2 { code |= 1; delta += step >> 2 }
            predictor = min(max(predictor + (code & 8 != 0 ? -delta : delta), -32768), 32767)
            stepIndex = min(max(stepIndex + Self.indexTable[code], 0), 88)

            let byte = 4 + (i - 1) / 2
            if i % 2 == 1 { out[byte] = UInt8(code) } else { out[byte] |= UInt8(code << 4) }
        }
        return out
    }
}

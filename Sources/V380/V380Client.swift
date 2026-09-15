import CommonCrypto
import Foundation

public struct CameraConfig: Codable, Equatable {
    public var port: UInt16 = 8800
    public var deviceId: UInt32
    public var username: String = "admin"
    public var password: String
    public var hd: Bool = true

    public init(port: UInt16 = 8800, deviceId: UInt32, username: String = "admin", password: String, hd: Bool = true) {
        self.port = port; self.deviceId = deviceId
        self.username = username; self.password = password; self.hd = hd
    }
}

public enum V380Error: Error, CustomStringConvertible {
    case badResponse(String)
    case wrongPassword, wrongUsername, wrongDeviceId
    case loginFailed(UInt32)
    case streamRefused(Int32)

    public var description: String {
        switch self {
        case .badResponse(let m): return "unexpected reply from camera: \(m)"
        case .wrongPassword: return "wrong camera password"
        case .wrongUsername: return "wrong camera username"
        case .wrongDeviceId: return "wrong device ID"
        case .loginFailed(let c):
            // 1002 comes from the cloud relay, not the camera's credential check — the device is unreachable.
            if c == 1002 { return "camera appears offline (V380's cloud can't reach it right now)" }
            return "camera refused login (code \(c))"
        case .streamRefused(let c): return "camera refused the stream (code \(c))"
        }
    }

    /// Credential errors will not fix themselves by retrying.
    public var isFatal: Bool {
        switch self {
        case .wrongPassword, .wrongUsername, .wrongDeviceId, .loginFailed: return true
        default: return false
        }
    }

    /// Wrong credentials fail identically on every path; other login codes (e.g. a relay's 1002
    /// "device not on this server") are worth retrying against a different relay.
    public var isCredentialError: Bool {
        switch self {
        case .wrongPassword, .wrongUsername, .wrongDeviceId: return true
        default: return false
        }
    }
}

public struct StreamInfo {
    public var width: Int
    public var height: Int
    public var deviceVersion: UInt8
    public var communicationVersion: UInt16
}

public enum MediaKind { case video, audio }

public enum AudioCodec {
    case imaADPCM   // 8 kHz mono, high nibble first (FFmpeg adpcm_ima_ws)
    case alaw       // G.711 A-law, 8 kHz mono
    case pcm16      // 8 kHz mono, little-endian
    case unsupported(UInt16)
}

public struct MediaFrame {
    public var kind: MediaKind
    public var audioCodec: AudioCodec? = nil
    public var isKeyFrame: Bool
    /// Camera-supplied timestamp (milliseconds).
    public var timestamp: UInt64
    public var frameRate: UInt16
    /// Video: H.264/H.265 Annex-B bytestream. Audio: raw codec payload.
    public var payload: [UInt8]
}

/// Talks to a V380 camera over its native TCP protocol (LAN, port 8800).
/// Protocol details follow github.com/PyanSofyan/V380Decoder.
public final class V380Session {
    public let config: CameraConfig
    var socket: TCPSocket?
    var ticket: UInt32 = 0
    private var sessionId: UInt32 = 0
    var deviceVersion: UInt8 = 0
    private var communicationVersion: UInt16 = 0
    var mediaKey = [UInt8](repeating: 0, count: 16)
    let lock = NSLock()
    var cancelled = false

    /// The V380 cloud relay this session streams through (set by `connect()`).
    public private(set) var relayIP = ""

    /// Hostname the relay uses to route to this specific device.
    var cloudHostname: String { "\(config.deviceId).nvdvr.net" }

    // SD-card playback state (see Recordings.swift).
    var playbackNote: UInt8 = 0
    var playbackSegment: UInt32 = 0
    var lastPlaybackFrameId: UInt32 = 0
    var lastPlaybackPacket: UInt16 = 0

    public var log: (String) -> Void = { _ in }

    public init(config: CameraConfig) {
        self.config = config
    }

    public func cancel() {
        lock.lock(); cancelled = true; let s = socket; lock.unlock()
        s?.shutdown()
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    // MARK: - Login (cmd 1167 -> 1168)

    /// Firmware generations differ in three places. Each is only varied when the camera's answer points at it:
    /// - header version byte: an unsupported one gets a -100 reply instead of 1168
    /// - username: 1011 (user not found); newer cameras use the device ID instead of "admin"
    /// - password padding: 1012 (wrong password)
    enum UsernameChoice: String, CaseIterable { case entered, deviceId }
    enum PasswordEncoding: String, CaseIterable {
        case zeroPadded48   // github.com/PyanSofyan/V380Decoder
        case pkcs7Twice     // Macrovideo SDK 6.0 LoginHelper.LoginFromServerEX
    }

    struct LoginVariant: Equatable {
        var version: UInt8
        var username: UsernameChoice
        var password: PasswordEncoding
        var key: String { "h\(version)-\(username.rawValue)-\(password.rawValue)" }
    }

    private static let variantKey = "v380.loginVariant"

    /// Logs in, starting with the variant that worked last time.
    public func authenticate() throws {
        let remembered = UserDefaults.standard.string(forKey: Self.variantKey)
        var versions: [UInt8] = [31, 2]
        var usernames = UsernameChoice.allCases
        var passwords = PasswordEncoding.allCases
        if let r = remembered {
            if r.hasPrefix("h2-") { versions.reverse() }
            if r.contains("-deviceId-") { usernames.reverse() }
            if r.hasSuffix("pkcs7Twice") { passwords.reverse() }
        }
        // Nothing to vary if the user typed the device ID as the username.
        if config.username == String(config.deviceId) { usernames = [.entered] }

        var lastError: Error = V380Error.wrongUsername
        versionLoop: for version in versions {
            userLoop: for username in usernames {
                for password in passwords {
                    let variant = LoginVariant(version: version, username: username, password: password)
                    do {
                        try authenticate(variant)
                        if variant.key != remembered { UserDefaults.standard.set(variant.key, forKey: Self.variantKey) }
                        return
                    } catch V380Error.wrongUsername {
                        lastError = V380Error.wrongUsername
                        continue userLoop
                    } catch V380Error.wrongPassword {
                        lastError = V380Error.wrongPassword
                        continue
                    } catch V380Error.badResponse(let detail) {
                        lastError = V380Error.badResponse(detail)
                        continue versionLoop
                    } catch V380Error.loginFailed(let code) {
                        // e.g. relay 1002: unclear which field is at fault, so keep trying every variant.
                        lastError = V380Error.loginFailed(code)
                        continue
                    }
                }
                // Every password encoding was refused for this username; another username will not help.
                if case V380Error.wrongPassword = lastError { break versionLoop }
            }
            // On a bad-header or unroutable (e.g. 1002) reply, still try the other header version.
            switch lastError {
            case V380Error.badResponse, V380Error.loginFailed: continue
            default: break versionLoop
            }
        }
        throw lastError
    }

    private static let relayKey = "v380.relay"

    /// Logs in through a V380 cloud relay (the same path the phone uses off-LAN).
    /// On success `relayIP` is set so later sockets reuse it. `shouldStop` bails out between attempts.
    public func authenticateAnywhere(shouldStop: () -> Bool = { false }) throws {
        var lastError: Error = SocketError.connectFailed("no relay reachable")

        func attempt(_ ip: String) throws -> Bool {
            if shouldStop() { return false }
            relayIP = ip
            do {
                try authenticate()
                UserDefaults.standard.set(ip, forKey: Self.relayKey)
                log("[connect] using cloud relay \(ip)")
                return true
            } catch let e as V380Error where e.isCredentialError {
                throw e // wrong user/pass/device fails on every relay
            } catch {
                lastError = error
                return false
            }
        }

        // Try the relay that worked last time first (avoids a dispatch round-trip).
        let cached = UserDefaults.standard.string(forKey: Self.relayKey)
        if let cached, try attempt(cached) { return }
        // Then fresh relays from the dispatch server.
        if !shouldStop() {
            let relays = (try? CloudDispatch.relayIPs(deviceId: config.deviceId)) ?? []
            for ip in relays where ip != cached && !shouldStop() {
                if try attempt(ip) { return }
            }
        }
        throw lastError
    }

    private func authenticate(_ variant: LoginVariant) throws {
        let s = try TCPSocket(host: relayIP, port: config.port, timeout: 5)
        defer { s.close() }

        let username = variant.username == .deviceId ? String(config.deviceId) : config.username
        let pw = Self.encryptPassword(config.password, encoding: variant.password)
        var cmd = [UInt8](repeating: 0, count: 520)
        cmd.putU32(1167, at: 0)
        cmd[8] = variant.version
        cmd.putU32(1, at: 9)
        cmd.putU32(config.deviceId, at: 13)
        // Cloud relay: identify the target device by hostname/port so the relay can route to it.
        cmd.putU32(1022, at: 4)
        cmd.putASCII(cloudHostname, at: 17, max: 50)
        cmd.putU32(UInt32(config.port), at: 67)
        cmd.putASCII(username, at: 71, max: 32)
        cmd.replaceSubrange(103..<(103 + pw.count), with: pw)
        try s.write(cmd)

        var resp = try s.readSome(max: 512, timeout: 8)
        while resp.count < 256, (try? s.waitReadable(0.4)) == true {
            resp += try s.readSome(max: 512 - resp.count, timeout: 0.4)
        }
        // Only the command/result header is logged; later bytes can hold the session ticket.
        let name = "h\(variant.version) user=\(variant.username.rawValue) pw=\(variant.password.rawValue)"
        log("[auth] \(name): \(resp.count) bytes, header \(Array(resp.prefix(8)).hex)")
        guard resp.count >= 8 else { throw V380Error.badResponse("\(resp.count)-byte login reply") }
        guard resp.u32(0) == 1168 else {
            throw V380Error.badResponse("login rejected with code \(Int32(bitPattern: resp.u32(0)))")
        }
        switch resp.u32(4) {
        case 1001: guard resp.count >= 23 else { throw V380Error.badResponse("short login reply") }
        case 1011: throw V380Error.wrongUsername
        case 1012: throw V380Error.wrongPassword
        case 1018: throw V380Error.wrongDeviceId
        case let code: throw V380Error.loginFailed(code)
        }
        deviceVersion = resp[12]
        ticket = resp.u32(13)
        sessionId = resp.u32(17)
        if deviceVersion > 30 {
            mediaKey.putU32(ticket, at: 0)
            mediaKey.putU64(0x6181_2346_2c14_795c, at: 4)
            mediaKey.putU32(0x8280_0df0, at: 12)
        }
        log("[auth] ok \(name) deviceVersion=\(deviceVersion) deviceType=\(resp[21]) camType=\(resp[22])")
    }

    /// 16-byte random key followed by the password encrypted with the static key, then with the random key.
    static func encryptPassword(_ pw: String, encoding: PasswordEncoding) -> [UInt8] {
        let staticKey = Array("macrovideo+*#!^@".utf8)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        let randomKey = (0..<16).map { _ in alphabet.randomElement()! }
        let pwBytes = Array(pw.utf8)
        switch encoding {
        case .zeroPadded48:
            var block = [UInt8](repeating: 0, count: 48)
            let n = min(pwBytes.count, 48)
            block.replaceSubrange(0..<n, with: pwBytes.prefix(n))
            aesECB(CCOperation(kCCEncrypt), key: staticKey, data: &block, offset: 0, count: 48)
            aesECB(CCOperation(kCCEncrypt), key: randomKey, data: &block, offset: 0, count: 48)
            return randomKey + block
        case .pkcs7Twice:
            // Java "AES/ECB/PKCS5Padding" applied twice, as in the SDK.
            let once = aesECBEncryptPKCS7(pwBytes, key: staticKey)
            return randomKey + Array(aesECBEncryptPKCS7(once, key: randomKey).prefix(64))
        }
    }


    // MARK: - Live stream (cmd 301 -> 401, then 303)

    /// Opens the media socket and starts the live stream. Call `authenticate()` first.
    public func startLive() throws -> StreamInfo {
        let s = try TCPSocket(host: relayIP, port: config.port, timeout: 5)
        lock.lock(); socket = s; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { s.shutdown() }

        var cmd = [UInt8](repeating: 0, count: 256)
        cmd.putU32(301, at: 0)
        cmd.putU32(1022, at: 4)
        cmd.putASCII(cloudHostname, at: 8, max: 50)
        cmd.putU32(UInt32(config.port), at: 58)
        cmd.putU32(config.deviceId, at: 62)
        cmd.putU32(ticket, at: 66)
        cmd.putU32(sessionId, at: 70)
        cmd.putU32(config.hd ? 1 : 0, at: 74)
        cmd[78] = 20
        cmd.putU32(1, at: 79)
        try s.write(cmd)

        var resp = try s.readSome(max: 412, timeout: 8)
        // The reply can arrive split across TCP segments; collect the rest if it is still trickling in.
        while resp.count < 26, (try? s.waitReadable(0.3)) == true {
            resp += try s.readSome(max: 412 - resp.count, timeout: 0.3)
        }
        guard resp.count >= 8, resp.u32(0) == 401 else {
            throw V380Error.badResponse("stream login \(Array(resp.prefix(16)).hex)")
        }
        let result = Int32(bitPattern: resp.u32(4))
        if result == -11 || result == -12 { throw V380Error.streamRefused(result) }

        // The actual frame size is re-derived from the H.26x stream, so defaults are fine here.
        let info = StreamInfo(width: 1280, height: 720, deviceVersion: deviceVersion, communicationVersion: 0)
        log("[stream] cloud login ok")
        var start = [UInt8](repeating: 0, count: 256)
        start.putU32(303, at: 0)
        start.putU16(0x3001, at: 4)
        try s.write(start)
        return info
    }

    /// Blocks, delivering frames until cancelled or the connection fails.
    public func receiveFrames(_ onFrame: (MediaFrame) -> Void) throws {
        guard let s = socket else { throw SocketError.closed }
        let decrypt = deviceVersion > 30
        var header = [UInt8](repeating: 0, count: 12)
        var chunk = [UInt8](repeating: 0, count: 65536)
        var video: [UInt8] = [], videoTotal: UInt16 = 0
        var audio: [UInt8] = [], audioTotal: UInt16 = 0
        var nextAudioFragment = -1
        video.reserveCapacity(512_000)

        while !isCancelled {
            try s.readExact(into: &header, count: 1, timeout: 10)
            guard header[0] == 0x7F else { continue } // resync byte by byte
            try s.readExact(into: &header, offset: 1, count: 11, timeout: 10)

            let type = header[1]
            let total = header.u16(3), cur = header.u16(5), len = Int(header.u16(7))
            guard len > 0, len <= 20000, total > 0, cur < total else { continue }
            try s.readExact(into: &chunk, count: len, timeout: 10)

            switch type {
            case 0x00, 0x01, 0x28, 0x29:
                if cur == 0 || total != videoTotal { video.removeAll(keepingCapacity: true); videoTotal = total }
                video.append(contentsOf: chunk[0..<len])
                guard cur == total - 1 else { continue }
                defer { video.removeAll(keepingCapacity: true) }
                guard video.count > 16 else { continue }

                var payload = Array(video[16...])
                if decrypt {
                    if communicationVersion == 21 { decryptPre2k(&payload) } else { decryptVideo(&payload) }
                }
                guard let start = Self.findStartCode(payload) else {
                    log("[video] no start code, len=\(payload.count)"); continue
                }
                if start > 0 { payload.removeFirst(start) }
                onFrame(MediaFrame(kind: .video, isKeyFrame: type == 0x00 || type == 0x28,
                                   timestamp: video.u64(8), frameRate: video.u16(6), payload: payload))

            case 0x1A:
                if cur == 0 || total != audioTotal { audio.removeAll(keepingCapacity: true); audioTotal = total }
                audio.append(contentsOf: chunk[0..<len])
                guard cur == total - 1 else { continue }
                defer { audio.removeAll(keepingCapacity: true) }
                guard audio.count > 16 else { continue }
                var payload = Array(audio[16...])
                if decrypt {
                    if communicationVersion == 21 { decryptPre2k(&payload) }
                    else { aesECB(CCOperation(kCCDecrypt), key: mediaKey, data: &payload, offset: 0, count: payload.count / 16 * 16) }
                }
                onFrame(MediaFrame(kind: .audio, audioCodec: .alaw, isKeyFrame: false, timestamp: audio.u64(8),
                                   frameRate: audio.u16(6), payload: payload))

            case 0x16:
                // Older IMA ADPCM audio: fragments must arrive in order, and the frame has a 20-byte header.
                if cur == 0 { audio.removeAll(keepingCapacity: true); audioTotal = total; nextAudioFragment = 0 }
                guard total == audioTotal, cur == nextAudioFragment else {
                    audio.removeAll(keepingCapacity: true); nextAudioFragment = -1; continue
                }
                audio.append(contentsOf: chunk[0..<len])
                nextAudioFragment += 1
                guard cur == total - 1 else { continue }
                defer { audio.removeAll(keepingCapacity: true); nextAudioFragment = -1 }
                guard audio.count > 20 else { continue }
                // Live 0x16 audio is IMA ADPCM with a 20-byte header (may be encrypted on some firmware).
                onFrame(MediaFrame(kind: .audio, audioCodec: .imaADPCM, isKeyFrame: false, timestamp: audio.u64(8),
                                   frameRate: audio.u16(6), payload: Array(audio[20...])))

            case 0x5B:
                continue
            default:
                log("[frame] unknown type 0x\(String(type, radix: 16)) len=\(len)")
            }
        }
    }

    public func close() {
        lock.lock(); let s = socket; socket = nil; lock.unlock()
        s?.close()
    }

    // MARK: - Camera controls (16-byte packets on the live stream socket, as in V380Decoder)

    public enum Light { case on, off, auto }

    /// Turns the camera's white light on/off/auto. Only meaningful while the live stream is running.
    public func setLight(_ mode: Light) {
        let sub: UInt8 = mode == .on ? 0xe9 : (mode == .off ? 0xea : 0xeb) // 1001 on, 1002 off, 1003 auto
        sendControl([0xc4, 0, 0, 0, sub, 0x03, 0, 0, 0, 0x01, 0, 0, 0, 0, 0, 0])
    }

    public enum PTZ { case left, right, up, down }

    /// Starts moving the camera in a direction. Send `ptzStop()` to stop (press-and-hold model).
    public func ptzMove(_ direction: PTZ) {
        // x/y are 1000 = centre, 1001 = left, 1002 = right, 1003 = up, 1004 = down.
        let x: UInt16 = direction == .left ? 1001 : (direction == .right ? 1002 : 1000)
        let y: UInt16 = direction == .up ? 1003 : (direction == .down ? 1004 : 1000)
        sendPTZ(x: x, y: y)
    }

    public func ptzStop() { sendPTZ(x: 1000, y: 1000) }

    private func sendPTZ(x: UInt16, y: UInt16) {
        var b = [UInt8](repeating: 0, count: 16)
        b[0] = 0xaa
        b.putU16(1000, at: 4)
        b.putU16(1000, at: 6)
        b.putU16(x, at: 8)
        b.putU16(y, at: 10)
        b[14] = 0x01
        sendControl(b)
    }

    private func sendControl(_ bytes: [UInt8]) {
        lock.lock(); let s = socket; lock.unlock()
        try? s?.write(bytes)
    }

    /// Decrypts recorded media (AES-ECB with the session key over whole 16-byte blocks) when the firmware encrypts it.
    func decryptMedia(_ payload: [UInt8]) -> [UInt8] {
        guard usesEncryptedMedia else { return payload }
        var d = payload
        aesECB(CCOperation(kCCDecrypt), key: mediaKey, data: &d, offset: 0, count: d.count / 16 * 16)
        return d
    }

    public var usesEncryptedMedia: Bool { deviceVersion > 30 }

    /// Only the first 64 bytes of every 80 are encrypted.
    func decryptVideo(_ d: inout [UInt8]) {
        var off = 0
        while off + 64 <= d.count {
            aesECB(CCOperation(kCCDecrypt), key: mediaKey, data: &d, offset: off, count: 64)
            off += 80
        }
    }

    private func decryptPre2k(_ d: inout [UInt8]) {
        aesECB(CCOperation(kCCDecrypt), key: mediaKey, data: &d, offset: 0, count: d.count / 16 * 16)
    }

    /// Index of an Annex-B start code (00 00 01 / 00 00 00 01) within the first 16 bytes.
    static func findStartCode(_ p: [UInt8]) -> Int? {
        guard p.count > 3 else { return nil }
        for i in 0..<min(16, p.count - 3) where p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
            return (i > 0 && p[i - 1] == 0) ? i - 1 : i
        }
        return nil
    }
}

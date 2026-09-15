import Foundation
import V380

// Usage: v380probe <deviceId> <password> [seconds=10] [out=probe.h26x] [--sd]
let args = CommandLine.arguments
guard args.count >= 3, let deviceId = UInt32(args[1]) else {
    FileHandle.standardError.write("usage: v380probe <deviceId> <password> [seconds] [outfile] [--sd]\n".data(using: .utf8)!)
    exit(2)
}
let seconds = args.count > 3 ? Double(args[3]) ?? 10 : 10
let outPath = args.count > 4 && !args[4].hasPrefix("--") ? args[4] : "probe.h26x"
let config = CameraConfig(deviceId: deviceId, password: args[2], hd: !args.contains("--sd"))

let session = V380Session(config: config)
session.log = { print($0) }

FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)!
var videoFrames = 0, keyFrames = 0, audioFrames = 0, bytes = 0
var audioSample: [UInt8] = []
let started = Date()

DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 12) { session.cancel() }

do {
    let t0 = Date()
    try session.authenticateAnywhere()
    print(String(format: "[time] auth %.2fs via relay %@", Date().timeIntervalSince(t0), session.relayIP))
    let info = try session.startLive()
    print(String(format: "[time] stream ready %.2fs  %dx%d", Date().timeIntervalSince(t0), info.width, info.height))
    var firstFrameLogged = false
    try session.receiveFrames { frame in
        if frame.kind == .video {
            if !firstFrameLogged {
                firstFrameLogged = true
                print(String(format: "[time] first video frame %.2fs  head=%@", Date().timeIntervalSince(t0),
                             frame.payload.prefix(8).map { String(format: "%02x", $0) }.joined()))
            }
            videoFrames += 1; if frame.isKeyFrame { keyFrames += 1 }
            bytes += frame.payload.count
            out.write(Data(frame.payload))
        } else {
            audioFrames += 1
            if audioSample.isEmpty { audioSample = Array(frame.payload.prefix(24)); print("[audio] first len=\(frame.payload.count) head=\(audioSample.map { String(format: "%02x", $0) }.joined())") }
        }
        if Date().timeIntervalSince(started) > seconds + 3 { session.cancel() }
    }
} catch {
    if videoFrames == 0 { print("[error] \(error)") }
}
session.close()
try? out.close()
print("[done] video=\(videoFrames) key=\(keyFrames) audio=\(audioFrames) bytes=\(bytes) -> \(outPath)")

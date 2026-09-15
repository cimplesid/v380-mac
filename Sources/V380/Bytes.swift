import CommonCrypto
import Foundation

extension Array where Element == UInt8 {
    mutating func putU32(_ v: UInt32, at o: Int) {
        self[o] = UInt8(truncatingIfNeeded: v); self[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
        self[o + 2] = UInt8(truncatingIfNeeded: v >> 16); self[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }
    mutating func putU16(_ v: UInt16, at o: Int) {
        self[o] = UInt8(truncatingIfNeeded: v); self[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    mutating func putU64(_ v: UInt64, at o: Int) {
        for i in 0..<8 { self[o + i] = UInt8(truncatingIfNeeded: v >> (UInt64(i) * 8)) }
    }
    mutating func putASCII(_ s: String, at o: Int, max: Int) {
        let b = Array(s.utf8.prefix(max))
        replaceSubrange(o..<(o + b.count), with: b)
    }
    func u32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func u16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    func u64(_ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[o + i]) << (UInt64(i) * 8) }
        return v
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// AES-128-ECB with PKCS#7 padding (Java's "AES/ECB/PKCS5Padding").
func aesECBEncryptPKCS7(_ input: [UInt8], key: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: input.count + 16)
    var moved = 0
    _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                key, key.count, nil, input, input.count, &out, out.count, &moved)
    return Array(out.prefix(moved))
}

/// AES-128-ECB (no padding) over `count` bytes at `offset`, written back in place; `count` must be a multiple of 16.
func aesECB(_ op: CCOperation, key: [UInt8], data: inout [UInt8], offset: Int, count: Int) {
    guard count > 0 else { return }
    var out = [UInt8](repeating: 0, count: count)
    var moved = 0
    data.withUnsafeBytes { src in
        _ = CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    key, key.count, nil, src.baseAddress! + offset, count, &out, count, &moved)
    }
    data.replaceSubrange(offset..<(offset + count), with: out)
}

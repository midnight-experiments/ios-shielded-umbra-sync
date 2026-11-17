// Byte helpers shared by the client: hex, little-endian reads and writes, SHA-256, random bytes, timing.

import CryptoKit
import Foundation
import Security

enum ClientError: Error, CustomStringConvertible {
    case invalid(String)
    case http(Int, String)
    case snapshotReplaced(String)

    var description: String {
        switch self {
        case .invalid(let s): return s
        case .http(let status, let s): return "HTTP \(status): \(s)"
        case .snapshotReplaced(let s): return "the server replaced the snapshot: \(s)"
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String, length: Int? = nil) throws {
        let t = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "0x", with: "")
        guard t.count % 2 == 0 else { throw ClientError.invalid("odd-length hex") }
        var out = Data(capacity: t.count / 2)
        var it = t.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { throw ClientError.invalid("not hex: \(t.prefix(20))…") }
            out.append(v)
        }
        if let length, out.count != length { throw ClientError.invalid("expected \(length) bytes of hex, got \(out.count)") }
        self = out
    }

    func u16(_ at: Int) -> UInt16 { UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[startIndex + at + i]) << (8 * UInt32(i)) }
        return v
    }
    func u64(_ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[startIndex + at + i]) << (8 * UInt64(i)) }
        return v
    }
    /// A copy with its own indices starting at 0.
    func sub(_ at: Int, _ count: Int) -> Data { Data(self[(startIndex + at)..<(startIndex + at + count)]) }

    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    var sha256: Data { Data(SHA256.hash(data: self)) }
    var isAllZero: Bool { allSatisfy { $0 == 0 } }
}

enum Random {
    /// Bytes from the operating system's cryptographic source.
    static func bytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }

    /// Fills `out` with uniform 32-bit words.
    static func fill(_ out: UnsafeMutableBufferPointer<UInt32>) {
        guard out.count > 0 else { return }
        let ok = SecRandomCopyBytes(kSecRandomDefault, out.count * 4, out.baseAddress!)
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
    }

    /// A uniform integer in [0, bound).
    static func below(_ bound: Int) -> Int {
        precondition(bound > 0)
        var g = SystemRandomNumberGenerator()
        return Int.random(in: 0..<bound, using: &g)
    }
}

/// Milliseconds since an arbitrary start, monotonic.
@inline(__always) func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

func formatBytes(_ n: Int) -> String {
    if n >= 1 << 20 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
    if n >= 1 << 10 { return String(format: "%.1f KB", Double(n) / 1024) }
    return "\(n) B"
}

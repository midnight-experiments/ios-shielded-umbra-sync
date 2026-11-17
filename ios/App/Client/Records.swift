// Record layouts (the same as the TypeScript client's shared/records.ts).
//
// Read record, 98 bytes: the commitment's first 16 bytes, then ciphertext elements 1–5 shrunk to 82 bytes (element 1
// keeps 1 byte, 2 keeps 32, 3 keeps 1, 4 keeps 32, 5 keeps 16). The wallet rebuilds each short element from its own
// pad: m = (e − pad) mod 2^(8b), then e = pad + m in the field. Path record: k sibling hashes, zero when the block was
// not full. Tail output: flags (1), commitment (32), ciphertext (224).

import Foundation

enum Records {
    static let commitmentPrefixBytes = 16
    static let shrunk: [(element: Int, keep: Int)] = [(1, 1), (2, 32), (3, 1), (4, 32), (5, 16)]
    static let shrunkElementsBytes = shrunk.reduce(0) { $0 + $1.keep }
    static let readRecordBytes = commitmentPrefixBytes + shrunkElementsBytes
    static let ciphertextBytes = 224
    static let tailOutputBytes = 1 + 32 + ciphertextBytes

    struct ReadRecord {
        let commitmentPrefix: Data
        /// Elements 1–5 shrunk (82 bytes), or nil when the output has no ciphertext.
        let elements: Data?
    }

    static func decodeReadRecord(_ bytes: Data) throws -> ReadRecord {
        guard bytes.count == readRecordBytes else { throw ClientError.invalid("read record must be \(readRecordBytes) bytes") }
        let elements = bytes.sub(commitmentPrefixBytes, shrunkElementsBytes)
        return ReadRecord(commitmentPrefix: bytes.sub(0, commitmentPrefixBytes), elements: elements.isAllZero ? nil : elements)
    }

    /// Elements 1–5 in full (160 bytes) from their shrunk form and the six pads (6 × 32 bytes).
    static func rebuildElements(_ shrunkBytes: Data, pads: Data) -> Data {
        precondition(shrunkBytes.count == shrunkElementsBytes && pads.count == 192)
        var out = Data(count: 160)
        var at = 0
        for (element, keep) in shrunk {
            let low = shrunkBytes.sub(at, keep)
            at += keep
            let to = (element - 1) * 32
            if keep == 32 { out.replaceSubrange(to..<(to + 32), with: low); continue }
            let pad = U256(le: pads.sub(element * 32, 32))
            // m = (low − pad) mod 2^(8·keep), keep ∈ {1, 16}
            var m = U256.zero
            if keep == 1 {
                m.w[0] = UInt64((low[0] &- UInt8(truncatingIfNeeded: pad.w[0])))
            } else {
                let l = U256(le: low + Data(count: 16))
                let (d0, b0) = l.w[0].subtractingReportingOverflow(pad.w[0])
                let d1 = l.w[1] &- pad.w[1] &- (b0 ? 1 : 0)
                m.w[0] = d0; m.w[1] = d1
            }
            out.replaceSubrange(to..<(to + 32), with: pad.addMod(m).leBytes)
        }
        return out
    }

    /// A path record's k hashes, or nil when its block was not full at the snapshot.
    static func decodePathRecord(_ bytes: Data, pathSplit: Int) throws -> [Data]? {
        guard bytes.count == 32 * pathSplit else { throw ClientError.invalid("path record must be \(32 * pathSplit) bytes") }
        if bytes.isAllZero { return nil }
        return (0..<pathSplit).map { bytes.sub(32 * $0, 32) }
    }

    struct TailOutput { let commitment: Data; let ciphertext: Data? }

    static func decodeTailOutput(_ bytes: Data) throws -> TailOutput {
        guard bytes.count == tailOutputBytes else { throw ClientError.invalid("tail output must be \(tailOutputBytes) bytes") }
        let flags = bytes[bytes.startIndex]
        guard flags & ~1 == 0 else { throw ClientError.invalid("unknown tail-output flags \(flags)") }
        return TailOutput(commitment: bytes.sub(1, 32), ciphertext: flags & 1 == 1 ? bytes.sub(33, ciphertextBytes) : nil)
    }
}

/// An unsigned 256-bit value, four little-endian 64-bit words: just what rebuilding elements needs.
struct U256 {
    var w: [UInt64]
    static var zero: U256 { U256(w: [0, 0, 0, 0]) }
    /// The BLS12-381 scalar field's prime.
    static let fieldPrime = U256(w: [0xffffffff00000001, 0x53bda402fffe5bfe, 0x3339d80809a1d805, 0x73eda753299d7d48])

    init(w: [UInt64]) { self.w = w }
    init(le: Data) {
        precondition(le.count == 32)
        w = (0..<4).map { le.u64(8 * $0) }
    }

    var leBytes: Data {
        var d = Data(capacity: 32)
        for x in w { d.appendLE(x) }
        return d
    }

    static func >= (a: U256, b: U256) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where a.w[i] != b.w[i] { return a.w[i] > b.w[i] }
        return true
    }

    /// (self + other) mod p, for self below p and self + other below 2p.
    func addMod(_ other: U256) -> U256 {
        var r = U256.zero
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = w[i].addingReportingOverflow(other.w[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r.w[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        if carry == 0 && !(r >= U256.fieldPrime) { return r }
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, b1) = r.w[i].subtractingReportingOverflow(U256.fieldPrime.w[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            r.w[i] = d2
            borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
        }
        return r
    }
}

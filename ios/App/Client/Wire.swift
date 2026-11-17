// Binary wire formats of the module's API (shared/wire.ts, shared/constants.ts). Integers are little-endian.
//
// Query body: magic "PSSQ", format version (u16), snapshot id (32), vector count (u16), then count × C u32 values.
// Answer body: the same header with magic "PSSA", then count × R u32 values. Tail: 132-byte header, then the
// commitments, outputs, nullifiers and block-root sections.

import Foundation

enum Wire {
    static let formatVersion = 2
    static let callHeaderBytes = 40
    static let tailHeaderBytes = 132

    enum Route {
        static let prefix = "/pss/v1"
        static let manifest = "\(prefix)/manifest"
        static let blob = "\(prefix)/blob/"
        static let tail = "\(prefix)/tail"
        static func query(_ table: PirTable) -> String { "\(prefix)/query/\(table.rawValue)" }
    }

    private static func magic(_ s: String) -> UInt32 { s.utf8.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    static let queryMagic = magic("PSSQ")
    static let answerMagic = magic("PSSA")
    static let tailMagic = magic("PSST")

    /// A query call: `count` vectors of `cols` values, vector-major.
    static func encodeQuery(snapshotId: Data, count: Int, values: UnsafeBufferPointer<UInt32>) -> Data {
        precondition(snapshotId.count == 32)
        var out = Data(capacity: callHeaderBytes + values.count * 4)
        out.appendLE(queryMagic)
        out.appendLE(UInt16(formatVersion))
        out.append(snapshotId)
        out.appendLE(UInt16(count))
        out.append(UnsafeBufferPointer(start: UnsafeRawPointer(values.baseAddress!).assumingMemoryBound(to: UInt8.self), count: values.count * 4))
        return out
    }

    /// An answer's values (count × rows, vector-major), after checking its header against the call.
    static func decodeAnswer(_ bytes: Data, rows: Int, count: Int, snapshotId: Data) throws -> [UInt32] {
        guard bytes.count >= callHeaderBytes else { throw ClientError.invalid("answer shorter than its header") }
        guard bytes.u32(0) == answerMagic else { throw ClientError.invalid("not an answer body") }
        guard Int(bytes.u16(4)) == formatVersion else { throw ClientError.invalid("answer has format version \(bytes.u16(4))") }
        guard bytes.sub(6, 32) == snapshotId else { throw ClientError.invalid("the answer names another snapshot") }
        guard Int(bytes.u16(38)) == count else { throw ClientError.invalid("the answer carries \(bytes.u16(38)) vectors, not \(count)") }
        let expected = callHeaderBytes + count * rows * 4
        guard bytes.count == expected else { throw ClientError.invalid("answer must be \(expected) bytes, got \(bytes.count)") }
        var values = [UInt32](repeating: 0, count: count * rows)
        values.withUnsafeMutableBytes { dst in
            bytes.withUnsafeBytes { src in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[callHeaderBytes...])) }
        }
        return values
    }

    struct Tail {
        let snapshotId: Data
        let height: Int
        let blockHash: Data
        let firstFree: Int
        let root: Data
        let commitments: Data
        let outputs: Data
        let nullifiers: Data
        let blockRoots: Data
    }

    static func splitTail(_ bytes: Data) throws -> Tail {
        guard bytes.count >= tailHeaderBytes else { throw ClientError.invalid("tail shorter than its header") }
        guard bytes.u32(0) == tailMagic else { throw ClientError.invalid("not a tail") }
        guard Int(bytes.u16(4)) == formatVersion else { throw ClientError.invalid("tail has format version \(bytes.u16(4))") }
        let lengths = (0..<4).map { Int(bytes.u32(116 + 4 * $0)) }
        let entry = [32, Records.tailOutputBytes, Buckets.recordBytes, 32]
        for i in 0..<4 where lengths[i] % entry[i] != 0 { throw ClientError.invalid("tail section \(i) is not whole entries") }
        let total = tailHeaderBytes + lengths.reduce(0, +)
        guard bytes.count == total else { throw ClientError.invalid("tail must be \(total) bytes, got \(bytes.count)") }
        var off = tailHeaderBytes
        var parts: [Data] = []
        for l in lengths { parts.append(bytes.sub(off, l)); off += l }
        return Tail(snapshotId: bytes.sub(8, 32), height: Int(bytes.u32(40)), blockHash: bytes.sub(44, 32),
                    firstFree: Int(bytes.u64(76)), root: bytes.sub(84, 32),
                    commitments: parts[0], outputs: parts[1], nullifiers: parts[2], blockRoots: parts[3])
    }
}

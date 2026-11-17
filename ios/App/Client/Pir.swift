// SimplePIR on the client (pir/params.ts, encode.ts, gaussian.ts, query.ts, matrix.ts, grid.ts).
//
// - A query for column j: a fresh uniform secret s (n = 1,024 values) and a fresh Gaussian error e (C values):
//   q = A·s + e + Δ·unit(j) mod 2^32. A (C × n) is the AES-128-CTR keystream of the table's seed.
// - The server answers grid × q (R values). The client decodes x = answer − H·s, where H = grid·A is the table's setup
//   data: each cell is round(x / Δ) mod p, + p/2 to undo the centring; the cells reassemble into the column's records.

import CommonCrypto
import Foundation

enum PirTable: String { case read, path, nullifier }

enum Pir {
    static let logQ = 32
    static let n = 1024
    static let sigma = 6.4
    static let cellBits = 9
    static let plainModulus = 1 << cellBits
    static let halfPlain = UInt32(plainModulus >> 1)
    static let logDelta = UInt32(logQ - cellBits)
    static let delta: UInt32 = 1 << logDelta

    static func cellsPerRecord(_ recordBytes: Int) -> Int { (8 * recordBytes + cellBits - 1) / cellBits }

    static func noiseBoundHolds(cols: Int) -> Bool {
        8 * sigma * Double(halfPlain) * Double(cols).squareRoot() < Double(delta) / 2
    }

    static func positionOf(_ index: Int, perColumn: Int) -> (column: Int, slot: Int) { (index / perColumn, index % perColumn) }

    /// The distinct wanted columns cut into calls of `perCall`, each padded with uniformly random columns.
    static func paddedCalls(_ wanted: [Int], cols: Int, perCall: Int) -> [(real: [Int], columns: [Int])] {
        var seen = Set<Int>()
        let distinct = wanted.filter { seen.insert($0).inserted }
        var calls: [(real: [Int], columns: [Int])] = []
        var from = 0
        repeat {
            let real = Array(distinct[min(from, distinct.count)..<min(from + perCall, distinct.count)])
            var columns = real
            while columns.count < perCall { columns.append(Random.below(cols)) }
            calls.append((real, columns))
            from += perCall
        } while from < distinct.count
        return calls
    }

    /// Reassembles `recordBytes` bytes from cell values (9 bits each, least significant first).
    static func decodeRecord(_ values: UnsafeBufferPointer<UInt16>, start: Int, recordBytes: Int) -> Data {
        var out = Data(count: recordBytes)
        var acc: UInt32 = 0, nbits: UInt32 = 0, o = 0, g = start
        let mask = UInt32(plainModulus - 1)
        while o < recordBytes {
            acc |= (UInt32(values[g]) & mask) << nbits
            nbits += UInt32(cellBits)
            g += 1
            while nbits >= 8 && o < recordBytes {
                out[o] = UInt8(acc & 0xff)
                o += 1
                acc >>= 8
                nbits -= 8
            }
        }
        return out
    }

    /// The `perColumn` records of one decoded column, in slot order.
    static func columnRecords(_ table: PirTableRef, _ values: [UInt16]) -> [Data] {
        values.withUnsafeBufferPointer { v in
            (0..<table.perColumn).map { decodeRecord(v, start: $0 * table.cellsPerRecord, recordBytes: table.recordBytes) }
        }
    }

    // ── the error: a discrete Gaussian, σ = 6.4, by inversion of its cumulative table (pir/gaussian.ts) ──────────

    private static let tail = Int((12 * sigma).rounded(.up))
    private static let cdf: [Double] = {
        var w = [Double](repeating: 0, count: 2 * tail + 1)
        var total = 0.0
        for i in 0..<w.count {
            let x = Double(i - tail)
            w[i] = exp(-(x * x) / (2 * sigma * sigma))
            total += w[i]
        }
        var acc = 0.0
        var c = w.map { acc += $0 / total; return acc }
        c[c.count - 1] = 1
        return c
    }()

    /// Adds independent Gaussian samples to `out` (wrapping), 53 uniform bits per sample.
    static func addGaussian(_ out: UnsafeMutableBufferPointer<UInt32>) {
        var bits = [UInt32](repeating: 0, count: out.count * 2)
        bits.withUnsafeMutableBufferPointer { Random.fill($0) }
        for i in 0..<out.count {
            let u = (Double(bits[2 * i] >> 5) * 67_108_864 + Double(bits[2 * i + 1] >> 6)) / 9_007_199_254_740_992
            var lo = 0, hi = cdf.count - 1
            while lo < hi {
                let mid = (lo + hi) >> 1
                if cdf[mid] > u { hi = mid } else { lo = mid + 1 }
            }
            out[i] = out[i] &+ UInt32(bitPattern: Int32(lo - tail))
        }
    }

    // ── A, the public matrix (pir/matrix.ts) ─────────────────────────────────────────────────────────────────────

    /// The AES-128 key of A: SHA-256("umbradb-pss/A/v1" ‖ seed)[0..16].
    static func matrixKey(seed: Data) -> Data { (Data("umbradb-pss/A/v1".utf8) + seed).sha256.sub(0, 16) }

    /// Rows [first, first + count) of A, row-major, written to `out` (count × n words): the AES-128-CTR keystream
    /// from counter block first·n/4, read as little-endian words.
    static func matrixRows(seed: Data, first: Int, count: Int, out: UnsafeMutablePointer<UInt32>) throws {
        let key = matrixKey(seed: seed)
        var iv = Data(count: 16)
        var block = UInt64(first * n * 4 / 16).bigEndian
        withUnsafeBytes(of: &block) { iv.replaceSubrange(8..<16, with: $0) }
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        v.baseAddress, k.baseAddress, 16, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw ClientError.invalid("AES-CTR setup failed: \(status)") }
        defer { CCCryptorRelease(cryptor) }
        let bytes = count * n * 4
        let raw = UnsafeMutableRawPointer(out)
        memset(raw, 0, bytes)
        var moved = 0
        let st = CCCryptorUpdate(cryptor, raw, bytes, raw, bytes, &moved)
        guard st == kCCSuccess, moved == bytes else { throw ClientError.invalid("AES-CTR failed: \(st)") }
    }
}

/// A 32-bit matrix, rows × cols, row-major, in memory a Metal device can read without a copy when one is given.
final class Matrix32 {
    let rows: Int
    let cols: Int
    let storage: UnsafeMutablePointer<UInt32>
    let gpuBuffer: AnyObject?   // MTLBuffer, typed loosely so the client compiles without Metal
    private let owned: Bool

    init(rows: Int, cols: Int, allocate: (Int) -> (UnsafeMutableRawPointer, AnyObject?)?) {
        self.rows = rows
        self.cols = cols
        if let (p, b) = allocate(rows * cols * 4) {
            storage = p.bindMemory(to: UInt32.self, capacity: rows * cols)
            gpuBuffer = b
            owned = false
        } else {
            storage = UnsafeMutablePointer<UInt32>.allocate(capacity: max(1, rows * cols))
            gpuBuffer = nil
            owned = true
        }
    }

    deinit { if owned { storage.deallocate() } }

    var bytes: Int { rows * cols * 4 }
}

/// Computes out[v·rows + r] = Σ_k matrix[r·cols + k] · vectors[v·cols + k] mod 2^32 (vector-major output).
protocol Multiplier: AnyObject {
    var name: String { get }
    /// Storage for a matrix this multiplier will read (Metal: a shared buffer, so nothing is copied).
    func makeMatrix(rows: Int, cols: Int) -> Matrix32
    /// `rows` limits the product to the matrix's first rows (a partly filled chunk).
    func multiply(_ m: Matrix32, rows: Int, vectors: [UInt32], count: Int) throws -> (out: [UInt32], gpuMs: Double?)
}

/// The CPU multiply: rows split across the cores, each dot product in 16-wide SIMD (NEON), wrapping.
final class CpuMultiplier: Multiplier {
    let threads: Int
    init(threads: Int = ProcessInfo.processInfo.activeProcessorCount) { self.threads = max(1, threads) }
    var name: String { threads == 1 ? "CPU, one thread" : "CPU, \(threads) threads" }

    func makeMatrix(rows: Int, cols: Int) -> Matrix32 { Matrix32(rows: rows, cols: cols) { _ in nil } }

    func multiply(_ m: Matrix32, rows: Int, vectors: [UInt32], count: Int) throws -> (out: [UInt32], gpuMs: Double?) {
        let cols = m.cols
        precondition(vectors.count == count * cols && cols % 16 == 0)
        if count == 0 { return ([], nil) }
        var out = [UInt32](repeating: 0, count: count * rows)
        let chunks = min(threads * 4, max(1, rows))
        out.withUnsafeMutableBufferPointer { o in
            vectors.withUnsafeBufferPointer { vec in
                let op = o.baseAddress!, vp = vec.baseAddress!, mp = m.storage
                let run = { (chunk: Int) in
                    let r0 = rows * chunk / chunks, r1 = rows * (chunk + 1) / chunks
                    for r in r0..<r1 {
                        let row = UnsafeRawPointer(mp + r * cols)
                        for v in 0..<count {
                            let x = UnsafeRawPointer(vp + v * cols)
                            var acc = SIMD16<UInt32>(repeating: 0)
                            var k = 0
                            while k < cols {
                                let a = row.loadUnaligned(fromByteOffset: k * 4, as: SIMD16<UInt32>.self)
                                let b = x.loadUnaligned(fromByteOffset: k * 4, as: SIMD16<UInt32>.self)
                                acc &+= a &* b
                                k += 16
                            }
                            op[v * rows + r] = acc.wrappedSum()
                        }
                    }
                }
                if threads == 1 { for c in 0..<chunks { run(c) } } else { DispatchQueue.concurrentPerform(iterations: chunks, execute: run) }
            }
        }
        return (out, nil)
    }
}

extension SIMD16 where Scalar == UInt32 {
    func wrappedSum() -> UInt32 { indices.reduce(UInt32(0)) { $0 &+ self[$1] } }
}

/// One call's queries and the secrets kept to decode the answers.
struct QueryBatch {
    let columns: [Int]
    let secrets: [UInt32]   // count × n
    let queries: [UInt32]   // count × C
}

/// Where a call's client time went.
struct BuildTimes {
    var aesMs = 0.0
    var multiplyMs = 0.0
    var gpuMs: Double? = nil
    var errorMs = 0.0
}

extension Pir {
    /// Rows of A per chunk: A is expanded and multiplied chunk by chunk, so the client never holds all of it.
    static let aChunkRows = 4096

    /// One query per column, each with its own fresh secret and error.
    static func buildQueries(table: PirTableRef, columns: [Int], multiplier: Multiplier, times: inout BuildTimes) throws -> QueryBatch {
        let count = columns.count, cols = table.cols
        let seed = try Data(hex: table.seed, length: 32)
        var secrets = [UInt32](repeating: 0, count: count * n)
        secrets.withUnsafeMutableBufferPointer { Random.fill($0) }
        var queries = [UInt32](repeating: 0, count: count * cols)
        let chunkRows = min(aChunkRows, cols)
        let chunk = multiplier.makeMatrix(rows: chunkRows, cols: n)
        var c0 = 0
        while c0 < cols {
            let rows = min(chunkRows, cols - c0)
            var t = nowMs()
            try matrixRows(seed: seed, first: c0, count: rows, out: chunk.storage)
            times.aesMs += nowMs() - t
            t = nowMs()
            let (part, gpu) = try multiplier.multiply(chunk, rows: rows, vectors: secrets, count: count)
            times.multiplyMs += nowMs() - t
            if let gpu { times.gpuMs = (times.gpuMs ?? 0) + gpu }
            for v in 0..<count {
                queries.withUnsafeMutableBufferPointer { q in
                    part.withUnsafeBufferPointer { p in
                        (q.baseAddress! + v * cols + c0).update(from: p.baseAddress! + v * rows, count: rows)
                    }
                }
            }
            c0 += rows
        }
        let t = nowMs()
        queries.withUnsafeMutableBufferPointer { addGaussian($0) }
        for (v, j) in columns.enumerated() { queries[v * cols + j] = queries[v * cols + j] &+ delta }
        times.errorMs += nowMs() - t
        return QueryBatch(columns: columns, secrets: secrets, queries: queries)
    }

    /// Decodes the answers of vectors `which` (indices into the batch): answer − H·s, rounded to cells.
    static func decodeAnswers(setup: Matrix32, batch: QueryBatch, answers: [UInt32], which: [Int], multiplier: Multiplier) throws -> (values: [[UInt16]], gpuMs: Double?, multiplyMs: Double) {
        let rows = setup.rows
        var sel = [UInt32](repeating: 0, count: which.count * n)
        for (i, v) in which.enumerated() { sel.replaceSubrange((i * n)..<((i + 1) * n), with: batch.secrets[(v * n)..<((v + 1) * n)]) }
        let t = nowMs()
        let (hs, gpu) = try multiplier.multiply(setup, rows: rows, vectors: sel, count: which.count)
        let multiplyMs = nowMs() - t
        let half = delta / 2
        let mask = UInt32(plainModulus - 1)
        var out: [[UInt16]] = []
        for (i, v) in which.enumerated() {
            var values = [UInt16](repeating: 0, count: rows)
            for r in 0..<rows {
                let x = answers[v * rows + r] &- hs[i * rows + r]
                values[r] = UInt16((((x &+ half) >> logDelta) &+ halfPlain) & mask)
            }
            out.append(values)
        }
        return (out, gpu, multiplyMs)
    }
}

/// The nullifier table's buckets (pir/buckets.ts): records of 40 bytes (nullifier, height u32, transaction u32).
enum Buckets {
    static let recordBytes = 40

    static func bucketOf(_ nullifier: Data, bits: Int) -> Int {
        let top = Int(nullifier[nullifier.startIndex]) << 16 | Int(nullifier[nullifier.startIndex + 1]) << 8 | Int(nullifier[nullifier.startIndex + 2])
        return top >> (24 - bits)
    }

    struct Entry { let nullifier: Data; let height: Int; let txIndex: Int }

    static func find(_ records: [Data], _ nullifier: Data) -> Entry? {
        for r in records where r.sub(0, 32) == nullifier {
            return Entry(nullifier: nullifier, height: Int(r.u32(32)), txIndex: Int(r.u32(36)))
        }
        return nil
    }

    static func decode(_ r: Data) -> Entry { Entry(nullifier: r.sub(0, 32), height: Int(r.u32(32)), txIndex: Int(r.u32(36))) }
}

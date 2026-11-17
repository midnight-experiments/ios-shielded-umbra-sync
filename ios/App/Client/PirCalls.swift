// PIR calls against one table (client/pir-calls.ts): every call carries exactly `queriesPerCall` vectors, the wanted
// columns then uniformly random ones; a wallet that needs nothing still sends one full call.

import Foundation

struct CallStats {
    var calls = 0
    var buildMs = 0.0
    var roundTripMs = 0.0
    var decodeMs = 0.0
    var bytesUp = 0
    var bytesDown = 0
    var build = BuildTimes()
    var decodeMultiplyMs = 0.0
    var decodeGpuMs: Double? = nil
    var decodedVectors = 0
    var plan: [(real: [Int], padding: Int)] = []
}

struct PirSession {
    let http: PssHttp
    let manifest: Manifest
    let snapshotId: Data
    let multiplier: Multiplier
    /// Decode the padding vectors' answers too, as the TypeScript client does (the server cannot see either way).
    var decodePadding = false

    /// The decoded column (cells) of each wanted column.
    func columns(_ table: PirTable, ref: PirTableRef, setup: Matrix32, wanted: [Int], stats: inout CallStats) async throws -> [Int: [UInt16]] {
        var out: [Int: [UInt16]] = [:]
        for call in Pir.paddedCalls(wanted, cols: ref.cols, perCall: manifest.queriesPerCall) {
            stats.plan.append((call.real, call.columns.count - call.real.count))
            var t = nowMs()
            let batch = try Pir.buildQueries(table: ref, columns: call.columns, multiplier: multiplier, times: &stats.build)
            let body = batch.queries.withUnsafeBufferPointer { Wire.encodeQuery(snapshotId: snapshotId, count: call.columns.count, values: $0) }
            stats.buildMs += nowMs() - t
            t = nowMs()
            let answer = try await http.query(table, body: body)
            stats.roundTripMs += nowMs() - t
            stats.bytesUp += body.count
            stats.bytesDown += answer.count
            t = nowMs()
            let values = try Wire.decodeAnswer(answer, rows: ref.rows, count: call.columns.count, snapshotId: snapshotId)
            let which = decodePadding ? Array(0..<call.columns.count) : Array(0..<call.real.count)
            let decoded = try Pir.decodeAnswers(setup: setup, batch: batch, answers: values, which: which, multiplier: multiplier)
            for (q, column) in call.real.enumerated() { out[column] = decoded.values[q] }
            stats.decodeMultiplyMs += decoded.multiplyMs
            if let g = decoded.gpuMs { stats.decodeGpuMs = (stats.decodeGpuMs ?? 0) + g }
            stats.decodedVectors += which.count
            stats.decodeMs += nowMs() - t
            stats.calls += 1
        }
        return out
    }

    /// Where tree position `position` sits in a positional table: its slot, column and place there.
    func cell(_ position: Int, ref: PirTableRef) throws -> (index: Int, column: Int, slot: Int) {
        let index = try manifest.slotOf(position)
        let (c, s) = Pir.positionOf(index, perColumn: ref.perColumn)
        return (index, c, s)
    }

    /// Records of tree positions in a positional table (the read table or the path table).
    func readPositions(_ table: PirTable, ref: PirTableRef, setup: Matrix32, positions: [Int], stats: inout CallStats) async throws -> [Int: Data] {
        let cells = try positions.map { try cell($0, ref: ref) }
        let cols = try await columns(table, ref: ref, setup: setup, wanted: cells.map(\.column), stats: &stats)
        var out: [Int: Data] = [:]
        for (i, p) in positions.enumerated() { out[p] = Pir.columnRecords(ref, cols[cells[i].column]!)[cells[i].slot] }
        return out
    }

    /// Nullifier lookups: the entry where present, else nil.
    func lookupNullifiers(_ nullifiers: [Data], setup: Matrix32, stats: inout CallStats) async throws -> [Data: Buckets.Entry?] {
        let ref = manifest.artifacts.nullifierTable
        let bits = ref.bucketBits ?? 0
        let cols = try await columns(.nullifier, ref: ref, setup: setup, wanted: nullifiers.map { Buckets.bucketOf($0, bits: bits) }, stats: &stats)
        var out: [Data: Buckets.Entry?] = [:]
        for n in nullifiers { out[n] = Buckets.find(Pir.columnRecords(ref, cols[Buckets.bucketOf(n, bits: bits)]!), n) }
        return out
    }
}

/// Setup data (R × n little-endian u32) into a matrix the multiplier reads.
func setupMatrix(_ bytes: Data, rows: Int, multiplier: Multiplier) throws -> Matrix32 {
    guard bytes.count == rows * Pir.n * 4 else { throw ClientError.invalid("setup data must be \(rows * Pir.n * 4) bytes, got \(bytes.count)") }
    let m = multiplier.makeMatrix(rows: rows, cols: Pir.n)
    bytes.withUnsafeBytes { UnsafeMutableRawPointer(m.storage).copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
    return m
}

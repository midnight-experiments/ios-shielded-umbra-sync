// The snapshot manifest (shared/manifest.ts, format 2): canonical JSON naming the snapshot's height, root and every
// artifact's digest, size and table shape. The snapshot identifier is the SHA-256 of its bytes.

import Foundation

struct ArtifactRef: Codable, Equatable {
    let digest: String
    let size: Int
}

struct BlockRootsRef: Codable, Equatable {
    let digest: String
    let size: Int
    let blocks: Int
}

/// A PIR table: the grid's shape and the seed of its public matrix A.
struct PirTableRef: Codable, Equatable {
    let digest: String
    let size: Int
    let rows: Int
    let cols: Int
    let perColumn: Int
    let cellsPerRecord: Int
    let recordBytes: Int
    let records: Int
    let seed: String
    // The nullifier table's own fields.
    let bucketBits: Int?
    let capacity: Int?
}

struct PirParams: Codable, Equatable {
    let logQ: Int
    let n: Int
    let sigma: Double
    let cellBits: Int
    let plainModulus: Int
}

struct Manifest: Codable, Equatable {
    struct Padding: Codable, Equatable { let size: Int }
    struct Artifacts: Codable, Equatable {
        let scan: ArtifactRef
        let blockRoots: BlockRootsRef
        let readTable: PirTableRef
        let readSetup: ArtifactRef
        let pathTable: PirTableRef?
        let pathSetup: ArtifactRef?
        let nullifierTable: PirTableRef
        let nullifierSetup: ArtifactRef
    }

    let formatVersion: Int
    let network: String
    let genesisHash: String
    let height: Int
    let blockHash: String
    let firstFree: Int
    let root: String
    let pathSplit: Int
    let queriesPerCall: Int
    let padding: Padding?
    let pir: PirParams
    let artifacts: Artifacts

    /// Slots of the scan file and the positional tables: the outputs, or the padded size (debug snapshots).
    var slotCount: Int { padding?.size ?? firstFree }

    static func decode(_ bytes: Data) throws -> Manifest {
        let m = try JSONDecoder().decode(Manifest.self, from: bytes)
        try m.validate()
        return m
    }

    /// The checks of `validateManifest` that the client relies on.
    func validate() throws {
        func need(_ ok: Bool, _ what: String) throws { if !ok { throw ClientError.invalid("invalid manifest: \(what)") } }
        try need(formatVersion == Wire.formatVersion, "formatVersion \(formatVersion) (this app speaks \(Wire.formatVersion))")
        try need(pir.logQ == Pir.logQ && pir.n == Pir.n && pir.cellBits == Pir.cellBits && pir.plainModulus == Pir.plainModulus,
                 "PIR parameters \(pir) differ from the app's")
        try need(pir.sigma == Pir.sigma, "σ \(pir.sigma)")
        try need(queriesPerCall >= 1 && queriesPerCall <= 0xffff, "queriesPerCall")
        let a = artifacts
        try need(a.scan.size == 36 * slotCount, "scan.size = 36 × slots")
        try need(a.blockRoots.size == 32 * a.blockRoots.blocks, "blockRoots.blocks")
        for (name, t) in [("readTable", a.readTable), ("nullifierTable", a.nullifierTable)] + (a.pathTable.map { [("pathTable", $0)] } ?? []) {
            try need(t.rows == t.perColumn * t.cellsPerRecord, "\(name).rows = perColumn × cellsPerRecord")
            try need(t.cellsPerRecord == Pir.cellsPerRecord(t.recordBytes), "\(name).cellsPerRecord")
            try need(t.size == 32 + t.rows * t.cols * 2, "\(name).size matches its shape")
            try need(Pir.noiseBoundHolds(cols: t.cols), "\(name) fails the noise check")
        }
        try need(a.readTable.recordBytes == Records.readRecordBytes, "readTable.recordBytes = 98")
        try need(a.readTable.records == slotCount, "readTable.records = slots")
        try need(a.readSetup.size == a.readTable.rows * pir.n * 4, "readSetup.size")
        try need(a.nullifierSetup.size == a.nullifierTable.rows * pir.n * 4, "nullifierSetup.size")
        try need(a.nullifierTable.recordBytes == Buckets.recordBytes, "nullifier records are 40 bytes")
        if pathSplit == 0 {
            try need(a.pathTable == nil && a.pathSetup == nil, "no path table when pathSplit is 0")
        } else {
            guard let p = a.pathTable, let s = a.pathSetup else { throw ClientError.invalid("invalid manifest: pathTable missing") }
            try need(p.recordBytes == 32 * pathSplit, "pathTable.recordBytes = 32 × pathSplit")
            try need(s.size == p.rows * pir.n * 4, "pathSetup.size")
        }
    }

    // ── slots of a padded snapshot (shared/padding.ts) ────────────────────────────────────────────────────────────

    /// The slot of tree position `position`.
    func slotOf(_ position: Int) throws -> Int {
        guard position >= 0 && position < firstFree else { throw ClientError.invalid("position \(position) is not in the snapshot (0 to \(firstFree - 1))") }
        guard let p = padding else { return position }
        return Int((Int64(position) * Int64(p.size)) / Int64(firstFree))
    }

    /// The tree position held at `slot`, or nil when the slot holds noise.
    func positionAtSlot(_ slot: Int) -> Int? {
        guard let p = padding else { return slot }
        let r = Int64(firstFree), n = Int64(p.size)
        let i = (Int64(slot) * r + n - 1) / n
        return i < r && (i * n) / r == Int64(slot) ? Int(i) : nil
    }
}

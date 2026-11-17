// The client's steps, one at a time, as the web step page runs them (web/worker.ts): keys, files, scan, read,
// nullifiers, paths, tail, summary; plus the device's limits and the GPU benchmarks this app exists to measure.
// Each step returns rows for the screen and the requests it made. The mnemonic and the keys stay in this process.

import Foundation
import Metal
import os

struct Row: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

struct StepResult {
    var ok = true
    var ms = 0.0
    var rows: [Row] = []
    var sections: [(title: String, rows: [Row])] = []
    var exchanges: [Exchange] = []
    var error: String? = nil

    mutating func add(_ k: String, _ v: String) { rows.append(Row(key: k, value: v)) }
    mutating func section(_ title: String, _ r: [Row]) { sections.append((title, r)) }
}

struct Coin: Identifiable {
    var id: Int { position }
    let position: Int
    let tokenType: Data
    let value: UInt128Compat
    let nonce: Data
    let commitment: Data
    let nullifier: Data
    var source: String
    var spent: String? = nil
    var spentHeight: Int? = nil
    var lowerPath: [Data]? = nil
}

enum Engine: String, CaseIterable, Identifiable {
    case gpu = "Metal GPU"
    case cpu = "CPU, all cores"
    case cpu1 = "CPU, one thread"
    var id: String { rawValue }
}

enum ScanEngine: String, CaseIterable, Identifiable {
    case gpu32 = "Metal, 32-bit limbs"
    case gpu13 = "Metal, WGSL port"
    case cpu = "CPU, all cores"
    case cpu1 = "CPU, one thread"
    var id: String { rawValue }
}

/// The Metal libraries, compiled from the app's bundled sources when the app starts.
struct MetalLibraries {
    let multiply: MTLLibrary?
    let scan13: MTLLibrary?
    let scan32: MTLLibrary?
    var compile: [Row] = []

    init(device: MTLDevice?) {
        var rows: [Row] = []
        func load(_ name: String) -> MTLLibrary? {
            guard let device, let url = Bundle.main.url(forResource: name, withExtension: "msl"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let t = nowMs()
            do {
                let lib = try device.makeLibrary(source: source, options: nil)
                rows.append(Row(key: "\(name).metal", value: String(format: "%@ of source compiled in %.0f ms", formatBytes(source.utf8.count), nowMs() - t)))
                return lib
            } catch {
                rows.append(Row(key: "\(name).metal", value: "FAILED to compile: \(error)"))
                return nil
            }
        }
        multiply = load("Multiply")
        scan13 = load("PssScan")
        scan32 = load("PssScanW32")
        compile = rows
    }
}

/// Everything the steps share. Steps run off the main thread, one at a time.
final class ClientState: @unchecked Sendable {
    var http: PssHttp
    var keys: WalletKeys? = nil
    var manifest: Manifest? = nil
    var snapshotId: Data? = nil
    var files: [String: Data] = [:]
    var readSetup: [String: Matrix32] = [:]       // by multiplier name
    var nullifierSetup: [String: Matrix32] = [:]
    var pathSetup: [String: Matrix32] = [:]
    var pathSetupBytes: Data? = nil
    var matches: [Int] = []
    var coins: [Int: Coin] = [:]
    var commitments: [Int: Data] = [:]
    /// The chain height the last tail reached.
    var tailHeight: Int? = nil

    let device: MTLDevice?
    lazy var libraries = MetalLibraries(device: device)
    lazy var metalMultiplier: MetalMultiplier? = {
        guard let device, let lib = libraries.multiply else { return nil }
        return try? MetalMultiplier(device: device, library: lib)
    }()
    lazy var metalScanner: MetalScanner? = {
        guard let device, let lib = libraries.scan32 else { return nil }
        return try? MetalScanner(device: device, library: lib, options: .init(field: .limbs32))
    }()
    lazy var metalScanner13: MetalScanner? = {
        guard let device, let lib = libraries.scan13 else { return nil }
        return try? MetalScanner(device: device, library: lib, options: .init(field: .limbs13))
    }()
    let cpuMultiplier = CpuMultiplier()
    let cpuMultiplier1 = CpuMultiplier(threads: 1)

    init(server: URL) {
        http = PssHttp(origin: server)
        device = MTLCreateSystemDefaultDevice()
    }

    func multiplier(_ e: Engine) throws -> Multiplier {
        switch e {
        case .gpu:
            guard let m = metalMultiplier else { throw ClientError.invalid("no Metal device or library") }
            return m
        case .cpu: return cpuMultiplier
        case .cpu1: return cpuMultiplier1
        }
    }

    func need<T>(_ v: T?, _ step: String) throws -> T {
        guard let v else { throw ClientError.invalid("run “\(step)” first") }
        return v
    }

    func setup(_ table: PirTable, for m: Multiplier) throws -> Matrix32 {
        let man = try need(manifest, "Get the files")
        switch table {
        case .read:
            if let s = readSetup[m.name] { return s }
            let s = try setupMatrix(files[man.artifacts.readSetup.digest]!, rows: man.artifacts.readTable.rows, multiplier: m)
            readSetup[m.name] = s
            return s
        case .nullifier:
            if let s = nullifierSetup[m.name] { return s }
            let s = try setupMatrix(files[man.artifacts.nullifierSetup.digest]!, rows: man.artifacts.nullifierTable.rows, multiplier: m)
            nullifierSetup[m.name] = s
            return s
        case .path:
            if let s = pathSetup[m.name] { return s }
            guard let bytes = pathSetupBytes, let pt = man.artifacts.pathTable else { throw ClientError.invalid("no path setup data") }
            let s = try setupMatrix(bytes, rows: pt.rows, multiplier: m)
            pathSetup[m.name] = s
            return s
        }
    }

    func resetSnapshot() {
        files = [:]; readSetup = [:]; nullifierSetup = [:]; pathSetup = [:]; pathSetupBytes = nil
        matches = []; coins = [:]; commitments = [:]; tailHeight = nil
    }
}

enum Steps {
    static func short(_ d: Data) -> String { d.count <= 8 ? d.hex : "\(d.prefix(6).hex)…\(d.suffix(2).hex)" }

    // ── device ───────────────────────────────────────────────────────────────────────────────────────────────────

    static func device(_ s: ClientState) -> StepResult {
        var r = StepResult()
        let p = ProcessInfo.processInfo
        r.add("device", deviceModel())
        r.add("system", "\(p.operatingSystemVersionString)\(isSimulator ? " (Simulator)" : "")")
        r.add("CPU cores", "\(p.activeProcessorCount) active of \(p.processorCount)")
        r.add("memory", "\(formatBytes(Int(p.physicalMemory))) physical; \(formatBytes(availableMemory())) this app may still use (os_proc_available_memory)")
        r.add("thermal state", thermalName(p.thermalState))
        r.add("low power mode", p.isLowPowerModeEnabled ? "on" : "off")
        if let d = s.device {
            r.add("GPU", d.name)
            r.add("max buffer length", formatBytes(d.maxBufferLength))
            r.add("recommended working set", formatBytes(Int(d.recommendedMaxWorkingSetSize)))
            r.add("threadgroup memory", formatBytes(d.maxThreadgroupMemoryLength))
            r.add("max threads per threadgroup", "\(d.maxThreadsPerThreadgroup.width)")
            let fams: [(MTLGPUFamily, String)] = [(.apple6, "apple6"), (.apple7, "apple7"), (.apple8, "apple8"), (.apple9, "apple9"), (.metal3, "metal3")]
            r.add("GPU families", fams.filter { d.supportsFamily($0.0) }.map(\.1).joined(separator: ", "))
            r.add("unified memory", d.hasUnifiedMemory ? "yes" : "no")
            if let m = s.metalMultiplier { r.add("multiply pipeline", "SIMD width \(m.threadExecutionWidth), at most \(m.maxThreadsPerThreadgroup) threads per group") }
            for (name, sc) in [("scan, 32-bit limbs", s.metalScanner), ("scan, WGSL port", s.metalScanner13)] {
                if let sc {
                    r.add(name, "\(sc.stateWords * 4) B of GPU state per entry; \(formatBytes(sc.chunkBytes)) per chunk of \(sc.options.chunkEntries) entries; SIMD width \(sc.pipelines.first?.threadExecutionWidth ?? 0)")
                } else {
                    r.add(name, "not available")
                }
            }
            r.section("Metal libraries (compiled at start from source)", s.libraries.compile)
        } else {
            r.add("GPU", "no Metal device")
        }
        r.add("server", s.http.origin.absoluteString)
        return r
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func deviceModel() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "\(sim) (Simulator)" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func availableMemory() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        return Int(ProcessInfo.processInfo.physicalMemory)
        #endif
    }

    static func thermalName(_ t: ProcessInfo.ThermalState) -> String {
        switch t { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown" }
    }

    // ── keys ─────────────────────────────────────────────────────────────────────────────────────────────────────

    static func keys(_ s: ClientState, mnemonic: String, seedHex: String) throws -> StepResult {
        var r = StepResult()
        let t = nowMs()
        let m = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty {
            s.keys = try Core.keys(mnemonic: m)
            r.add("source", "mnemonic (\(m.split(whereSeparator: \.isWhitespace).count) words) → BIP-39 seed → BIP32 m/44'/2400'/0'/3/0 → Zswap keys")
        } else if !seedHex.trimmingCharacters(in: .whitespaces).isEmpty {
            s.keys = try Core.keys(zswapSeed: Data(hex: seedHex, length: 32))
            r.add("source", "32-byte Zswap seed")
        } else {
            throw ClientError.invalid("give a mnemonic or a Zswap seed")
        }
        let k = s.keys!
        s.coins = [:]; s.matches = []; s.commitments = [:]
        r.add("shielded address", Bech32m.shieldedAddress(k.coinPublicKey, k.encryptionPublicKey, network: s.manifest?.network ?? "preprod"))
        r.add("coin public key", k.coinPublicKey.hex)
        r.add("encryption public key", k.encryptionPublicKey.hex)
        r.add("check", Core.publicKey(secret: k.scanSecret) == k.encryptionPublicKey
              ? "the scan secret gives the encryption public key" : "FAILED: the scan secret does not give the encryption public key")
        r.add("scan secret, coin secret key", "held in this process, never shown or sent")
        r.ms = nowMs() - t
        return r
    }

    // ── files ────────────────────────────────────────────────────────────────────────────────────────────────────

    static func files(_ s: ClientState) async throws -> StepResult {
        var r = StepResult()
        let t = nowMs()
        let served = try await s.http.manifest()
        let id = served.bytes.sha256
        if let sid = served.servedId, sid != id.hex { throw ClientError.invalid("the manifest's SHA-256 is not the identifier the server names") }
        let m = try Manifest.decode(served.bytes)
        if s.snapshotId != id { s.resetSnapshot() }
        s.manifest = m
        s.snapshotId = id
        let a = m.artifacts
        var downloads: [Row] = []
        for (name, ref) in [("scan file", a.scan), ("block roots", ArtifactRef(digest: a.blockRoots.digest, size: a.blockRoots.size)),
                            ("read table setup", a.readSetup), ("nullifier table setup", a.nullifierSetup)] {
            let t1 = nowMs()
            if s.files[ref.digest] == nil { s.files[ref.digest] = try await s.http.blob(ref) }
            downloads.append(Row(key: name, value: "\(formatBytes(ref.size)) in \(Int(nowMs() - t1)) ms, SHA-256 equal to the manifest's"))
        }
        let rootOk = try Tree.rootOverBlocks(s.files[a.blockRoots.digest]!, k: m.pathSplit) == Data(hex: m.root, length: 32)
        if !rootOk { throw ClientError.invalid("the block roots do not give the manifest's root") }
        r.add("snapshot", "\(id.hex.prefix(16))… at height \(m.height) (\(m.network))")
        r.add("outputs (first_free)", "\(m.firstFree)\(m.padding.map { "; padded to \($0.size) slots (debug snapshot)" } ?? "")")
        r.add("read table", "\(a.readTable.rows) rows × \(a.readTable.cols) columns, \(a.readTable.perColumn) records of \(a.readTable.recordBytes) B per column")
        if let p = a.pathTable, let ps = a.pathSetup { r.add("path table", "\(p.rows) × \(p.cols), setup \(formatBytes(ps.size)) (downloaded only to spend)") }
        r.add("nullifier table", "\(a.nullifierTable.rows) × \(a.nullifierTable.cols), \(a.nullifierTable.bucketBits ?? 0) bucket bits, \(a.nullifierTable.capacity ?? 0) per bucket")
        r.add("PIR", "n = \(m.pir.n), q = 2^\(m.pir.logQ), p = \(m.pir.plainModulus), σ = \(m.pir.sigma), \(m.queriesPerCall) vectors per call")
        r.add("checks", "manifest SHA-256 = served id; every artifact's size and SHA-256; block roots give the root")
        r.add("memory left", formatBytes(availableMemory()))
        r.section("Downloads", downloads)
        r.ms = nowMs() - t
        return r
    }

    // ── scan ─────────────────────────────────────────────────────────────────────────────────────────────────────

    static func scan(_ s: ClientState, engine: ScanEngine, progress: @escaping (String) -> Void) throws -> StepResult {
        var r = StepResult()
        let k = try s.need(s.keys, "Keys")
        let m = try s.need(s.manifest, "Get the files")
        let file = s.files[m.artifacts.scan.digest]!
        let n = m.slotCount
        let t = nowMs()
        var found: [Int]
        switch engine {
        case .gpu32, .gpu13:
            guard let scanner = engine == .gpu32 ? s.metalScanner : s.metalScanner13 else { throw ClientError.invalid("the Metal scan kernels are not available") }
            let res = try scanner.scan(entries: file, secret: [UInt8](k.scanSecret))
            found = res.positions
            r.add("GPU time", res.timings.description)
        case .cpu, .cpu1:
            let threads = engine == .cpu1 ? 1 : ProcessInfo.processInfo.activeProcessorCount
            found = try Core.scanParallel(file, secret: k.scanSecret, threads: threads) { done in
                if done % 20000 < 300 { progress("scanned \(done) of \(n)") }
            }
        }
        let ms = nowMs() - t
        found.sort()
        let noise = found.filter { m.positionAtSlot($0) == nil }
        s.matches = found.compactMap { m.positionAtSlot($0) }
        r.add("engine", engine == .cpu || engine == .cpu1 ? engine.rawValue : "\(engine.rawValue) on \(s.device?.name ?? "?")")
        r.add("entries", "\(n) × 36 B = \(formatBytes(36 * n))")
        r.add("time", String(format: "%.1f ms, %.2f µs per entry", ms, n == 0 ? 0 : 1000 * ms / Double(n)))
        r.add("matches", s.matches.isEmpty ? "none" : s.matches.map(String.init).joined(separator: ", "))
        if !noise.isEmpty { r.add("noise slots matched", noise.map(String.init).joined(separator: ", ")) }
        r.add("note", "a match: the 4 tag bytes equal the wallet's pad (about 1 in 4 billion by chance) and the point is in the subgroup")
        r.ms = ms
        return r
    }

    // ── read ─────────────────────────────────────────────────────────────────────────────────────────────────────

    static func pirSession(_ s: ClientState, engine: Engine, decodePadding: Bool) throws -> PirSession {
        PirSession(http: s.http, manifest: try s.need(s.manifest, "Get the files"), snapshotId: s.snapshotId!,
                   multiplier: try s.multiplier(engine), decodePadding: decodePadding)
    }

    static func statsRows(_ st: CallStats, label: String) -> [Row] {
        var rows: [Row] = []
        for (i, c) in st.plan.enumerated() {
            rows.append(Row(key: "call \(i + 1)", value: "\(c.real.count + c.padding) vectors: real \(label) [\(c.real.map(String.init).joined(separator: ", "))], \(c.padding) random"))
        }
        rows.append(Row(key: "bytes", value: "\(formatBytes(st.bytesUp)) up, \(formatBytes(st.bytesDown)) down"))
        rows.append(Row(key: "build", value: String(format: "%.2f ms: A from its seed (AES-CTR) %.2f, A·s %.2f%@, error and Δ %.2f",
                                                    st.buildMs, st.build.aesMs, st.build.multiplyMs,
                                                    st.build.gpuMs.map { String(format: " (GPU %.2f)", $0) } ?? "", st.build.errorMs)))
        rows.append(Row(key: "round trip", value: String(format: "%.2f ms (upload, the server's multiplication, download)", st.roundTripMs)))
        rows.append(Row(key: "decode", value: String(format: "%.2f ms: H·s of %d vectors %.2f%@, then subtract and round",
                                                     st.decodeMs, st.decodedVectors, st.decodeMultiplyMs,
                                                     st.decodeGpuMs.map { String(format: " (GPU %.2f)", $0) } ?? "")))
        return rows
    }

    static func read(_ s: ClientState, positionsText: String, engine: Engine, decodePadding: Bool) async throws -> StepResult {
        var r = StepResult()
        let m = try s.need(s.manifest, "Get the files")
        let session = try pirSession(s, engine: engine, decodePadding: decodePadding)
        var positions = try parsePositions(positionsText)
        if positions.isEmpty { positions = s.matches }
        positions = Array(Set(positions)).sorted()
        let ref = m.artifacts.readTable
        let setup = try s.setup(.read, for: session.multiplier)
        var st = CallStats()
        let t = nowMs()
        let records = try await session.readPositions(.read, ref: ref, setup: setup, positions: positions, stats: &st)
        let callMs = nowMs() - t
        let file = s.files[m.artifacts.scan.digest]!
        r.add("positions", positions.isEmpty ? "none (one call is still sent)" : positions.map(String.init).joined(separator: ", "))
        r.rows += statsRows(st, label: "columns")
        for p in positions {
            let rec = try Records.decodeReadRecord(records[p]!)
            let cell = try session.cell(p, ref: ref)
            var rows = [Row(key: "table cell", value: "column \(cell.column), slot \(cell.slot)\(m.padding == nil ? "" : ", table index \(cell.index)")"),
                        Row(key: "commitment (first 16 B)", value: rec.commitmentPrefix.hex),
                        Row(key: "elements 1–5 (82 B)", value: rec.elements.map(short) ?? "none (no ciphertext)")]
            if let k = s.keys {
                let entry = file.sub(36 * cell.index, 36)
                switch checkMatch(k, entry: entry, record: rec) {
                case .failure(let why): rows.append(Row(key: "ownership", value: "not the wallet's: \(why)"))
                case .success(let (coin, commitment)):
                    let nf = Core.nullifier(coin: coin, coinSecretKey: k.coinSecretKey)
                    s.coins[p] = Coin(position: p, tokenType: coin.tokenType, value: coin.value, nonce: coin.nonce, commitment: commitment, nullifier: nf, source: "snapshot")
                    s.commitments[p] = commitment
                    rows.append(Row(key: "ownership", value: "the wallet's: elements rebuilt from its pads, decrypted, commitment starts with the record's 16 bytes"))
                    rows.append(Row(key: "coin", value: "\(coin.value) of token \(short(coin.tokenType))"))
                    rows.append(Row(key: "nullifier", value: nf.hex))
                }
            }
            r.section("Position \(p)", rows)
        }
        r.ms = callMs
        return r
    }

    /// The ownership check of one scan match (client/sync.ts checkSnapshotMatch).
    static func checkMatch(_ k: WalletKeys, entry: Data, record: Records.ReadRecord) -> Result<(DecryptedCoin, Data), MatchError> {
        guard let elements = record.elements else { return .failure(.init("the record has no ciphertext")) }
        let point = entry.sub(0, 32)
        guard let pads = Core.pads(point: point, secret: k.scanSecret) else { return .failure(.init("the point is not one the ledger accepts")) }
        guard pads.sub(0, 4) == entry.sub(32, 4) else { return .failure(.init("the scan entry is not the wallet's")) }
        let ciphertext = point + pads.sub(0, 32) + Records.rebuildElements(elements, pads: pads)
        return checkCiphertext(k, ciphertext: ciphertext, expected: record.commitmentPrefix)
    }

    struct MatchError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    static func checkCiphertext(_ k: WalletKeys, ciphertext: Data, expected: Data) -> Result<(DecryptedCoin, Data), MatchError> {
        guard let coin = Core.decryptCoin(ciphertext: ciphertext, secret: k.scanSecret) else { return .failure(.init("the ciphertext does not decrypt to a coin")) }
        let commitment = Core.commitment(coin: coin, coinPublicKey: k.coinPublicKey)
        guard commitment.prefix(expected.count) == expected else { return .failure(.init("the decrypted coin's commitment differs from the record's")) }
        return .success((coin, commitment))
    }

    static func parsePositions(_ text: String) throws -> [Int] {
        var out: [Int] = []
        for part in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) where !part.isEmpty {
            let bits = part.split(separator: "-")
            if bits.count == 2, let a = Int(bits[0]), let b = Int(bits[1]), a <= b { out += Array(a...b) }
            else if let v = Int(part) { out.append(v) }
            else { throw ClientError.invalid("not a position: \(part)") }
        }
        return out
    }

    // ── nullifiers ───────────────────────────────────────────────────────────────────────────────────────────────

    static func nullifiers(_ s: ClientState, manual: String, engine: Engine, decodePadding: Bool) async throws -> StepResult {
        var r = StepResult()
        let m = try s.need(s.manifest, "Get the files")
        let session = try pirSession(s, engine: engine, decodePadding: decodePadding)
        let own = s.coins.values.filter { $0.source == "snapshot" }.sorted { $0.position < $1.position }.map(\.nullifier)
        let typed = try manual.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { try Data(hex: String($0), length: 32) }
        var seen = Set<Data>()
        let list = (own + typed).filter { seen.insert($0).inserted }
        let setup = try s.setup(.nullifier, for: session.multiplier)
        var st = CallStats()
        let t = nowMs()
        let found = try await session.lookupNullifiers(list, setup: setup, stats: &st)
        r.ms = nowMs() - t
        r.add("lookups", "\(list.count)\(list.isEmpty ? " (one call is still sent, so the server cannot tell a wallet with no coin)" : "")")
        r.rows += statsRows(st, label: "buckets")
        let bits = m.artifacts.nullifierTable.bucketBits ?? 0
        var rows: [Row] = []
        for n in list {
            let coin = s.coins.values.first { $0.nullifier == n }
            let e = found[n] ?? nil
            if let e, let c = coin {
                s.coins[c.position]?.spent = "spent at height \(e.height), transaction \(e.txIndex)"
                s.coins[c.position]?.spentHeight = Int(e.height)
            }
            rows.append(Row(key: "\(short(n)) (bucket \(Buckets.bucketOf(n, bits: bits)))",
                            value: "\(coin.map { "coin at \($0.position)" } ?? "entered by hand"): " + (e.map { "spent at height \($0.height), transaction \($0.txIndex)" } ?? "not in the snapshot's table (unspent at the snapshot)")))
        }
        r.section("Results", rows)
        return r
    }

    // ── paths (to spend) ─────────────────────────────────────────────────────────────────────────────────────────

    static func paths(_ s: ClientState, positionsText: String, engine: Engine, decodePadding: Bool) async throws -> StepResult {
        var r = StepResult()
        let m = try s.need(s.manifest, "Get the files")
        guard let ref = m.artifacts.pathTable, let setupRef = m.artifacts.pathSetup else { throw ClientError.invalid("this snapshot has no path table (path split 0)") }
        let session = try pirSession(s, engine: engine, decodePadding: decodePadding)
        let blockSize = 1 << m.pathSplit
        let fullBlocks = m.firstFree / blockSize
        var asked = try parsePositions(positionsText)
        if asked.isEmpty { asked = s.coins.values.filter { $0.source == "snapshot" }.map(\.position) }
        asked = Array(Set(asked)).sorted()
        guard !asked.isEmpty else { throw ClientError.invalid("no position: read the wallet's coins first, or enter positions") }
        let positions = asked.filter { $0 / blockSize < fullBlocks }
        let t = nowMs()
        if s.pathSetupBytes == nil {
            let t1 = nowMs()
            s.pathSetupBytes = try await s.http.blob(setupRef)
            r.add("path setup download", "\(formatBytes(setupRef.size)) in \(Int(nowMs() - t1)) ms (once per snapshot)")
        }
        let setup = try s.setup(.path, for: session.multiplier)
        var st = CallStats()
        let records = positions.isEmpty ? [:] : try await session.readPositions(.path, ref: ref, setup: setup, positions: positions, stats: &st)
        r.ms = nowMs() - t
        r.add("path table", "\(ref.rows) × \(ref.cols), \(ref.perColumn) records of \(ref.recordBytes) B per column")
        r.rows += statsRows(st, label: "columns")
        let blockRoots = s.files[m.artifacts.blockRoots.digest]!
        var rows: [Row] = []
        for p in positions {
            guard let lower = try Records.decodePathRecord(records[p]!, pathSplit: m.pathSplit) else {
                rows.append(Row(key: "\(p)", value: "FAILED: no path for a position in a full block")); continue
            }
            let block = p / blockSize
            if let c = s.commitments[p] {
                let ok = Tree.rootFromPath(Core.leaf(c), index: p % blockSize, siblings: lower) == blockRoots.sub(32 * block, 32)
                rows.append(Row(key: "\(p)", value: ok ? "\(lower.count) hashes; give block \(block)'s root from the coin's commitment" : "DOES NOT give block \(block)'s root"))
                s.coins[p]?.lowerPath = lower
            } else {
                rows.append(Row(key: "\(p)", value: "\(lower.count) hashes read; no commitment here to check them with (not the wallet's coin)"))
            }
        }
        for p in asked where p / blockSize >= fullBlocks { rows.append(Row(key: "\(p)", value: "not read: its block was not full at the snapshot; the tail gives its path")) }
        r.section("Paths", rows)
        return r
    }

    // ── tail ─────────────────────────────────────────────────────────────────────────────────────────────────────

    static func tail(_ s: ClientState) async throws -> StepResult {
        var r = StepResult()
        let m = try s.need(s.manifest, "Get the files")
        let t = nowMs()
        let bytes = try await s.http.tail()
        let fetchMs = nowMs() - t
        let t2 = nowMs()
        let tl = try Wire.splitTail(bytes)
        guard tl.snapshotId == s.snapshotId else { throw ClientError.invalid("the tail belongs to another snapshot: get the files again") }
        let blockSize = 1 << m.pathSplit
        let t0 = m.firstFree / blockSize * blockSize
        let roots = s.files[m.artifacts.blockRoots.digest]!.prefix(32 * (t0 / blockSize)) + tl.blockRoots
        let rootOk = try Tree.rootOverBlocks(Data(roots), k: m.pathSplit) == tl.root
        let outputs = tl.outputs.count / Records.tailOutputBytes
        let decoded = try (0..<outputs).map { try Records.decodeTailOutput(tl.outputs.sub($0 * Records.tailOutputBytes, Records.tailOutputBytes)) }
        var found: [Row] = []
        if let k = s.keys, outputs > 0 {
            var entries = Data(count: 36 * outputs)
            for (i, o) in decoded.enumerated() { if let c = o.ciphertext { entries.replaceSubrange((36 * i)..<(36 * i + 36), with: c.prefix(36)) } }
            let hits = try entries.withUnsafeBytes { try Core.scan($0, secret: k.scanSecret) }
            for i in hits {
                let o = decoded[i]
                guard case .success(let (coin, commitment)) = checkCiphertext(k, ciphertext: o.ciphertext!, expected: o.commitment) else { continue }
                let p = m.firstFree + i
                let nf = Core.nullifier(coin: coin, coinSecretKey: k.coinSecretKey)
                s.coins[p] = Coin(position: p, tokenType: coin.tokenType, value: coin.value, nonce: coin.nonce, commitment: commitment, nullifier: nf, source: "tail")
                found.append(Row(key: "\(p)", value: "\(coin.value) of token \(short(coin.tokenType))"))
            }
        }
        var spends = 0
        for off in stride(from: 0, to: tl.nullifiers.count, by: Buckets.recordBytes) {
            let e = Buckets.decode(tl.nullifiers.sub(off, Buckets.recordBytes))
            for (p, c) in s.coins where c.nullifier == e.nullifier && c.spent == nil {
                s.coins[p]?.spent = "spent at height \(e.height), transaction \(e.txIndex) (tail)"
                s.coins[p]?.spentHeight = Int(e.height)
                spends += 1
            }
        }
        s.tailHeight = tl.height
        r.add("tail", "height \(tl.height), first_free \(tl.firstFree), \(formatBytes(bytes.count)) in \(Int(fetchMs)) ms")
        r.add("outputs since the snapshot", "\(outputs)")
        r.add("nullifiers since the snapshot", "\(tl.nullifiers.count / Buckets.recordBytes) (\(spends) of the wallet's)")
        r.add("root check", rootOk ? "the snapshot's full blocks and the tail's block roots give the tail's root" : "FAILED: the roots do not give the tail's root")
        r.add("client time", String(format: "%.1f ms", nowMs() - t2))
        r.section("The wallet's coins in the tail", found.isEmpty ? [Row(key: "-", value: s.keys == nil ? "derive the keys to scan the tail" : "none")] : found)
        r.ms = nowMs() - t
        return r
    }

    // ── summary ──────────────────────────────────────────────────────────────────────────────────────────────────

    static func summary(_ s: ClientState) -> StepResult {
        var r = StepResult()
        var balance: [Data: UInt128Compat] = [:]
        for c in s.coins.values where c.spent == nil { balance[c.tokenType] = (balance[c.tokenType] ?? .zero) + c.value }
        r.add("coins", "\(s.coins.count) (\(s.coins.values.filter { $0.spent == nil }.count) unspent)")
        r.section("Unspent balance by token type", balance.sorted { $0.key.hex < $1.key.hex }.map { Row(key: short($0.key), value: $0.value.description) })
        r.section("Coins", s.coins.values.sorted { $0.position < $1.position }.map {
            Row(key: "\($0.position) (\($0.source))", value: "\($0.value) of \(short($0.tokenType)); \($0.spent ?? "unspent")\($0.lowerPath == nil ? "" : "; lower path read")")
        })
        return r
    }
}

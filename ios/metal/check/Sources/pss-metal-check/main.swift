// The Metal scan's check: MetalScanner's results byte-equal to the CPU kernel's on the same inputs.
//
//     node make-reference.ts --out DIR                     # inputs, the CPU kernel's outputs and timings
//     swift run -c release pss-metal-check --ref DIR [options]
//
// Options: --variant w13|w32 (generated/PssScan.metal or PssScanW32.metal), --metal FILE, --chunk N, --digits N
// (ladder digits per dispatch), --tg N (threads per threadgroup), --max-threads N (pipelines' register budget hint),
// --quick (the two reference sets only, no 1,000,000 / 2,000,000 runs), --out FILE (results JSON; default
// ../results/check-<date>-<variant>.json unless --quick). Exit code 1 if any check fails.
//
// Steps: compiles the .metal file at run time (and once more with a salt, for the uncached compile time); for the
// 16,384 test vectors and the 70,000-entry edge-case set, one warm-up call then three timed calls each of scanValues
// and scan, every output compared with the CPU's; the vectors' values and hits also with the ledger's (pads.bin,
// mine.bin); 1,000,000 entries (the 70,000 set repeated, best of three) and 2,000,000 (once), compared with the CPU's
// outputs repeated; negative controls (one tag bit changed in a hit loses exactly that hit; one point byte changed
// changes exactly that entry's value); refusals (secret length, non-canonical secret, partial entry, no entries).

import Foundation
import Metal
import PssMetal

// MARK: - Options

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let metalRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
let variant = option("--variant") ?? "w13"
guard variant == "w13" || variant == "w32" else { fatalError("--variant is w13 or w32") }
let metalPath = option("--metal") ?? metalRoot.appendingPathComponent(variant == "w32" ? "generated/PssScanW32.metal" : "generated/PssScan.metal").path
guard let refDir = option("--ref") else {
    print("usage: pss-metal-check --ref DIR [--variant w13|w32] [--chunk N] [--digits N] [--tg N] [--max-threads N] [--quick] [--out FILE]")
    exit(2)
}
let quick = args.contains("--quick")
var options = MetalScanner.Options(field: variant == "w32" ? .limbs32 : .limbs13)
if let v = option("--chunk") { options.chunkEntries = Int(v)! }
if let v = option("--digits") { options.digitsPerPass = Int(v)! }
if let v = option("--tg") { options.threadgroupWidth = Int(v)! }
if let v = option("--max-threads") { options.maxTotalThreadsPerThreadgroup = Int(v)! }
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd"
let outPath = option("--out") ?? (quick ? nil : metalRoot.appendingPathComponent("results/check-\(dateFormatter.string(from: Date()))-\(variant).json").path)

// MARK: - Reference

struct Manifest: Decodable {
    struct CPU: Decodable {
        let threads: Int
        let poolValuesMs: [Double]
        let poolScanMs: [Double]
        let singleThreadSample: Int
        let singleThreadMs: Double
    }
    struct Set: Decodable {
        let name: String
        let count: Int
        let entries, secret, values, hits: String
        let composition: [String: Int]
        let cpu: CPU
    }
    struct Million: Decodable {
        let entries: Int
        let threads: Int
        let poolValuesMs: Double
    }
    let node: String
    let cpus: Int
    let threads: Int
    let loadBefore: [Double]
    let loadAfter: [Double]?
    let sets: [Set]
    let pads: String
    let mine: String
    let million: Million?
}

let ref = URL(fileURLWithPath: refDir)
func load(_ name: String) -> Data {
    do { return try Data(contentsOf: ref.appendingPathComponent(name)) } catch { fatalError("cannot read \(name) in \(refDir): \(error)") }
}
let manifest = try JSONDecoder().decode(Manifest.self, from: load("manifest.json"))

// MARK: - Results

var checks: [[String: Any]] = []
func record(_ name: String, _ ok: Bool, _ detail: String) {
    checks.append(["name": name, "ok": ok, "detail": detail])
    print("\(ok ? "ok  " : "FAIL") \(name): \(detail)")
}

/// Equal, or how many bytes differ and where the first is.
func compare(_ a: Data, _ b: Data) -> (equal: Bool, differing: Int, first: Int) {
    if a.count != b.count { return (false, abs(a.count - b.count), min(a.count, b.count)) }
    var differing = 0
    var first = -1
    a.withUnsafeBytes { (x: UnsafeRawBufferPointer) in
        b.withUnsafeBytes { (y: UnsafeRawBufferPointer) in
            if memcmp(x.baseAddress!, y.baseAddress!, a.count) == 0 { return }
            for i in 0..<a.count where x[i] != y[i] {
                differing += 1
                if first < 0 { first = i }
            }
        }
    }
    return (differing == 0, differing, first)
}
func valuesDetail(_ c: (equal: Bool, differing: Int, first: Int), entries: Int) -> String {
    c.equal ? "\(entries) entries, \(entries * 32) bytes equal" : "\(c.differing) bytes differ, first at byte \(c.first) (entry \(c.first / 32))"
}
let ms = { (s: Double) in String(format: "%.1f ms", s * 1000) }
let us = { (s: Double, n: Int) in String(format: "%.2f", s * 1e6 / Double(n)) }

// MARK: - Device and library

func loadAverage() -> [Double] {
    var l = [0.0, 0.0, 0.0]
    return getloadavg(&l, 3) == 3 ? l : []
}
let loadBefore = loadAverage()
guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(2) }
let source = try String(contentsOfFile: metalPath, encoding: .utf8)
print("device \(device.name); maxBufferLength \(device.maxBufferLength); recommendedMaxWorkingSetSize \(device.recommendedMaxWorkingSetSize)")
print("library \(metalPath) (\(source.utf8.count) bytes); reference \(refDir) (node \(manifest.node), \(manifest.threads) CPU threads)")

func seconds(_ body: () throws -> Void) rethrows -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9
}
var library: MTLLibrary!
let compileSeconds = try seconds { library = try device.makeLibrary(source: source, options: nil) }
var scanner: MetalScanner!
let pipelineSeconds = try seconds { scanner = try MetalScanner(device: device, library: library, options: options) }
// The same source with a salt the compiler cannot fold away (a comparison with the parameters' unused word), so neither
// the source nor the functions are in Metal's caches: the time a first launch pays.
let salt = UInt32.random(in: 1..<UInt32.max)
let salted = source.replacingOccurrences(of: "if (idx >= params.n) { return; }", with: "if (idx >= params.n || params.pad == \(salt)u) { return; }")
var freshCompileSeconds = 0.0
var freshPipelineSeconds = 0.0
do {
    var lib: MTLLibrary!
    freshCompileSeconds = try seconds { lib = try device.makeLibrary(source: salted, options: nil) }
    freshPipelineSeconds = try seconds { _ = try MetalScanner(device: device, library: lib, options: options) }
}
print("compile: library \(ms(compileSeconds)), pipelines \(ms(pipelineSeconds)); uncached (salted): library \(ms(freshCompileSeconds)), pipelines \(ms(freshPipelineSeconds))")
print("layout: \(scanner.stateWords) state words per entry, \(scanner.fieldWords)-word field; chunk \(scanner.options.chunkEntries) entries (\(scanner.chunkBytes) bytes), \(scanner.options.digitsPerPass) digits per ladder dispatch, threadgroup \(scanner.options.threadgroupWidth)")
for p in scanner.pipelines {
    print("  pipeline \(p.name): maxTotalThreadsPerThreadgroup \(p.maxTotalThreadsPerThreadgroup), threadExecutionWidth \(p.threadExecutionWidth), static threadgroup memory \(p.staticThreadgroupMemoryLength)")
}

// MARK: - Runs

struct Runs {
    var values = Data()
    var hits: [Int] = []
    var firstWall = 0.0
    var valuesTimings: [ScanTimings] = []
    var scanTimings: [ScanTimings] = []
    var repeatsAgree = true
}
func run(entries: Data, secret: [UInt8], times: Int, warmUp: Bool) throws -> Runs {
    var r = Runs()
    if warmUp {
        r.firstWall = try seconds { r.values = try scanner.scanValues(entries: entries, secret: secret) }
    }
    for _ in 0..<times {
        let v = try scanner.scanValues(entries: entries, secret: secret)
        r.valuesTimings.append(scanner.lastTimings!)
        if !r.values.isEmpty && v != r.values { r.repeatsAgree = false }
        r.values = v
        let h = try scanner.scan(entries: entries, secret: secret)
        r.scanTimings.append(h.timings)
        if !r.hits.isEmpty && h.positions != r.hits { r.repeatsAgree = false }
        r.hits = h.positions
    }
    return r
}
func best(_ t: [ScanTimings]) -> ScanTimings { t.min { $0.wall < $1.wall }! }
func minGpu(_ t: [ScanTimings]) -> Double { t.map(\.gpu).min()! }

var timingRows: [[String: Any]] = []
func timingRow(_ name: String, _ n: Int, _ r: Runs, cpu: Manifest.CPU?, cpuMillionMs: Double? = nil) {
    let bv = best(r.valuesTimings)
    let bs = best(r.scanTimings)
    var row: [String: Any] = [
        "set": name, "entries": n, "runs": r.valuesTimings.count,
        "scanValues": ["bestWallMs": bv.wall * 1000, "minGpuMs": minGpu(r.valuesTimings) * 1000, "bestWallUsPerEntry": bv.wall * 1e6 / Double(n),
                       "minGpuUsPerEntry": minGpu(r.valuesTimings) * 1e6 / Double(n),
                       "phasesOfBestMs": ["decompress": bv.decompress * 1000, "ladder": bv.ladder * 1000, "finish": bv.finish * 1000],
                       "chunks": bv.chunks, "commandBuffers": bv.commandBuffers, "longestCommandBufferMs": bv.longestCommandBuffer * 1000,
                       "allWallMs": r.valuesTimings.map { $0.wall * 1000 }, "allGpuMs": r.valuesTimings.map { $0.gpu * 1000 }],
        "scan": ["bestWallMs": bs.wall * 1000, "minGpuMs": minGpu(r.scanTimings) * 1000, "torsionOfBestMs": bs.torsion * 1000, "hits": r.hits.count,
                 "allWallMs": r.scanTimings.map { $0.wall * 1000 }],
    ]
    if r.firstWall > 0 { row["firstCallWallMs"] = r.firstWall * 1000 }
    if let c = cpu {
        let poolBest = c.poolValuesMs.min()!
        row["cpu"] = ["threads": c.threads, "poolScanValuesBestMs": poolBest, "poolUsPerEntry": poolBest * 1000 / Double(n),
                      "poolScanBestMs": c.poolScanMs.min()!, "singleThreadUsPerEntry": c.singleThreadMs * 1000 / Double(c.singleThreadSample)]
        row["speedupOverPool"] = poolBest / 1000 / bv.wall
    }
    if let m = cpuMillionMs { row["cpu"] = ["threads": manifest.million!.threads, "poolScanValuesMs": m, "poolUsPerEntry": m * 1000 / Double(n)] }
    timingRows.append(row)
    print("  \(name) (\(n)): scanValues best \(ms(bv.wall)) wall (\(us(bv.wall, n)) µs/entry), GPU \(ms(minGpu(r.valuesTimings))) (\(us(minGpu(r.valuesTimings), n)) µs/entry); " +
          "scan best \(ms(bs.wall)), \(r.hits.count) hits; best scanValues: \(bv)")
}

let secretOf = { (name: String) in [UInt8](load(name)) }
var preprodEntries = Data()
var preprodValues = Data()
var preprodHits: [Int] = []
var preprodSecret: [UInt8] = []
var metalPreprodHits: [Int] = []

for set in manifest.sets {
    let entries = load(set.entries)
    let secret = secretOf(set.secret)
    let cpuValues = load(set.values)
    let cpuHits = try JSONDecoder().decode([Int].self, from: load(set.hits))
    let r = try run(entries: entries, secret: secret, times: 3, warmUp: true)
    record("\(set.name): repeat runs agree", r.repeatsAgree, "a warm-up and 3 timed calls of scanValues and of scan")
    let c = compare(r.values, cpuValues)
    record("\(set.name): Metal scanValues = CPU ScanPool.scanValues", c.equal, valuesDetail(c, entries: set.count))
    record("\(set.name): Metal scan = CPU ScanPool.scan", r.hits == cpuHits, "Metal \(r.hits.count) hits, CPU \(cpuHits.count) hits")
    if set.name == "vectors" {
        let pads = load(manifest.pads)
        let p = compare(r.values, pads)
        record("vectors: Metal values = the ledger's (pads.bin)", p.equal, valuesDetail(p, entries: set.count))
        let want = load(manifest.mine).enumerated().compactMap { $0.element != 0 ? $0.offset : nil }
        record("vectors: Metal hits = the ledger's (mine.bin)", r.hits == want, "\(r.hits.count) of \(want.count)")
    }
    if set.name == "preprod" {
        preprodEntries = entries
        preprodValues = cpuValues
        preprodHits = cpuHits
        preprodSecret = secret
        metalPreprodHits = r.hits
    }
    timingRow(set.name, set.count, r, cpu: set.cpu)
}

// MARK: - Large sets: the 70,000-entry set repeated, against the CPU's outputs repeated

func tiled(_ d: Data, _ unit: Int, _ n: Int) -> Data {
    var out = Data(capacity: n * unit)
    while out.count < n * unit { out.append(d.prefix(min(d.count, n * unit - out.count))) }
    return out
}
if !quick && !preprodEntries.isEmpty {
    let base = preprodEntries.count / MetalScanner.entryBytes
    for (n, times) in [(1_000_000, 3), (2_000_000, 1)] {
        let entries = tiled(preprodEntries, MetalScanner.entryBytes, n)
        let want = tiled(preprodValues, 32, n)
        var wantHits: [Int] = []
        for k in stride(from: 0, to: n, by: base) { wantHits += preprodHits.map { $0 + k }.filter { $0 < n } }
        let r = try run(entries: entries, secret: preprodSecret, times: times, warmUp: false)
        let c = compare(r.values, want)
        record("\(n) entries: Metal scanValues = CPU's (the 70,000 set repeated)", c.equal, valuesDetail(c, entries: n))
        record("\(n) entries: Metal scan = CPU's (repeated)", r.hits == wantHits, "Metal \(r.hits.count) hits, CPU \(wantHits.count) hits")
        if times > 1 { record("\(n) entries: repeat runs agree", r.repeatsAgree, "\(times) calls of scanValues and of scan") }
        timingRow("\(n / 1000)k", n, r, cpu: nil, cpuMillionMs: n == manifest.million?.entries ? manifest.million!.poolValuesMs : nil)
    }
}

// MARK: - Negative controls

if let hit = metalPreprodHits.first {
    var changed = preprodEntries
    changed[hit * 36 + 32] ^= 1
    let hits = try scanner.scan(entries: changed, secret: preprodSecret).positions
    let missing = preprodHits.filter { !hits.contains($0) }
    let extra = hits.filter { !preprodHits.contains($0) }
    record("negative control: one tag bit changed in a hit", missing == [hit] && extra.isEmpty,
           "Metal hits against the CPU's for the original: lost \(missing), gained \(extra) (changed \(hit))")
    var changed2 = preprodEntries
    changed2[hit * 36] ^= 1
    let values = try scanner.scanValues(entries: changed2, secret: preprodSecret)
    var differing: [Int] = []
    for i in 0..<(values.count / 32) where values[(i * 32)..<(i * 32 + 32)] != preprodValues[(i * 32)..<(i * 32 + 32)] { differing.append(i) }
    record("negative control: one point byte changed", differing == [hit], "entries whose value differs from the CPU's for the original: \(differing) (changed \(hit))")
} else {
    record("negative controls", false, "the preprod set has no hit")
}

// MARK: - Refusals, as the CPU kernel's

func refusal(_ name: String, _ expect: (MetalScannerError) -> Bool, _ body: () throws -> Void) {
    do {
        try body()
        record("refusal: \(name)", false, "accepted")
    } catch let e as MetalScannerError {
        record("refusal: \(name)", expect(e), "\(e)")
    } catch {
        record("refusal: \(name)", false, "\(error)")
    }
}
let someEntries = preprodEntries.prefix(36 * 4)
refusal("31-byte secret", { if case .secretLength(31) = $0 { return true }; return false }) { _ = try scanner.scan(entries: someEntries, secret: Array(preprodSecret.prefix(31))) }
let r: [UInt8] = { var b = [UInt8](repeating: 0, count: 32); let limbs: [UInt64] = [0xd097_0e5e_d6f7_2cb7, 0xa668_2093_ccc8_1082, 0x0667_3b01_0134_3b00, 0x0e7d_b4ea_6533_afa9]; for i in 0..<32 { b[i] = UInt8((limbs[i / 8] >> (8 * UInt64(i % 8))) & 0xff) }; return b }()
refusal("secret = r", { if case .secretNotCanonical = $0 { return true }; return false }) { _ = try scanner.scanValues(entries: someEntries, secret: r) }
refusal("secret = 2^256 − 1", { if case .secretNotCanonical = $0 { return true }; return false }) { _ = try scanner.scan(entries: someEntries, secret: [UInt8](repeating: 0xff, count: 32)) }
refusal("35-byte entries", { if case .entriesNotWhole(35) = $0 { return true }; return false }) { _ = try scanner.scan(entries: someEntries.prefix(35), secret: preprodSecret) }
do {
    let rMinusOne: [UInt8] = { var b = r; b[0] -= 1; return b }()
    let a = try scanner.scan(entries: Data(), secret: preprodSecret).positions
    let b = try scanner.scanValues(entries: Data(), secret: preprodSecret)
    let c = try scanner.scanValues(entries: someEntries, secret: rMinusOne)
    record("no entries; secret r − 1 accepted", a.isEmpty && b.isEmpty && c.count == 4 * 32, "scan [] and scanValues of 0 bytes; r − 1 gives \(c.count) bytes")
} catch {
    record("no entries; secret r − 1 accepted", false, "\(error)")
}

// MARK: - Summary

let ok = checks.allSatisfy { $0["ok"] as! Bool }
print("\nµs per entry (Metal: best wall of the calls, and the least GPU execution time; WebGPU: gpu/README.md, same M4 Max)")
print("set | Metal wall | Metal GPU | WebGPU wall | WebGPU GPU | CPU pool | CPU one thread")
let webgpu: [String: (Double, Double)] = ["vectors": (3.1, 2.3), "preprod": (2.8, 2.2)]
for row in timingRows {
    let name = row["set"] as! String
    let v = row["scanValues"] as! [String: Any]
    let cpu = row["cpu"] as? [String: Any]
    let w = webgpu[name].map { (String($0.0), String($0.1)) } ?? ("—", "—")
    print(String(format: "%@ (%d) | %.2f | %.2f | %@ | %@ | %@ | %@", name, row["entries"] as! Int, v["bestWallUsPerEntry"] as! Double, v["minGpuUsPerEntry"] as! Double,
                 w.0, w.1, cpu.map { String(format: "%.1f (%d threads)", $0["poolUsPerEntry"] as! Double, $0["threads"] as! Int) } ?? "—",
                 (cpu?["singleThreadUsPerEntry"] as? Double).map { String(format: "%.0f", $0) } ?? "—"))
}

if let outPath {
    let results: [String: Any] = [
        "date": ISO8601DateFormatter().string(from: Date()),
        "ok": ok,
        "variant": variant,
        "environment": [
            "device": device.name, "maxBufferLength": device.maxBufferLength, "recommendedMaxWorkingSetSize": device.recommendedMaxWorkingSetSize,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "loadAverageBefore": loadBefore, "loadAverageAfter": loadAverage(),
            "referenceLoadAverage": [manifest.loadBefore, manifest.loadAfter ?? []], "node": manifest.node, "cpuThreads": manifest.threads,
        ],
        "library": ["file": URL(fileURLWithPath: metalPath).lastPathComponent, "bytes": source.utf8.count, "compileMs": compileSeconds * 1000,
                    "pipelinesMs": pipelineSeconds * 1000, "uncachedCompileMs": freshCompileSeconds * 1000, "uncachedPipelinesMs": freshPipelineSeconds * 1000],
        "options": ["chunkEntries": options.chunkEntries, "digitsPerPass": options.digitsPerPass, "threadgroupWidth": options.threadgroupWidth,
                    "maxTotalThreadsPerThreadgroup": options.maxTotalThreadsPerThreadgroup, "stateWords": scanner.stateWords, "chunkBytes": scanner.chunkBytes],
        "pipelines": scanner.pipelines.map { ["name": $0.name, "maxTotalThreadsPerThreadgroup": $0.maxTotalThreadsPerThreadgroup, "threadExecutionWidth": $0.threadExecutionWidth] },
        "checks": checks,
        "scan": timingRows,
    ]
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: outPath))
    print("results: \(outPath)")
}
print("load average before \(loadBefore.map { String(format: "%.1f", $0) }), after \(loadAverage().map { String(format: "%.1f", $0) })")
print(ok ? "all \(checks.count) checks passed" : "\(checks.filter { !($0["ok"] as! Bool) }.count) of \(checks.count) checks FAILED")
exit(ok ? 0 : 1)

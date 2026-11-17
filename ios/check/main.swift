// Runs the app's PIR client code on macOS against a live server, with the CPU and the Metal multiplier, and compares
// every record with the TypeScript client's (read-reference.ts):
//   swift run -c release pss-client-check <server> <reference.json>
import Foundation
import Metal

let args = CommandLine.arguments
let server = URL(string: args.count > 1 ? args[1] : "http://127.0.0.1:10480")!
let refPath = args.count > 2 ? args[2] : "reference.json"
let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: refPath))) as! [String: Any]

let http = PssHttp(origin: server)
let served = try await http.manifest()
let m = try Manifest.decode(served.bytes)
let id = served.bytes.sha256
guard id.hex == reference["snapshotId"] as? String else { fatalError("the server's snapshot \(id.hex) is not the reference's") }
print("snapshot \(id.hex.prefix(16))… height \(m.height), \(m.firstFree) outputs; read table \(m.artifacts.readTable.rows) × \(m.artifacts.readTable.cols)")

let device = MTLCreateSystemDefaultDevice()!
let source = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Metal/Multiply.metal").path, encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
let multipliers: [Multiplier] = [CpuMultiplier(), CpuMultiplier(threads: 1), try MetalMultiplier(device: device, library: library)]

let a = m.artifacts
let readSetupBytes = try await http.blob(a.readSetup)
let nullSetupBytes = try await http.blob(a.nullifierSetup)
var pathSetupBytes: Data? = nil
if let ps = a.pathSetup { pathSetupBytes = try await http.blob(ps) }
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("  DIFFERENT: \(what)") } }

for mul in multipliers {
    for decodePadding in [false, true] {
        let s = PirSession(http: http, manifest: m, snapshotId: id, multiplier: mul, decodePadding: decodePadding)
        let readSetup = try setupMatrix(readSetupBytes, rows: a.readTable.rows, multiplier: mul)
        let refRead = reference["read"] as! [String: String]
        let positions = refRead.keys.compactMap(Int.init).sorted()
        var st = CallStats()
        let got = try await s.readPositions(.read, ref: a.readTable, setup: readSetup, positions: positions, stats: &st)
        for p in positions { check(got[p]?.hex == refRead[String(p)], "read record \(p)") }
        print(String(format: "%@, decode padding %@: read %d positions: build %.1f ms (AES %.1f, A·s %.1f%@, error %.1f), round trip %.1f ms, decode %.1f ms (H·s %.1f%@, %d vectors), %@ up, %@ down",
                     mul.name, decodePadding ? "yes" : "no ", positions.count, st.buildMs, st.build.aesMs, st.build.multiplyMs,
                     st.build.gpuMs.map { String(format: ", GPU %.2f", $0) } ?? "", st.build.errorMs, st.roundTripMs, st.decodeMs,
                     st.decodeMultiplyMs, st.decodeGpuMs.map { String(format: ", GPU %.2f", $0) } ?? "", st.decodedVectors,
                     formatBytes(st.bytesUp), formatBytes(st.bytesDown)))
        if let pt = a.pathTable, let pathSetupBytes, let refPaths = reference["paths"] as? [String: String], !refPaths.isEmpty {
            let pathSetup = try setupMatrix(pathSetupBytes, rows: pt.rows, multiplier: mul)
            var ps = CallStats()
            let pp = refPaths.keys.compactMap(Int.init).sorted()
            let gotPaths = try await s.readPositions(.path, ref: pt, setup: pathSetup, positions: pp, stats: &ps)
            for p in pp { check(gotPaths[p]?.hex == refPaths[String(p)], "path record \(p)") }
            print(String(format: "   path %d positions (%d × %d): build %.1f ms (AES %.1f, A·s %.1f), round trip %.1f ms, decode %.1f ms, %@ up",
                         pp.count, pt.rows, pt.cols, ps.buildMs, ps.build.aesMs, ps.build.multiplyMs, ps.roundTripMs, ps.decodeMs, formatBytes(ps.bytesUp)))
        }
        let nt = a.nullifierTable
        let nSetup = try setupMatrix(nullSetupBytes, rows: nt.rows, multiplier: mul)
        let refBuckets = reference["nullifierBuckets"] as! [String: [String]]
        var ns = CallStats()
        let buckets = refBuckets.keys.compactMap(Int.init).sorted()
        let cols = try await s.columns(.nullifier, ref: nt, setup: nSetup, wanted: buckets, stats: &ns)
        for b in buckets { check(Pir.columnRecords(nt, cols[b]!).map(\.hex) == refBuckets[String(b)]!, "nullifier bucket \(b)") }
        print(String(format: "   nullifier %d buckets: build %.1f ms, round trip %.1f ms, decode %.1f ms", buckets.count, ns.buildMs, ns.roundTripMs, ns.decodeMs))
    }
}
print(failures == 0 ? "ALL EQUAL to the TypeScript client" : "\(failures) DIFFERENCES")
exit(failures == 0 ? 0 : 1)

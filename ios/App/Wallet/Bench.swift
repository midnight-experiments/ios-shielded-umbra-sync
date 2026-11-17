// The GPU and CPU work of a sync at larger snapshot sizes, measured on this device: the scan of N entries, and the
// client's PIR multiplications (A·s to build a call, H·s to decode it) for the read table of N outputs. No server: the
// entries repeat the downloaded scan file (or random points if none) and the matrices are random, which costs the
// same as the real ones.

import Foundation

enum Bench {
    /// The read table's shape for `records` records of 98 bytes (pir/grid.ts positionalShape).
    static func readShape(_ records: Int) -> (rows: Int, cols: Int, perColumn: Int) {
        let e = Pir.cellsPerRecord(Records.readRecordBytes)
        let perColumn = max(1, Int((Double(records * e).squareRoot() / Double(e)).rounded()))
        let cols = max(1, (records + perColumn - 1) / perColumn)
        return (perColumn * e, cols, perColumn)
    }

    static func sizeLabel(_ n: Int) -> String { n >= 1_000_000 ? "\(n / 1_000_000)M" : "\(n / 1000)k" }

    /// The scan of `n` entries on the GPU (and, for small n, the CPU), repeating the real scan file.
    static func scan(_ s: ClientState, sizes: [Int], cpuToo: Bool, progress: @escaping (String) -> Void) throws -> StepResult {
        var r = StepResult()
        let secret = s.keys?.scanSecret ?? Data(repeating: 7, count: 32)
        let base: Data = {
            if let m = s.manifest, let f = s.files[m.artifacts.scan.digest] { return f }
            return Data(count: 36)
        }()
        r.add("entries from", s.manifest == nil ? "zeros (get the files first for real entries)" : "the downloaded scan file, repeated")
        r.add("secret", s.keys == nil ? "a fixed test scalar" : "the wallet's")
        for n in sizes {
            progress("scan of \(sizeLabel(n)) entries")
            let before = Steps.availableMemory()
            var entries = Data(capacity: 36 * n)
            while entries.count < 36 * n { entries.append(base.prefix(36 * n - entries.count)) }
            var rows: [Row] = [Row(key: "file", value: formatBytes(entries.count))]
            for (label, scanner) in [("Metal, 32-bit limbs", s.metalScanner), ("Metal, WGSL port", s.metalScanner13)] {
                guard let scanner else { rows.append(Row(key: label, value: "not available")); continue }
                do {
                    let t = nowMs()
                    let res = try scanner.scan(entries: entries, secret: [UInt8](secret))
                    let ms = nowMs() - t
                    rows.append(Row(key: label, value: String(format: "%.0f ms, %.2f µs per entry; %@", ms, 1000 * ms / Double(n), res.timings.description)))
                } catch {
                    rows.append(Row(key: label, value: "FAILED: \(error)"))
                }
            }
            if cpuToo {
                let threads = ProcessInfo.processInfo.activeProcessorCount
                let t = nowMs()
                _ = try Core.scanParallel(entries, secret: secret, threads: threads)
                let ms = nowMs() - t
                rows.append(Row(key: "CPU, \(threads) threads", value: String(format: "%.0f ms, %.2f µs per entry", ms, 1000 * ms / Double(n))))
            }
            rows.append(Row(key: "memory left", value: "\(formatBytes(Steps.availableMemory())) (was \(formatBytes(before)) before the file)"))
            r.section("Scan of \(sizeLabel(n)) entries", rows)
        }
        return r
    }

    /// The client's PIR work for the read table of each size: A from its seed, A·s, H·s (32 vectors).
    static func pir(_ s: ClientState, sizes: [Int], engines: [Engine], progress: @escaping (String) -> Void) throws -> StepResult {
        var r = StepResult()
        let seed = Random.bytes(32).hex
        for n in sizes {
            let shape = readShape(n)
            var rows: [Row] = [Row(key: "read table", value: "\(shape.rows) × \(shape.cols) (\(shape.perColumn) records per column)"),
                               Row(key: "setup data H", value: formatBytes(shape.rows * Pir.n * 4)),
                               Row(key: "A", value: "\(formatBytes(shape.cols * Pir.n * 4)), expanded \(Pir.aChunkRows) rows at a time"),
                               Row(key: "one call", value: "\(formatBytes(32 * shape.cols * 4)) up, \(formatBytes(32 * shape.rows * 4)) down")]
            let ref = PirTableRef(digest: "", size: 0, rows: shape.rows, cols: shape.cols, perColumn: shape.perColumn,
                                  cellsPerRecord: Pir.cellsPerRecord(Records.readRecordBytes), recordBytes: Records.readRecordBytes,
                                  records: n, seed: seed, bucketBits: nil, capacity: nil)
            for e in engines {
                progress("\(sizeLabel(n)): \(e.rawValue)")
                let mul = try s.multiplier(e)
                var times = BuildTimes()
                let t = nowMs()
                let columns = (0..<32).map { _ in Random.below(shape.cols) }
                let batch = try Pir.buildQueries(table: ref, columns: columns, multiplier: mul, times: &times)
                let buildMs = nowMs() - t
                let h = mul.makeMatrix(rows: shape.rows, cols: Pir.n)
                Random.fill(UnsafeMutableBufferPointer(start: h.storage, count: shape.rows * Pir.n))
                let answers = [UInt32](repeating: 0, count: 32 * shape.rows)
                let t2 = nowMs()
                let dec1 = try Pir.decodeAnswers(setup: h, batch: batch, answers: answers, which: Array(0..<10), multiplier: mul)
                let dec10 = nowMs() - t2
                let t3 = nowMs()
                let dec32 = try Pir.decodeAnswers(setup: h, batch: batch, answers: answers, which: Array(0..<32), multiplier: mul)
                let decAll = nowMs() - t3
                let slices = (mul as? MetalMultiplier).map { $0.lastSlices > 1 ? " [H in \($0.lastSlices) slices: over the GPU's buffer limit]" : "" } ?? ""
                rows.append(Row(key: e.rawValue + slices, value: String(
                    format: "build %.0f ms (AES %.0f, A·s %.0f%@, error %.0f); decode 10 vectors %.0f ms%@, all 32 %.0f ms%@",
                    buildMs, times.aesMs, times.multiplyMs, times.gpuMs.map { String(format: " GPU %.1f", $0) } ?? "", times.errorMs,
                    dec10, dec1.gpuMs.map { String(format: " (GPU %.1f)", $0) } ?? "", decAll, dec32.gpuMs.map { String(format: " (GPU %.1f)", $0) } ?? "")))
            }
            rows.append(Row(key: "memory left", value: formatBytes(Steps.availableMemory())))
            r.section("Read table of \(sizeLabel(n)) outputs", rows)
        }
        return r
    }
}

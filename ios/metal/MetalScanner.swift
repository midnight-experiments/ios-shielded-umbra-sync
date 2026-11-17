// The ownership test (the scan) on the GPU through Metal: the kernels of generated/PssScan.metal (gen-metal.ts), with
// the inputs, outputs and refusals of the CPU kernel (kernel/src/lib.rs, `scan` and `scan_values`):
//
// - entries are 36 bytes each (compressed point, then element 0's first 4 bytes); the secret is the encryption secret
//   key's scalar, 32 bytes little-endian, below the Jubjub subgroup order (otherwise refused, as the kernel's -1);
// - an all-zero entry, or a point that does not decode, has the value zero and never matches;
// - a match needs the 4 bytes to equal the value's and the point to pass the ledger's check (prime-order subgroup, not
//   the identity; FR-103), which runs on the GPU over the 4-byte matches only.
//
// The host follows gpu/scan.ts: the scalar is recoded once into width-4 signed digits; entries go through the GPU in
// chunks; each chunk runs decompress, the ladder in several dispatches, then finish; the candidates of all chunks then
// run decompress, the ladder with the subgroup order r, and torsion. Every dispatch is its own command buffer, so no
// single GPU submission runs long (iOS stops a command buffer that runs for seconds) and each one's GPU time is known.
//
// iOS: GPU work cannot be submitted while the app is in the background; such a command buffer fails
// (MTLCommandBufferError.notPermitted) and the call throws `.gpu`. Call scan from the foreground; a call that fails
// can be repeated, and entries can be passed in slices to keep each call short.
//
// Usable on iOS 17+ and macOS 14+. Not reentrant: calls on one scanner run one after another (a lock).

import Foundation
import Metal

public enum MetalScannerError: Error, CustomStringConvertible {
    /// The entries' byte count is not a multiple of 36.
    case entriesNotWhole(bytes: Int)
    /// The secret is not 32 bytes.
    case secretLength(Int)
    /// The secret is not below the Jubjub subgroup order (the CPU kernel's -1).
    case secretNotCanonical
    /// The library lacks a kernel, or its layout is not one this host knows.
    case library(String)
    /// A queue, command buffer or buffer could not be made.
    case resources(String)
    /// A command buffer did not complete: on iOS, work submitted from the background (`.notPermitted`) or stopped by
    /// the GPU watchdog (`.timeout`); on any device, a GPU fault or a lost device.
    case gpu(String)

    public var description: String {
        switch self {
        case .entriesNotWhole(let bytes): return "scan entries must be a whole number of 36-byte entries (\(bytes) bytes)"
        case .secretLength(let n): return "secret must be 32 bytes, got \(n)"
        case .secretNotCanonical: return "the secret is not a canonical scalar"
        case .library(let s): return "Metal library: \(s)"
        case .resources(let s): return "Metal resources: \(s)"
        case .gpu(let s): return "GPU: \(s)"
        }
    }
}

/// Times of one call, in seconds. GPU times are MTLCommandBuffer.gpuEndTime − gpuStartTime, summed per phase.
public struct ScanTimings: CustomStringConvertible {
    /// From the call to its result in host memory.
    public var wall: TimeInterval = 0
    /// The main pass: point decoding and tables.
    public var decompress: TimeInterval = 0
    /// The main pass: point × secret.
    public var ladder: TimeInterval = 0
    /// The main pass: affine, two Poseidon hashes, value and candidate flag.
    public var finish: TimeInterval = 0
    /// The subgroup check of the candidates (`scan` only): its decompress, its ladder with r, and the torsion kernel.
    public var torsion: TimeInterval = 0
    /// Chunks of the main pass, and of the candidate pass.
    public var chunks = 0
    public var commandBuffers = 0
    /// The longest single command buffer's GPU time (the iOS watchdog applies per command buffer).
    public var longestCommandBuffer: TimeInterval = 0

    public init() {}

    /// The GPU's execution time of every phase.
    public var gpu: TimeInterval { decompress + ladder + finish + torsion }

    public var description: String {
        let ms = { (s: TimeInterval) in String(format: "%.1f ms", s * 1000) }
        return "wall \(ms(wall)), GPU \(ms(gpu)) (decompress \(ms(decompress)), ladder \(ms(ladder)), finish \(ms(finish)), " +
            "torsion \(ms(torsion))), \(chunks) chunks, \(commandBuffers) command buffers, longest \(ms(longestCommandBuffer))"
    }
}

/// `scan`'s answer: the positions (indices into the entries) that pass the ownership test, ascending.
public struct ScanResult {
    public let positions: [Int]
    public let timings: ScanTimings
}

public final class MetalScanner {
    /// The field the kernels compute in: which kernels of the library the scanner runs.
    public enum Field {
        /// generated/PssScan.metal (`pss_scan_…`): 20 limbs of 13 bits, gpu/field.ts's, 381 state words per entry.
        case limbs13
        /// generated/PssScanW32.metal (`pss_scan32_…`): 8 limbs of 32 bits with `mulhi`, 153 state words per entry.
        case limbs32

        var prefix: String { self == .limbs13 ? "pss_scan_" : "pss_scan32_" }
    }

    public struct Options {
        /// Which kernels to run (default: the 13-bit field, the WGSL kernels' port).
        public var field: Field
        /// Entries per chunk. The chunk's working state is `stateWords` × 4 bytes per entry (1,524 bytes with the
        /// 13-bit field): 32,768 entries are 50 MB of state, 1.2 MB of entries and 1.2 MB of outputs.
        public var chunkEntries: Int
        /// Ladder digits per dispatch: 37 gives seven dispatches for the 253 digits (gpu/scan.ts's default).
        public var digitsPerPass: Int
        /// Threads per threadgroup, capped by each pipeline's `maxTotalThreadsPerThreadgroup`.
        public var threadgroupWidth: Int
        /// If not zero, the pipelines are built with this `maxTotalThreadsPerThreadgroup` (a register budget hint to
        /// the compiler).
        public var maxTotalThreadsPerThreadgroup: Int

        public init(field: Field = .limbs13, chunkEntries: Int = 32_768, digitsPerPass: Int = 37, threadgroupWidth: Int = 64,
                    maxTotalThreadsPerThreadgroup: Int = 0) {
            self.field = field
            self.chunkEntries = chunkEntries
            self.digitsPerPass = digitsPerPass
            self.threadgroupWidth = threadgroupWidth
            self.maxTotalThreadsPerThreadgroup = maxTotalThreadsPerThreadgroup
        }
    }

    /// The limits Metal gives a pipeline (register pressure shows as a lower `maxTotalThreadsPerThreadgroup`).
    public struct PipelineInfo {
        public let name: String
        public let maxTotalThreadsPerThreadgroup: Int
        public let threadExecutionWidth: Int
        public let staticThreadgroupMemoryLength: Int
    }

    public static let entryBytes = 36
    static let entryWords = 9
    static let outWords = 9
    static let digits = 253
    static let paramsWords = 260 // 256 digits, then top, count, n, pad (1,040 bytes, as the WGSL uniform)

    public let device: MTLDevice
    public let options: Options
    /// State words per entry and words of one field element, as the library reports them (its `layout` kernel).
    public let stateWords: Int
    public let fieldWords: Int
    public let pipelines: [PipelineInfo]
    /// Times of the last `scan` or `scanValues` call.
    public private(set) var lastTimings: ScanTimings?

    private let queue: MTLCommandQueue
    private let decompress: MTLComputePipelineState
    private let ladder: MTLComputePipelineState
    private let finish: MTLComputePipelineState
    private let torsion: MTLComputePipelineState
    private let passes: [(top: Int, count: Int)]
    private let lock = NSLock()
    private var buffers: (entries: MTLBuffer, state: MTLBuffer, out: MTLBuffer)?

    /// Builds the pipelines from a library holding the kernels of generated/PssScan.metal (or PssScanW32.metal, with
    /// `options.field = .limbs32`): the app's default library, or `device.makeLibrary(source:options:)`.
    public init(device: MTLDevice, library: MTLLibrary, options: Options = Options()) throws {
        guard options.chunkEntries >= 1, options.digitsPerPass >= 1, options.digitsPerPass <= Self.digits, options.threadgroupWidth >= 1 else {
            throw MetalScannerError.resources("options out of range: \(options)")
        }
        self.device = device
        self.options = options
        guard let queue = device.makeCommandQueue() else { throw MetalScannerError.resources("no command queue") }
        self.queue = queue
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: options.field.prefix + name) else {
                throw MetalScannerError.library("no kernel \(options.field.prefix + name)")
            }
            let d = MTLComputePipelineDescriptor()
            d.computeFunction = f
            d.label = name
            if options.maxTotalThreadsPerThreadgroup > 0 { d.maxTotalThreadsPerThreadgroup = options.maxTotalThreadsPerThreadgroup }
            return try device.makeComputePipelineState(descriptor: d, options: [], reflection: nil)
        }
        decompress = try pipeline("decompress")
        ladder = try pipeline("ladder")
        finish = try pipeline("finish")
        torsion = try pipeline("torsion")
        pipelines = [("decompress", decompress), ("ladder", ladder), ("finish", finish), ("torsion", torsion)].map {
            PipelineInfo(name: $0.0, maxTotalThreadsPerThreadgroup: $0.1.maxTotalThreadsPerThreadgroup,
                         threadExecutionWidth: $0.1.threadExecutionWidth, staticThreadgroupMemoryLength: $0.1.staticThreadgroupMemoryLength)
        }
        var passes: [(top: Int, count: Int)] = []
        var top = Self.digits - 1
        while top >= 0 {
            passes.append((top, min(options.digitsPerPass, top + 1)))
            top -= options.digitsPerPass
        }
        self.passes = passes
        // The library's layout: state words per entry and field words.
        let layoutPipeline = try pipeline("layout")
        guard let out = device.makeBuffer(length: 16, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw MetalScannerError.resources("layout query")
        }
        enc.setComputePipelineState(layoutPipeline)
        enc.setBuffer(out, offset: 0, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw MetalScannerError.gpu("layout query: \(e.localizedDescription)") }
        let words = out.contents().bindMemory(to: UInt32.self, capacity: 2)
        stateWords = Int(words[0])
        fieldWords = Int(words[1])
        guard fieldWords == (options.field == .limbs13 ? 20 : 8), stateWords == 16 * fieldWords + 3 * fieldWords + 1 else {
            throw MetalScannerError.library("unknown layout: \(stateWords) state words, \(fieldWords) field words")
        }
    }

    /// Bytes of GPU memory a chunk holds (state, entries, outputs).
    public var chunkBytes: Int { options.chunkEntries * (stateWords + Self.entryWords + Self.outWords) * 4 }

    /// Frees the chunk buffers (they hold the last chunk's points × secret and values until the next call).
    public func releaseBuffers() {
        lock.lock()
        defer { lock.unlock() }
        buffers = nil
    }

    // MARK: - Calls

    /// The positions (indices into `entries`) that pass the ownership test, ascending, as the CPU kernel's `scan`.
    public func scan(entries: Data, secret: [UInt8]) throws -> ScanResult {
        lock.lock()
        defer { lock.unlock() }
        let start = DispatchTime.now().uptimeNanoseconds
        let count = try Self.entryCount(entries)
        var params = try Self.secretParams(secret)
        defer { Self.wipe(&params) }
        var t = ScanTimings()
        var candidates: [Int] = []
        if count > 0 {
            try values(entries: entries, count: count, params: &params, timings: &t) { first, n, out in
                for k in 0..<n where out[k * Self.outWords + 8] == 1 { candidates.append(first + k) }
            }
        }
        var positions: [Int] = []
        if !candidates.isEmpty {
            let ok = try inSubgroup(entries: entries, indices: candidates, timings: &t)
            positions = zip(candidates, ok).compactMap { $0.1 ? $0.0 : nil }
        }
        t.wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lastTimings = t
        return ScanResult(positions: positions, timings: t)
    }

    /// For each entry, the 32-byte value the ownership test compares (zero for an all-zero entry or a point that does
    /// not decode), as the CPU kernel's `scan_values`.
    public func scanValues(entries: Data, secret: [UInt8]) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let start = DispatchTime.now().uptimeNanoseconds
        let count = try Self.entryCount(entries)
        var params = try Self.secretParams(secret)
        defer { Self.wipe(&params) }
        var t = ScanTimings()
        var result = Data(count: count * 32)
        if count > 0 {
            try result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let words = dst.bindMemory(to: UInt32.self)
                try values(entries: entries, count: count, params: &params, timings: &t) { first, n, out in
                    for k in 0..<n {
                        let o = k * Self.outWords
                        let d = (first + k) * 8
                        for w in 0..<8 { words[d + w] = out[o + w] }
                    }
                }
            }
        }
        t.wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lastTimings = t
        return result
    }

    // MARK: - Chunks

    private enum Phase { case decompress, ladder, finish, torsion }

    private func chunkBuffers() throws -> (entries: MTLBuffer, state: MTLBuffer, out: MTLBuffer) {
        if let b = buffers { return b }
        let n = options.chunkEntries
        let stateBytes = n * stateWords * 4
        guard stateBytes <= device.maxBufferLength else {
            throw MetalScannerError.resources("a chunk's state (\(stateBytes) bytes) exceeds maxBufferLength \(device.maxBufferLength)")
        }
        guard let e = device.makeBuffer(length: n * Self.entryBytes, options: .storageModeShared),
              let s = device.makeBuffer(length: stateBytes, options: .storageModePrivate),
              let o = device.makeBuffer(length: n * Self.outWords * 4, options: .storageModeShared) else {
            throw MetalScannerError.resources("chunk buffers for \(n) entries refused")
        }
        e.label = "scan entries"
        s.label = "scan state"
        o.label = "scan outputs"
        buffers = (e, s, o)
        return (e, s, o)
    }

    /// Runs decompress, the ladder and `last` over the `n` entries in the entries buffer, one command buffer per
    /// dispatch, waits, and adds the GPU times to `phase` (or to torsion for the candidate pass).
    private func run(n: Int, params: inout [Int32], last: MTLComputePipelineState, candidatePass: Bool, timings t: inout ScanTimings) throws {
        let b = try chunkBuffers()
        var submitted: [(MTLCommandBuffer, Phase)] = []
        func submit(_ pipeline: MTLComputePipelineState, _ phase: Phase) throws {
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
                throw MetalScannerError.resources("no command buffer")
            }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(b.entries, offset: 0, index: 0)
            enc.setBuffer(b.state, offset: 0, index: 1)
            enc.setBuffer(b.out, offset: 0, index: 2)
            params.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 3) }
            let width = min(options.threadgroupWidth, pipeline.maxTotalThreadsPerThreadgroup)
            enc.dispatchThreadgroups(MTLSize(width: (n + width - 1) / width, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            submitted.append((cb, candidatePass ? .torsion : phase))
        }
        params[258] = Int32(n)
        do {
            try submit(decompress, .decompress)
            for p in passes {
                params[256] = Int32(p.top)
                params[257] = Int32(p.count)
                try submit(ladder, .ladder)
            }
            try submit(last, candidatePass ? .torsion : .finish)
        } catch {
            // The buffers stay in use until what was committed has run.
            for (cb, _) in submitted { cb.waitUntilCompleted() }
            throw error
        }
        for (cb, phase) in submitted {
            cb.waitUntilCompleted()
            guard cb.status == .completed else {
                throw MetalScannerError.gpu("command buffer \(cb.status.rawValue): \(cb.error.map { "\($0)" } ?? "no error given")")
            }
            let s = cb.gpuEndTime - cb.gpuStartTime
            switch phase {
            case .decompress: t.decompress += s
            case .ladder: t.ladder += s
            case .finish: t.finish += s
            case .torsion: t.torsion += s
            }
            t.longestCommandBuffer = max(t.longestCommandBuffer, s)
        }
        t.commandBuffers += submitted.count
        t.chunks += 1
    }

    /// Values and candidate flags of every entry, chunk by chunk (equal chunks of at most `chunkEntries`).
    /// `onChunk` gets the chunk's first entry index, its entry count and its outputs (9 words per entry).
    private func values(entries: Data, count: Int, params: inout [Int32], timings t: inout ScanTimings,
                        onChunk: (Int, Int, UnsafeBufferPointer<UInt32>) throws -> Void) throws {
        let chunks = (count + options.chunkEntries - 1) / options.chunkEntries
        let size = (count + chunks - 1) / chunks
        let b = try chunkBuffers()
        try entries.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var first = 0
            while first < count {
                let n = min(size, count - first)
                b.entries.contents().copyMemory(from: src.baseAddress! + first * Self.entryBytes, byteCount: n * Self.entryBytes)
                try run(n: n, params: &params, last: finish, candidatePass: false, timings: &t)
                try onChunk(first, n, UnsafeBufferPointer(start: b.out.contents().bindMemory(to: UInt32.self, capacity: n * Self.outWords), count: n * Self.outWords))
                first += n
            }
        }
    }

    /// The ledger's point check (prime-order subgroup, not the identity) of the given entries, on the GPU.
    private func inSubgroup(entries: Data, indices: [Int], timings t: inout ScanTimings) throws -> [Bool] {
        var params = [Int32](repeating: 0, count: Self.paramsWords)
        params.replaceSubrange(0..<256, with: Self.signedDigits(Self.subgroupOrder))
        let b = try chunkBuffers()
        var ok: [Bool] = []
        ok.reserveCapacity(indices.count)
        try entries.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var first = 0
            while first < indices.count {
                let n = min(options.chunkEntries, indices.count - first)
                let dst = b.entries.contents()
                for k in 0..<n {
                    dst.advanced(by: k * Self.entryBytes).copyMemory(from: src.baseAddress! + indices[first + k] * Self.entryBytes, byteCount: Self.entryBytes)
                }
                try run(n: n, params: &params, last: torsion, candidatePass: true, timings: &t)
                let out = b.out.contents().bindMemory(to: UInt32.self, capacity: n * Self.outWords)
                for k in 0..<n { ok.append(out[k * Self.outWords + 8] == 1) }
                first += n
            }
        }
        return ok
    }

    // MARK: - Inputs

    private static func entryCount(_ entries: Data) throws -> Int {
        guard entries.count % entryBytes == 0 else { throw MetalScannerError.entriesNotWhole(bytes: entries.count) }
        return entries.count / entryBytes
    }

    /// Jubjub's prime subgroup order r, four little-endian 64-bit limbs.
    static let subgroupOrder: [UInt64] = [0xd097_0e5e_d6f7_2cb7, 0xa668_2093_ccc8_1082, 0x0667_3b01_0134_3b00, 0x0e7d_b4ea_6533_afa9]

    /// The parameters' words with the secret's digits; throws as the kernel does for a wrong length or a scalar not
    /// below r.
    private static func secretParams(_ secret: [UInt8]) throws -> [Int32] {
        guard secret.count == 32 else { throw MetalScannerError.secretLength(secret.count) }
        var k = [UInt64](repeating: 0, count: 4)
        for i in 0..<32 { k[i / 8] |= UInt64(secret[i]) << (8 * UInt64(i % 8)) }
        defer { for i in 0..<4 { k[i] = 0 } }
        var below = false
        for i in stride(from: 3, through: 0, by: -1) where k[i] != subgroupOrder[i] {
            below = k[i] < subgroupOrder[i]
            break
        }
        guard below else { throw MetalScannerError.secretNotCanonical }
        var params = [Int32](repeating: 0, count: paramsWords)
        var digits = signedDigits(k)
        params.replaceSubrange(0..<256, with: digits)
        wipe(&digits)
        return params
    }

    /// A scalar below 2^252 in width-4 non-adjacent form (gpu/scan.ts's signedDigits): digit i (0 or ±1, ±3, ±5, ±7)
    /// counts 2^i, and of any four digits in a row at most one is not zero. 256 values, of which at most 253 are used.
    static func signedDigits(_ scalar: [UInt64]) -> [Int32] {
        var k = scalar
        var digits = [Int32](repeating: 0, count: 256)
        var i = 0
        while k.contains(where: { $0 != 0 }) {
            precondition(i < Self.digits, "the scalar is not below 2^252")
            if k[0] & 1 == 1 {
                let d = Int32(k[0] & 15)
                let digit = d >= 8 ? d - 16 : d
                digits[i] = digit
                if digit > 0 {
                    // k − digit: k's low bits are digit's, so nothing borrows.
                    k[0] -= UInt64(digit)
                } else {
                    var carry = UInt64(-digit)
                    for j in 0..<4 where carry != 0 {
                        let (s, o) = k[j].addingReportingOverflow(carry)
                        k[j] = s
                        carry = o ? 1 : 0
                    }
                }
            }
            for j in 0..<4 { k[j] = (k[j] >> 1) | (j < 3 ? k[j + 1] << 63 : 0) }
            i += 1
        }
        return digits
    }

    private static func wipe(_ a: inout [Int32]) {
        for i in a.indices { a[i] = 0 }
    }
}

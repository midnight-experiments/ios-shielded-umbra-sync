// The PIR multiply on the GPU through Metal (Multiply.metal). Matrices made by `makeMatrix` live in shared memory, so
// the CPU writes A's chunks (AES-CTR) and the downloaded setup data straight into what the GPU reads: no copies.

import Foundation
import Metal

final class MetalMultiplier: Multiplier {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    var name: String { "Metal GPU (\(device.name))" }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw ClientError.invalid("no Metal command queue") }
        queue = q
        guard let f = library.makeFunction(name: "pir_multiply") else { throw ClientError.invalid("pir_multiply is not in the Metal library") }
        pipeline = try device.makeComputePipelineState(function: f)
    }

    var threadExecutionWidth: Int { pipeline.threadExecutionWidth }
    var maxThreadsPerThreadgroup: Int { pipeline.maxTotalThreadsPerThreadgroup }

    func makeMatrix(rows: Int, cols: Int) -> Matrix32 {
        Matrix32(rows: rows, cols: cols) { [device] bytes in
            guard let b = device.makeBuffer(length: max(16, bytes), options: .storageModeShared) else { return nil }
            return (b.contents(), b)
        }
    }

    /// Matrices larger than one buffer may be (device.maxBufferLength) are multiplied in slices of rows, each
    /// copied into a reusable buffer; the others are read in place.
    private(set) var lastSlices = 1

    func multiply(_ m: Matrix32, rows: Int, vectors: [UInt32], count: Int) throws -> (out: [UInt32], gpuMs: Double?) {
        let cols = m.cols
        precondition(cols % 4 == 0 && vectors.count == count * cols && rows <= m.rows)
        // A call with no real vector to decode (a wallet with no coin, padding not decoded): nothing to multiply, and
        // Metal refuses a buffer of length 0.
        if count == 0 { return ([], nil) }
        let countPad = (count + 7) / 8 * 8
        guard let vt = device.makeBuffer(length: countPad * cols * 4, options: .storageModeShared) else { throw ClientError.invalid("Metal buffers refused") }
        let t = vt.contents().bindMemory(to: UInt32.self, capacity: countPad * cols)
        vectors.withUnsafeBufferPointer { v in
            for k in 0..<cols {
                for i in 0..<count { t[k * countPad + i] = v[i * cols + k] }
                for i in count..<countPad { t[k * countPad + i] = 0 }
            }
        }
        if let b = m.gpuBuffer as? MTLBuffer {
            lastSlices = 1
            let (out, ms) = try dispatch(matrix: b, rows: rows, cols: cols, vt: vt, countPad: countPad, count: count)
            return (Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: UInt32.self, capacity: count * rows), count: count * rows)), ms)
        }
        let sliceRows = max(1, min(rows, device.maxBufferLength / (cols * 4)))
        guard let slice = device.makeBuffer(length: sliceRows * cols * 4, options: .storageModeShared) else { throw ClientError.invalid("a slice buffer of \(sliceRows * cols * 4) bytes refused") }
        var result = [UInt32](repeating: 0, count: count * rows)
        var gpu = 0.0
        var r0 = 0
        lastSlices = 0
        while r0 < rows {
            let n = min(sliceRows, rows - r0)
            slice.contents().copyMemory(from: m.storage + r0 * cols, byteCount: n * cols * 4)
            let (out, ms) = try dispatch(matrix: slice, rows: n, cols: cols, vt: vt, countPad: countPad, count: count)
            let o = out.contents().bindMemory(to: UInt32.self, capacity: count * n)
            for v in 0..<count { for r in 0..<n { result[v * rows + r0 + r] = o[v * n + r] } }
            gpu += ms
            r0 += n
            lastSlices += 1
        }
        return (result, gpu)
    }

    private func dispatch(matrix: MTLBuffer, rows: Int, cols: Int, vt: MTLBuffer, countPad: Int, count: Int) throws -> (MTLBuffer, Double) {
        guard let out = device.makeBuffer(length: max(16, count * rows * 4), options: .storageModeShared) else { throw ClientError.invalid("Metal buffers refused") }
        var dims = (UInt32(rows), UInt32(cols), UInt32(countPad), UInt32(count))
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw ClientError.invalid("no Metal command buffer") }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(matrix, offset: 0, index: 0)
        enc.setBuffer(vt, offset: 0, index: 1)
        enc.setBuffer(out, offset: 0, index: 2)
        enc.setBytes(&dims, length: MemoryLayout.size(ofValue: dims), index: 3)
        let width = min(64, pipeline.maxTotalThreadsPerThreadgroup)
        enc.dispatchThreads(MTLSize(width: rows, height: countPad / 8, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw ClientError.invalid("Metal multiply failed: \(e.localizedDescription)") }
        return (out, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }
}

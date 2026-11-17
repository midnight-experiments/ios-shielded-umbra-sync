// The client's PIR multiplications on the GPU: A·s (building queries) and H·s (decoding answers).
//
// out[v·rows + r] = Σ_k m[r·cols + k] · s[v][k] mod 2^32. The vectors arrive transposed (k-major, `countPad` values
// per k, countPad a multiple of 8), so a thread reads its eight vectors' values for one k as two uint4. One thread per
// (row, block of 8 vectors). `uint` arithmetic wraps modulo 2^32, as the CPU's does.

#include <metal_stdlib>
using namespace metal;

struct MulDims {
    uint rows;
    uint cols;      // a multiple of 4
    uint countPad;  // a multiple of 8
    uint count;     // vectors actually written
};

kernel void pir_multiply(device const uint4 *m [[buffer(0)]],
                         device const uint4 *vt [[buffer(1)]],
                         device uint *out [[buffer(2)]],
                         constant MulDims &d [[buffer(3)]],
                         uint2 gid [[thread_position_in_grid]]) {
    const uint row = gid.x;
    const uint vb = gid.y * 8u;
    if (row >= d.rows || vb >= d.count) { return; }
    device const uint4 *mr = m + (row * d.cols) / 4u;
    const uint stride = d.countPad / 4u;   // uint4s per k
    device const uint4 *vp = vt + vb / 4u;
    uint4 acc0 = uint4(0u);
    uint4 acc1 = uint4(0u);
    const uint quads = d.cols / 4u;
    for (uint q = 0u; q < quads; q++) {
        const uint4 a = mr[q];
        const uint k = q * 4u;
        acc0 += a.x * vp[(k + 0u) * stride]; acc1 += a.x * vp[(k + 0u) * stride + 1u];
        acc0 += a.y * vp[(k + 1u) * stride]; acc1 += a.y * vp[(k + 1u) * stride + 1u];
        acc0 += a.z * vp[(k + 2u) * stride]; acc1 += a.z * vp[(k + 2u) * stride + 1u];
        acc0 += a.w * vp[(k + 3u) * stride]; acc1 += a.w * vp[(k + 3u) * stride + 1u];
    }
    const uint rows = d.rows;
    const uint acc[8] = { acc0.x, acc0.y, acc0.z, acc0.w, acc1.x, acc1.y, acc1.z, acc1.w };
    for (uint i = 0u; i < 8u; i++) {
        if (vb + i < d.count) { out[(vb + i) * rows + row] = acc[i]; }
    }
}

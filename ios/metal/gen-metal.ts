/**
 * Writes the ownership test's Metal kernels (the scan) into `generated/`:
 *
 * - `PssScan.metal`: `gpu/scan-wgsl.ts` ported to the Metal Shading Language, with the same algorithm and the same
 *   memory layout (381 state words and 9 output words per entry). The field is `gpu/field.ts`'s: 20 limbs of 13 bits
 *   in Montgomery form (R = 2^260), `fadd`/`fsub`/`fneg`/`mmul`/`msqr` generated straight-line as there.
 * - `PssScanW32.metal`: the same kernels over a field of 8 limbs of 32 bits (R = 2^256), each limb product a 64-bit
 *   `ulong` multiply-add, which WGSL has no type for (`--variant w32` of the check; `MetalScanner.Options.field =
 *   .limbs32`). Its state is 153 words per entry.
 *
 * Kernels: `pss_scan_decompress`, `pss_scan_ladder`, `pss_scan_finish`, `pss_scan_torsion`, `pss_scan_layout` (the
 * variant: `pss_scan32_…`); everything else sits in a namespace (`pss_scan13`, `pss_scan32`), so both files and other
 * .metal files can be compiled into one library.
 *
 * The constants come from one source, `gpu/field.ts`'s `constantTable` over `test/fixtures/poseidon-constants.json`:
 * the 13-bit file holds that table as it is; the 32-bit file holds the same slots converted to its own Montgomery form.
 * Both hold the table as a program-scope `constant` array (WGSL needed a storage buffer only because of a Deno bug).
 *
 *     node gen-metal.ts
 *     node gen-metal.ts --w32 ulong|mulhi ulong|compare FILE   # one other form of the 32-bit field, for measuring
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { constantTable, CONSTANT_SLOTS, LIMBS, limbs, P, type PoseidonConstants, SLOT, words } from "../../gpu/field.ts";
import { DIGITS, ENTRY_WORDS, OUT_WORDS, PARAMS_BYTES, STATE_WORDS } from "../../gpu/scan-wgsl.ts";

const here = (p: string): string => fileURLToPath(new URL(p, import.meta.url));
const range = (n: number): number[] => Array.from({ length: n }, (_, i) => i);
const mod = (a: bigint): bigint => ((a % P) + P) % P;

// The WGSL layout (scan-wgsl.ts keeps these private; checked against its exported STATE_WORDS below).
const TABLE_POINT = 80;
const X_AT = 320;
const Y_AT = 340;
const Z_AT = 360;
const FLAGS_AT = 380;
if (FLAGS_AT + 1 !== STATE_WORDS || ENTRY_WORDS !== 9 || OUT_WORDS !== 9 || PARAMS_BYTES !== 1040 || DIGITS !== 253) {
  throw new Error("scan-wgsl.ts's layout changed: update gen-metal.ts");
}

const poseidon = JSON.parse(readFileSync(here("../../test/fixtures/poseidon-constants.json"), "utf8")) as PoseidonConstants;
const table = constantTable(poseidon);

/** A uint array as MSL initializer lines, `per` values a line, each line prefixed by `comment(line)`. */
function arrayLines(values: ArrayLike<number>, per: number, comment: (line: number) => string): string {
  const lines: string[] = [];
  for (let i = 0; i < values.length; i += per) {
    const row = Array.from({ length: Math.min(per, values.length - i) }, (_, k) => `${values[i + k]! >>> 0}u`);
    lines.push(`  ${row.join(", ")},${comment(i / per)}`);
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------------------------------------------
// The kernels, shared by both fields. The field module provides: the type Fe, FE_WORDS (words of one element in the
// state), fadd, fsub, fneg, mmul, msqr, fpow, fsqrt_ratio, feq, is_zero, cld, to_mont, from_mont, fe_of_words (plain
// value of eight words), words_of_fe (eight words of a plain value), fe_geq_p (plain value at least p), ld and st.
// ---------------------------------------------------------------------------------------------------------------

function kernels(fe: number): string {
  const tablePoint = 4 * fe;
  const xAt = 4 * tablePoint;
  const yAt = xAt + fe;
  const zAt = yAt + fe;
  const flagsAt = zAt + fe;
  const stateWords = flagsAt + 1;
  return /* metal */ `
#define STATE_WORDS ${stateWords}u
#define TABLE_POINT ${tablePoint}u
#define X_AT ${xAt}u
#define Y_AT ${yAt}u
#define Z_AT ${zAt}u
#define FLAGS_AT ${flagsAt}u
#define FLAG_VALID 1u
#define FLAG_IDENTITY 2u

// The pass's parameters (setBytes, ${PARAMS_BYTES} bytes, the WGSL uniform's layout): the recoded scalar's digits, the
// pass's first digit, its digit count, and the entry count.
struct Params { int digits[256]; uint top; uint count; uint n; uint pad; };

inline Fe pow5(Fe x) { const Fe x2 = msqr(x); const Fe x4 = msqr(x2); return mmul(x4, x); }

// Poseidon of two elements: width 3, 8 full and 60 partial rounds, x^5, state [a, b, 2], first element out. Partial
// rounds 4–62 are in the constant table's sparse form (field.ts, partialRounds): five products a round. One loop for
// all rounds, so the code holds each product once.
inline Fe poseidon(Fe a, Fe b) {
  Fe s0 = fadd(a, cld(0u));
  Fe s1 = fadd(b, cld(1u));
  Fe s2 = fadd(cld(${SLOT.TWO}u), cld(2u));
  for (uint r = 0u; r < 68u; r++) {
    if (r < 4u || r >= 64u) { s0 = pow5(s0); s1 = pow5(s1); }
    const Fe x = pow5(s2);
    if (r >= 4u && r < 63u) {
      const uint q = ${SLOT.SPARSE}u + (r - 4u) * 5u;
      s2 = fadd(fadd(fadd(mmul(cld(q), s0), mmul(cld(q + 1u), s1)), mmul(cld(q + 2u), x)), cld(${SLOT.PARTIAL_CONSTANT}u + r - 4u));
      s0 = fadd(s0, mmul(cld(q + 3u), x));
      s1 = fadd(s1, mmul(cld(q + 4u), x));
    } else {
      uint m = ${SLOT.MDS}u;
      uint k = (r + 1u) * 3u;
      if (r == 63u) { m = ${SLOT.LAST_PARTIAL}u; k = ${SLOT.AFTER_PARTIAL}u; }
      Fe n0 = fadd(fadd(mmul(cld(m), s0), mmul(cld(m + 1u), s1)), mmul(cld(m + 2u), x));
      Fe n1 = fadd(fadd(mmul(cld(m + 3u), s0), mmul(cld(m + 4u), s1)), mmul(cld(m + 5u), x));
      Fe n2 = fadd(fadd(mmul(cld(m + 6u), s0), mmul(cld(m + 7u), s1)), mmul(cld(m + 8u), x));
      if (r < 67u) { n0 = fadd(n0, cld(k)); n1 = fadd(n1, cld(k + 1u)); n2 = fadd(n2, cld(k + 2u)); }
      s0 = n0; s1 = n1; s2 = n2;
    }
  }
  return s0;
}

// 1. Decodes the point as JubjubAffine::from_bytes does (v below p, u² a square, ZIP 216's refusal) and stores its
// table P, 3P, 5P, 7P, each as (Y − X, Y + X, 2d·T, 2Z), the ladder's start (the identity) and the flags.
inline void decompress(device const uint* entries, device uint* state, constant Params& params, uint idx) {
  if (idx >= params.n) { return; }
  const uint e = idx * ${ENTRY_WORDS}u;
  const uint s = idx * STATE_WORDS;
  uint nz = 0u;
  for (uint k = 0u; k < ${ENTRY_WORDS}u; k++) { nz = nz | entries[e + k]; }
  if (nz == 0u) { state[s + FLAGS_AT] = 0u; return; }
  W8 w = {};
  for (uint k = 0u; k < 8u; k++) { w.w[k] = entries[e + k]; }
  const uint sign = w.w[7] >> 31u;
  w.w[7] = w.w[7] & 0x7fffffffu;
  if (fe_geq_p(w)) { state[s + FLAGS_AT] = 0u; return; }
  const Fe raw = fe_of_words(w);
  const Fe v = to_mont(raw);
  const Fe v2 = msqr(v);
  const Fe one = cld(${SLOT.ONE}u);
  const Fe num = fsub(v2, one);
  const Fe den = fadd(one, mmul(cld(${SLOT.D}u), v2));
  Fe u = fsqrt_ratio(num, den);
  if (!feq(mmul(msqr(u), den), num)) { state[s + FLAGS_AT] = 0u; return; }
  const Fe ucan = from_mont(u);
  const bool u_zero = is_zero(ucan);
  if (u_zero && sign == 1u) { state[s + FLAGS_AT] = 0u; return; }
  if (fe_low_bit(ucan) != sign) { u = fneg(u); }
  uint flags = FLAG_VALID;
  if (u_zero && feq(v, one)) { flags = flags | FLAG_IDENTITY; }
  // The table: P, then 3P, 5P and 7P. The loop's first turn adds P to itself; 2P then becomes the addend and the sum
  // starts again from P, so the next three turns give 3P, 5P and 7P.
  const Fe two_d = cld(${SLOT.D2}u);
  const Fe t1 = mmul(u, v);
  Fe qa = fsub(v, u);
  Fe qb = fadd(v, u);
  Fe qc = mmul(two_d, t1);
  Fe qd = fadd(one, one);
  st(state, s, qa); st(state, s + ${fe}u, qb); st(state, s + ${2 * fe}u, qc); st(state, s + ${3 * fe}u, qd);
  Fe X = u; Fe Y = v; Fe Z = one; Fe T = t1;
  for (uint k = 0u; k < 4u; k++) {
    const Fe a2 = mmul(fsub(Y, X), qa);
    const Fe b2 = mmul(fadd(Y, X), qb);
    const Fe c2 = mmul(T, qc);
    const Fe d2 = mmul(Z, qd);
    const Fe e2 = fsub(b2, a2);
    const Fe f2 = fsub(d2, c2);
    const Fe g2 = fadd(d2, c2);
    const Fe h2 = fadd(b2, a2);
    X = mmul(e2, f2); Y = mmul(g2, h2); T = mmul(e2, h2); Z = mmul(f2, g2);
    const Fe ca = fsub(Y, X);
    const Fe cb = fadd(Y, X);
    const Fe cc = mmul(two_d, T);
    const Fe cd = fadd(Z, Z);
    if (k == 0u) {
      qa = ca; qb = cb; qc = cc; qd = cd;
      X = u; Y = v; Z = one; T = t1;
    } else {
      const uint tb = s + k * TABLE_POINT;
      st(state, tb, ca); st(state, tb + ${fe}u, cb); st(state, tb + ${2 * fe}u, cc); st(state, tb + ${3 * fe}u, cd);
    }
  }
  // The ladder starts from the identity.
  const Fe zero = {};
  st(state, s + X_AT, zero);
  st(state, s + Y_AT, one);
  st(state, s + Z_AT, one);
  state[s + FLAGS_AT] = flags;
}

// 2. params.count digits of the recoded scalar, from digit params.top downward: a doubling per digit, and for a
// digit that is not zero an addition of the table's point (its negative for a negative digit).
inline void ladder(device uint* state, constant Params& params, uint idx) {
  if (idx >= params.n) { return; }
  const uint s = idx * STATE_WORDS;
  if ((state[s + FLAGS_AT] & FLAG_VALID) == 0u) { return; }
  Fe X = ld(state, s + X_AT);
  Fe Y = ld(state, s + Y_AT);
  Fe Z = ld(state, s + Z_AT);
  for (uint k = 0u; k < params.count; k++) {
    const uint pos = params.top - k;
    const int digit = params.digits[pos];
    const Fe A = msqr(X);
    const Fe B = msqr(Y);
    const Fe zz = msqr(Z);
    const Fe C = fadd(zz, zz);
    const Fe xy = fadd(X, Y);
    const Fe E = fsub(fsub(msqr(xy), A), B);
    const Fe G = fsub(B, A);
    const Fe F = fsub(G, C);
    const Fe H = fneg(fadd(A, B));
    X = mmul(E, F); Y = mmul(G, H); Z = mmul(F, G);
    if (digit != 0) {
      const Fe T = mmul(E, H);
      const bool negative = digit < 0;
      const uint tb = s + (uint(negative ? -digit : digit) >> 1u) * TABLE_POINT;
      Fe pa = ld(state, tb);
      Fe pb = ld(state, tb + ${fe}u);
      if (negative) { const Fe swap = pa; pa = pb; pb = swap; }
      const Fe a2 = mmul(fsub(Y, X), pa);
      const Fe b2 = mmul(fadd(Y, X), pb);
      const Fe c2 = mmul(T, ld(state, tb + ${2 * fe}u));
      const Fe d2 = mmul(Z, ld(state, tb + ${3 * fe}u));
      const Fe e2 = fsub(b2, a2);
      Fe f2 = fsub(d2, c2);
      Fe g2 = fadd(d2, c2);
      const Fe h2 = fadd(b2, a2);
      if (negative) { const Fe swap = f2; f2 = g2; g2 = swap; }
      X = mmul(e2, f2); Y = mmul(g2, h2); Z = mmul(f2, g2);
    }
  }
  st(state, s + X_AT, X); st(state, s + Y_AT, Y); st(state, s + Z_AT, Z);
}

// 3. k* to affine, k = Poseidon(k*.u, k*.v), value = Poseidon(k, 0): the value's eight words and the candidate flag
// (the value's low 4 bytes equal the entry's 4 bytes).
inline void finish(device const uint* entries, device uint* state, device uint* outb, constant Params& params, uint idx) {
  if (idx >= params.n) { return; }
  const uint s = idx * STATE_WORDS;
  const uint o = idx * ${OUT_WORDS}u;
  if ((state[s + FLAGS_AT] & FLAG_VALID) == 0u) {
    for (uint k = 0u; k < ${OUT_WORDS}u; k++) { outb[o + k] = 0u; }
    return;
  }
  const Fe zi = fpow(ld(state, s + Z_AT), 0u);
  const Fe x = mmul(ld(state, s + X_AT), zi);
  const Fe y = mmul(ld(state, s + Y_AT), zi);
  const Fe zero = {};
  Fe pad = x;
  Fe second = y;
  for (uint i = 0u; i < 2u; i++) { pad = poseidon(pad, second); second = zero; }
  const W8 w = words_of_fe(from_mont(pad));
  for (uint k = 0u; k < 8u; k++) { outb[o + k] = w.w[k]; }
  outb[o + 8u] = uint(w.w[0] == entries[idx * ${ENTRY_WORDS}u + 8u]);
}

// 4. After decompress and the ladder with the scalar r: 1 if the point is in the prime-order subgroup and not the
// identity (the ledger's check, FR-103).
inline void torsion(device uint* state, device uint* outb, constant Params& params, uint idx) {
  if (idx >= params.n) { return; }
  const uint s = idx * STATE_WORDS;
  const uint flags = state[s + FLAGS_AT];
  bool ok = (flags & FLAG_VALID) != 0u && (flags & FLAG_IDENTITY) == 0u;
  if (ok) { ok = is_zero(ld(state, s + X_AT)) && feq(ld(state, s + Y_AT), ld(state, s + Z_AT)); }
  outb[idx * ${OUT_WORDS}u + 8u] = uint(ok);
}

// The layout, for the host: state words per entry and the field's limb count (read by MetalScanner).
inline void layout(device uint* outb, uint idx) {
  if (idx == 0u) { outb[0] = STATE_WORDS; outb[1] = FE_WORDS; }
}
`;
}

/**
 * The kernels at program scope, named `<prefix>decompress` … `<prefix>layout`, each calling its body in the variant's
 * namespace. Buffers: 0 entries, 1 state, 2 outputs, 3 parameters (setBytes).
 */
function entryPoints(ns: string, prefix: string): string {
  const e = "device const uint* entries [[buffer(0)]]";
  const st = "device uint* state [[buffer(1)]]";
  const o = "device uint* outb [[buffer(2)]]";
  const pr = `constant ${ns}::Params& params [[buffer(3)]]`;
  const id = "uint idx [[thread_position_in_grid]]";
  const k = (name: string, params: string[], call: string) =>
    `kernel void ${prefix}${name}(${params.join(", ")}) { ${ns}::${name}(${call}, idx); }`;
  return [
    "",
    `// The kernels (MetalScanner's names: "${prefix}" + decompress, ladder, finish, torsion, layout).`,
    k("decompress", [e, st, pr, id], "entries, state, params"),
    k("ladder", [st, pr, id], "state, params"),
    k("finish", [e, st, o, pr, id], "entries, state, outb, params"),
    k("torsion", [st, o, pr, id], "state, outb, params"),
    k("layout", [o, id], "outb"),
    "",
    "// This file's macros end here, so another .metal file can share the translation unit or the library.",
    ...["STATE_WORDS", "TABLE_POINT", "X_AT", "Y_AT", "Z_AT", "FLAGS_AT", "FLAG_VALID", "FLAG_IDENTITY", "FE_WORDS", "M", "PINV",
      ...Array.from({ length: 8 }, (_, j) => `P${j}`)].map((m) => `#undef ${m}`),
    "",
  ].join("\n");
}

/** Everything both fields share around the arithmetic: fpow, fsqrt_ratio and the helpers built on the primitives. */
function sharedField(): string {
  return /* metal */ `
inline bool feq(Fe a, Fe b) {
  bool same = true;
  for (uint i = 0u; i < FE_WORDS; i++) { if (a.l[i] != b.l[i]) { same = false; } }
  return same;
}
inline bool is_zero(Fe a) {
  uint any = 0u;
  for (uint i = 0u; i < FE_WORDS; i++) { any = any | a.l[i]; }
  return any == 0u;
}
inline bool is_one(Fe a) { return feq(a, cld(${SLOT.ONE}u)); }
inline Fe ld(device const uint* state, uint base) {
  Fe r = {};
  for (uint i = 0u; i < FE_WORDS; i++) { r.l[i] = state[base + i]; }
  return r;
}
inline void st(device uint* state, uint base, Fe v) {
  for (uint i = 0u; i < FE_WORDS; i++) { state[base + i] = v.l[i]; }
}
// which: 0 = p − 2 (inversion), 1 = (t − 1) / 2 (square root), by the steps of field.ts's powerSteps over a table of
// the odd powers a, a^3, …, a^15.
inline Fe fpow(Fe a, uint which) {
  Fe tbl[8];
  const Fe a2 = msqr(a);
  tbl[0] = a;
  for (uint i = 1u; i < 8u; i++) { tbl[i] = mmul(tbl[i - 1u], a2); }
  constant uint* steps = which == 1u ? STEPS_SQRT : STEPS_INV;
  const uint count = steps[0];
  Fe r = tbl[steps[1] & 255u];
  for (uint i = 1u; i < count; i++) {
    const uint step = steps[1u + i];
    const uint squarings = step >> 8u;
    for (uint k = 0u; k < squarings; k++) { r = msqr(r); }
    const uint entry = step & 255u;
    if (entry != 255u) { r = mmul(r, tbl[entry]); }
  }
  return r;
}
// A square root of num / den by Tonelli–Shanks, without the division (field.ts's fsqrt_ratio). For a non-residue the
// result is some x with x² · den different from num; the caller checks.
inline Fe fsqrt_ratio(Fe num, Fe den) {
  Fe d1 = den;
  Fe d2 = den;
  for (uint k = 0u; k < 31u; k++) { d1 = d2; d2 = mmul(msqr(d2), den); }
  const Fe y = mmul(num, d2);
  const Fe w = fpow(y, 1u);
  Fe x = mmul(mmul(w, num), d1);
  Fe b = mmul(y, msqr(w));
  Fe z = cld(${SLOT.ROOT}u);
  uint m = 32u;
  for (uint it = 0u; it < 33u; it++) {
    if (is_one(b)) { break; }
    uint i = 0u;
    Fe t = b;
    for (uint q = 0u; q < 32u; q++) { if (is_one(t)) { break; } t = msqr(t); i++; }
    if (i >= m) { break; }
    Fe c = z;
    const uint cnt = m - i - 1u;
    for (uint j = 0u; j < cnt; j++) { c = msqr(c); }
    x = mmul(x, c);
    z = msqr(c);
    b = mmul(b, z);
    m = i;
  }
  return x;
}
inline Fe to_mont(Fe a) { return mmul(a, cld(${SLOT.R2}u)); }
inline Fe from_mont(Fe a) { return mmul(a, cld(${SLOT.PLAIN_ONE}u)); }
`;
}

/** The power steps of field.ts's table (slots STEPS_INV and STEPS_SQRT, four slots each), as their own arrays. */
function stepsArrays(): string {
  const inv = table.subarray(SLOT.STEPS_INV * LIMBS, (SLOT.STEPS_INV + 4) * LIMBS);
  const sqrt = table.subarray(SLOT.STEPS_SQRT * LIMBS, (SLOT.STEPS_SQRT + 4) * LIMBS);
  const used = (a: Uint32Array) => a.subarray(0, a[0]! + 1);
  return [
    `// field.ts's powerSteps(p − 2) and powerSteps((t − 1) / 2): the step count, then (squarings << 8) | table index.`,
    `constant uint STEPS_INV[${used(inv).length}] = {\n${arrayLines(used(inv), 16, () => "")}\n};`,
    `constant uint STEPS_SQRT[${used(sqrt).length}] = {\n${arrayLines(used(sqrt), 16, () => "")}\n};`,
  ].join("\n");
}

/**
 * A whole file: everything but the kernels in namespace `ns`, so two variants (or other .metal files) can be linked
 * into one library without their helpers (`Fe`, `fadd`, …, all `inline`) being merged across files.
 */
function file(what: string, ns: string, prefix: string, body: string): string {
  return `// GENERATED by ios/metal/gen-metal.ts from gpu/field.ts and gpu/scan-wgsl.ts; do not edit.
// ${what}
#include <metal_stdlib>
using namespace metal;

namespace ${ns} {

// Eight little-endian 32-bit words (a 256-bit value).
struct W8 { uint w[8]; };
${body}
} // namespace ${ns}
${entryPoints(ns, prefix)}`;
}

// ---------------------------------------------------------------------------------------------------------------
// Field 1: 20 limbs of 13 bits, R = 2^260 (field.ts's), straight-line.
// ---------------------------------------------------------------------------------------------------------------

/** field.ts's unrolledArithmetic, in MSL: no loops and no indexed temporaries; locals initialized explicitly. */
function arithmetic13(): string {
  const p = limbs(P);
  // 2^260 − p: adding it to a value below 2p carries out of the top limb exactly when the value is at least p.
  const q = limbs((1n << 260n) - P);
  if (p[0] !== 1) throw new Error("the reduction rows are written for p = 1 mod 2^13");
  const out: string[] = [];
  const mp = (j: number): string => (p[j] === 0 ? "" : p[j] === 1 ? " + m" : ` + m * ${p[j]}u`);
  out.push("inline Fe fadd(Fe x, Fe y) {", "  Fe r = {};", "  Fe s = {};", "  uint c = 0u; uint e = 0u; uint v = 0u; uint w = 0u;");
  for (const j of range(LIMBS)) {
    out.push(`  v = x.l[${j}] + y.l[${j}]; w = v + ${q[j]}u + e; v = v + c; r.l[${j}] = v & M; c = v >> 13u; s.l[${j}] = w & M; e = w >> 13u;`);
  }
  out.push("  if (e != 0u) { return s; }", "  return r;", "}");
  out.push("inline Fe fsub(Fe x, Fe y) {", "  Fe r = {};", "  Fe s = {};", "  int c = 0; int e = 0; int v = 0; int w = 0;");
  for (const j of range(LIMBS)) {
    out.push(`  v = int(x.l[${j}]) - int(y.l[${j}]); w = v + ${p[j]} + e; v = v + c; r.l[${j}] = uint(v) & M; c = v >> 13; s.l[${j}] = uint(w) & M; e = w >> 13;`);
  }
  out.push("  if (c < 0) { return s; }", "  return r;", "}");
  out.push("inline Fe fneg(Fe a) { const Fe z = {}; return fsub(z, a); }");
  const reduced = (name: (j: number) => string): string[] => [
    "  uint c = 0u; uint e = 0u; uint v = 0u; uint w = 0u;",
    "  Fe r = {};",
    "  Fe s = {};",
    ...range(LIMBS).map((j) => `  w = ${name(j)} + ${q[j]}u + e; v = ${name(j)} + c; r.l[${j}] = v & M; c = v >> 13u; s.l[${j}] = w & M; e = w >> 13u;`),
    "  if (e != 0u) { return s; }",
    "  return r;",
  ];
  out.push("inline Fe mmul(Fe x, Fe y) {");
  for (const j of range(LIMBS)) out.push(`  const uint b${j} = y.l[${j}];`);
  for (const j of range(LIMBS)) out.push(`  uint t${j} = 0u;`);
  out.push("  uint ai = 0u; uint u = 0u; uint m = 0u;");
  for (const i of range(LIMBS)) {
    out.push(`  ai = x.l[${i}]; u = t0 + ai * b0; m = (0u - u) & M;`);
    out.push(`  t0 = t1 + ai * b1${mp(1)} + ((u + m) >> 13u);`);
    for (const j of range(LIMBS).slice(2)) out.push(`  t${j - 1} = t${j} + ai * b${j}${mp(j)};`);
    out.push(`  t${LIMBS - 1} = 0u;`);
  }
  out.push(...reduced((j) => `t${j}`), "}");
  out.push("inline Fe msqr(Fe x) {");
  for (const j of range(LIMBS)) out.push(`  const uint a${j} = x.l[${j}];`);
  for (const k of range(2 * LIMBS - 1)) {
    const pairs: string[] = [];
    for (let i = Math.max(0, k - LIMBS + 1); 2 * i < k; i++) pairs.push(`a${i} * a${k - i}`);
    const terms = [pairs.length > 0 ? `2u * (${pairs.join(" + ")})` : "", k % 2 === 0 ? `a${k / 2} * a${k / 2}` : ""];
    out.push(`  uint t${k} = ${terms.filter((e) => e !== "").join(" + ")};`);
  }
  out.push(`  uint t${2 * LIMBS - 1} = 0u;`, "  uint m = 0u;");
  for (const i of range(LIMBS)) {
    out.push(`  m = (0u - t${i}) & M;`);
    out.push(`  t${i + 1} += ((t${i} + m) >> 13u)${mp(1)};`);
    for (const j of range(LIMBS).slice(2)) if (mp(j) !== "") out.push(`  t${i + j} +=${mp(j).slice(2)};`);
  }
  out.push(...reduced((j) => `t${LIMBS + j}`), "}");
  return out.join("\n");
}

function field13(): string {
  const slotComment = (slot: number): string => {
    const names: Record<number, string> = {
      0: " // 0–203: Poseidon round constants",
      [SLOT.MDS]: " // MDS",
      [SLOT.P]: " // p, plain",
      [SLOT.R2]: " // R² mod p",
      [SLOT.ONE]: " // one (R mod p)",
      [SLOT.TWO]: " // 2",
      [SLOT.D]: " // d",
      [SLOT.D2]: " // 2d",
      [SLOT.ROOT]: " // root of unity",
      [SLOT.PLAIN_ONE]: " // 1, plain",
      [SLOT.STEPS_INV]: " // power steps (also in STEPS_INV / STEPS_SQRT)",
      [SLOT.SPARSE]: " // sparse partial rounds",
      [SLOT.PARTIAL_CONSTANT]: " // partial-round constants",
      [SLOT.LAST_PARTIAL]: " // round 63's matrix",
      [SLOT.AFTER_PARTIAL]: " // constants after round 63",
    };
    return names[slot] ?? "";
  };
  const p = limbs(P);
  return /* metal */ `
// A field element: 20 limbs of 13 bits, Montgomery form with R = 2^260 (gpu/field.ts).
struct Fe { uint l[20]; };
#define FE_WORDS 20u
#define M 8191u

// gpu/field.ts's constantTable: ${CONSTANT_SLOTS} slots of 20 limbs (slot k at 20·k; the layout is field.ts's module comment).
constant uint CONSTS[${CONSTANT_SLOTS * LIMBS}] = {
${arrayLines(table, LIMBS, slotComment)}
};
${stepsArrays()}

inline Fe cld(uint k) {
  Fe r = {};
  const uint b = k * 20u;
  for (uint i = 0u; i < 20u; i++) { r.l[i] = CONSTS[b + i]; }
  return r;
}
${arithmetic13()}
${sharedField()}
// Plain limbs of eight little-endian words (a value below 2^256).
inline Fe fe_of_words(W8 x) {
  Fe r = {};
  for (uint i = 0u; i < 20u; i++) {
    const uint pos = i * 13u;
    const uint wi = pos >> 5u;
    const uint sh = pos & 31u;
    uint v = x.w[wi] >> sh;
    if (sh > 19u && wi < 7u) { v = v | (x.w[wi + 1u] << (32u - sh)); }
    r.l[i] = v & M;
  }
  return r;
}
// Eight little-endian words of plain limbs (a value below 2^256).
inline W8 words_of_fe(Fe a) {
  W8 w = {};
  for (uint i = 0u; i < 20u; i++) {
    const uint pos = i * 13u;
    const uint wi = pos >> 5u;
    const uint sh = pos & 31u;
    w.w[wi] = w.w[wi] | (a.l[i] << sh);
    if (sh > 19u && wi < 7u) { w.w[wi + 1u] = w.w[wi + 1u] | (a.l[i] >> (32u - sh)); }
  }
  return w;
}
// The plain value of eight words (top bit clear) is at least p: field.ts's geq_p on the same limbs.
inline bool fe_geq_p(W8 x) {
  const Fe a = fe_of_words(x);
  for (int i = 19; i >= 0; i--) {
    const uint pv = CONSTS[${SLOT.P * LIMBS}u + uint(i)];
    if (a.l[i] > pv) { return true; }
    if (a.l[i] < pv) { return false; }
  }
  return true;
}
inline uint fe_low_bit(Fe a) { return a.l[0] & 1u; }
// p's limbs, for reference: ${p.join(", ")}
`;
}

// ---------------------------------------------------------------------------------------------------------------
// Field 2 (the variant): 8 limbs of 32 bits, R = 2^256, 64-bit limb products.
// ---------------------------------------------------------------------------------------------------------------

const R256 = mod(1n << 256n);
const R260 = mod(1n << 260n);
const inv = (a: bigint): bigint => {
  let r = 1n;
  let b = mod(a);
  let e = P - 2n;
  while (e > 0n) {
    if (e & 1n) r = (r * b) % P;
    b = (b * b) % P;
    e >>= 1n;
  }
  return r;
};
const fromLimbs = (l: ArrayLike<number>): bigint => {
  let v = 0n;
  for (let i = LIMBS - 1; i >= 0; i--) v = (v << 13n) | BigInt(l[i]!);
  return v;
};

/** field.ts's table converted slot by slot into the 32-bit field's Montgomery form (8 words a slot). */
function table32(): Uint32Array {
  const out = new Uint32Array(CONSTANT_SLOTS * 8);
  const rInv260 = inv(R260);
  const plain = new Set<number>([SLOT.P, SLOT.PLAIN_ONE]);
  const steps = new Set<number>(range(4).flatMap((k) => [SLOT.STEPS_INV + k, SLOT.STEPS_SQRT + k]));
  for (let slot = 0; slot < CONSTANT_SLOTS; slot++) {
    if (steps.has(slot)) continue; // held in STEPS_INV / STEPS_SQRT
    const v = fromLimbs(table.subarray(slot * LIMBS, (slot + 1) * LIMBS));
    let w: bigint;
    if (plain.has(slot)) w = v;
    else if (slot === SLOT.R2) w = mod(R256 * R256);
    else w = mod(mod(v * rInv260) * R256); // a Montgomery value: x·2^260 → x·2^256
    out.set(words(w), slot * 8);
  }
  // Checks of the conversion against the values field.ts documents.
  const at = (slot: number) => {
    let v = 0n;
    for (let i = 7; i >= 0; i--) v = (v << 32n) | BigInt(out[slot * 8 + i]!);
    return v;
  };
  if (at(SLOT.P) !== P || at(SLOT.ONE) !== R256 || at(SLOT.PLAIN_ONE) !== 1n || at(SLOT.TWO) !== mod(2n * R256)) {
    throw new Error("the 32-bit constant table's conversion is wrong");
  }
  return out;
}

/** How the 32-bit field forms a limb product and carries additions (see arithmetic32). */
interface Form32 {
  /** "ulong": `ulong(a) * ulong(b) + t + c` in one 64-bit expression; "mulhi": `a * b`, `mulhi(a, b)` and compares. */
  readonly products: "ulong" | "mulhi";
  /** "ulong": additions and subtractions carry through 64-bit sums; "compare": through 32-bit compares. */
  readonly carries: "ulong" | "compare";
}

/**
 * The 32-bit field's primitives. Montgomery product by CIOS over eight 32-bit limbs. A limb step t + a·b + c is either
 * one 64-bit expression (`ulong`, the default: the Metal compiler turns it into the GPU's 32 × 32 + 64-bit
 * multiply-adds) or the low half `a * b`, the high half `mulhi(a, b)` and carries from compares. p < 2^255, so with
 * a, b < p every intermediate fits in nine limbs (the top limb holds at most 1 bit) and one final subtraction of p
 * reduces it.
 */
function arithmetic32(form: Form32): string {
  const p = words(P);
  const out: string[] = [];
  // −p⁻¹ mod 2^32.
  let n0 = 1n;
  for (let i = 0; i < 6; i++) n0 = (n0 * (2n - BigInt(p[0]!) * n0)) & 0xffffffffn;
  const pinv = Number((1n << 32n) - n0);
  if (((BigInt(pinv) * BigInt(p[0]!)) & 0xffffffffn) !== 0xffffffffn) throw new Error("−p⁻¹ mod 2^32 is wrong");
  out.push(`#define PINV ${pinv}u`);
  out.push(...p.map((v, j) => `#define P${j} ${v >>> 0}u`));
  const wide = form.carries === "ulong";
  // src − p into red with a borrow; choose src when it borrowed.
  const subP = (src: (j: number) => string, top: string): string[] => [
    "  Fe red = {};",
    wide ? "  long d = 0;" : "  uint bw = 0u; uint d = 0u;",
    ...range(8).map((j) =>
      wide
        ? `  d = long(${src(j)}) - long(P${j}) + (d >> 32); red.l[${j}] = uint(d);`
        : `  d = ${src(j)} - P${j}; { const uint b1 = uint(${src(j)} < P${j}); red.l[${j}] = d - bw; bw = b1 | uint(d < bw); }`,
    ),
    `  if (${top} == 0u && ${wide ? "d < 0" : "bw != 0u"}) { Fe r = {}; ${range(8).map((j) => `r.l[${j}] = ${src(j)};`).join(" ")} return r; }`,
    "  return red;",
  ];
  out.push("inline Fe fadd(Fe x, Fe y) {");
  if (wide) {
    out.push("  ulong v = 0ul;");
    for (const j of range(8)) out.push(`  v = ulong(x.l[${j}]) + ulong(y.l[${j}]) + (v >> 32); const uint t${j} = uint(v);`);
    out.push("  const uint c = uint(v >> 32);");
  } else {
    out.push("  uint c = 0u; uint v = 0u;");
    for (const j of range(8)) out.push(`  v = x.l[${j}] + y.l[${j}]; const uint c${j} = uint(v < x.l[${j}]); const uint t${j} = v + c; c = c${j} | uint(t${j} < v);`);
  }
  out.push(...subP((j) => `t${j}`, "c"), "}");
  out.push("inline Fe fsub(Fe x, Fe y) {", "  Fe r = {};");
  if (wide) {
    out.push("  long d = 0;");
    for (const j of range(8)) out.push(`  d = long(x.l[${j}]) - long(y.l[${j}]) + (d >> 32); r.l[${j}] = uint(d);`);
    out.push("  if (d >= 0) { return r; }", "  ulong v = 0ul;");
    for (const j of range(8)) out.push(`  v = ulong(r.l[${j}]) + ulong(P${j}) + (v >> 32); r.l[${j}] = uint(v);`);
  } else {
    out.push("  uint bw = 0u; uint d = 0u;");
    for (const j of range(8)) out.push(`  d = x.l[${j}] - y.l[${j}]; { const uint b1 = uint(x.l[${j}] < y.l[${j}]); r.l[${j}] = d - bw; bw = b1 | uint(d < bw); }`);
    out.push("  if (bw == 0u) { return r; }", "  uint c = 0u; uint v = 0u;");
    for (const j of range(8)) out.push(`  v = r.l[${j}] + P${j}; { const uint c1 = uint(v < P${j}); r.l[${j}] = v + c; c = c1 | uint(r.l[${j}] < v); }`);
  }
  out.push("  return r;", "}");
  out.push("inline Fe fneg(Fe a) { const Fe z = {}; return fsub(z, a); }");
  // CIOS: for each limb a_i of x: t += a_i·y; m = t0·PINV; t += m·p; shift down one limb.
  out.push("inline Fe mmul(Fe x, Fe y) {");
  for (const j of range(8)) out.push(`  const uint y${j} = y.l[${j}];`);
  for (const j of range(10)) out.push(`  uint t${j} = 0u;`);
  out.push(form.products === "ulong" ? "  uint ai = 0u; uint c = 0u; uint m = 0u; uint s = 0u; ulong pr = 0ul;" : "  uint ai = 0u; uint lo = 0u; uint hi = 0u; uint c = 0u; uint m = 0u; uint s = 0u;");
  // t_j + a·b_j + c → (t_j, c): at most (2^32 − 1)² + 2·(2^32 − 1) = 2^64 − 1, so the 64-bit sum never overflows.
  const mac = (t: string, a: string, b: string): string =>
    form.products === "ulong"
      ? `pr = ulong(${a}) * ulong(${b}) + ulong(${t}) + ulong(c); ${t} = uint(pr); c = uint(pr >> 32);`
      : `lo = ${a} * ${b}; hi = mulhi(${a}, ${b}); s = ${t} + lo; hi += uint(s < lo); ${t} = s + c; hi += uint(${t} < s); c = hi;`;
  for (const i of range(8)) {
    out.push(`  ai = x.l[${i}]; c = 0u;`);
    for (const j of range(8)) out.push(`  ${mac(`t${j}`, "ai", `y${j}`)}`);
    out.push(`  s = t8 + c; t9 = uint(s < c); t8 = s;`);
    out.push(`  m = t0 * PINV; c = 0u;`);
    out.push(`  ${mac("t0", "m", "P0")}`);
    for (const j of range(8).slice(1)) out.push(`  ${mac(`t${j}`, "m", `P${j}`)} t${j - 1} = t${j};`);
    out.push(`  s = t8 + c; t7 = s; t8 = t9 + uint(s < c);`);
  }
  out.push(...subP((j) => `t${j}`, "t8"), "}");
  out.push("inline Fe msqr(Fe x) { return mmul(x, x); }");
  return out.join("\n");
}

function field32(form: Form32): string {
  const t32 = table32();
  return /* metal */ `
// A field element: 8 limbs of 32 bits, Montgomery form with R = 2^256 (the variant).
struct Fe { uint l[8]; };
#define FE_WORDS 8u

// gpu/field.ts's constantTable, slot by slot in this field's Montgomery form: ${CONSTANT_SLOTS} slots of 8 words (the
// power-step slots are unused here; they are STEPS_INV / STEPS_SQRT).
constant uint CONSTS[${CONSTANT_SLOTS * 8}] = {
${arrayLines(t32, 8, () => "")}
};
${stepsArrays()}

inline Fe cld(uint k) {
  Fe r = {};
  const uint b = k * 8u;
  for (uint i = 0u; i < 8u; i++) { r.l[i] = CONSTS[b + i]; }
  return r;
}
${arithmetic32(form)}
${sharedField()}
inline Fe fe_of_words(W8 x) { Fe r = {}; for (uint i = 0u; i < 8u; i++) { r.l[i] = x.w[i]; } return r; }
inline W8 words_of_fe(Fe a) { W8 w = {}; for (uint i = 0u; i < 8u; i++) { w.w[i] = a.l[i]; } return w; }
inline bool fe_geq_p(W8 x) {
  for (int i = 7; i >= 0; i--) {
    const uint pv = CONSTS[${SLOT.P * 8}u + uint(i)];
    if (x.w[i] > pv) { return true; }
    if (x.w[i] < pv) { return false; }
  }
  return true;
}
inline uint fe_low_bit(Fe a) { return a.l[0] & 1u; }
`;
}

// The variant's form: 64-bit products and compare carries (the fastest measured, ios/metal/README.md). Other forms,
// for measuring: node gen-metal.ts --w32 <products> <carries> <file> writes only that file.
const w32Arg = process.argv.indexOf("--w32");
const form: Form32 = { products: "ulong", carries: "compare" };
if (w32Arg >= 0) {
  const [products, carries, path] = process.argv.slice(w32Arg + 1);
  if ((products !== "ulong" && products !== "mulhi") || (carries !== "ulong" && carries !== "compare") || !path) {
    throw new Error("usage: node gen-metal.ts --w32 ulong|mulhi ulong|compare FILE");
  }
  const text = file(`Variant for measuring: 8 × 32-bit limbs, ${products} products, ${carries} carries.`, "pss_scan32", "pss_scan32_",
    field32({ products, carries }) + kernels(8));
  writeFileSync(path, text);
  console.log(`wrote ${path}: ${text.length} bytes`);
  process.exit(0);
}
const outDir = here("./generated/");
mkdirSync(outDir, { recursive: true });
const files: [string, string][] = [
  [
    "PssScan.metal",
    file("The ownership test (scan): gpu/scan-wgsl.ts in MSL, field of 20 × 13-bit limbs (gpu/field.ts).", "pss_scan13", "pss_scan_", field13() + kernels(LIMBS)),
  ],
  [
    "PssScanW32.metal",
    file("The ownership test (scan), variant: the same kernels over a field of 8 × 32-bit limbs, 64-bit products.", "pss_scan32", "pss_scan32_", field32(form) + kernels(8)),
  ],
];
for (const [name, text] of files) {
  writeFileSync(outDir + name, text);
  console.log(`wrote generated/${name}: ${text.length} bytes`);
}

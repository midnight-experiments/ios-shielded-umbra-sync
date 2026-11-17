# Metal scan

The ownership test (the scan) of `gpu/` ported from WebGPU to Metal for a native iOS app: MSL kernels generated from
the same sources as the WGSL ones, a Swift host (`MetalScanner`, iOS 17+ and macOS 14+), and a check that every
output is byte-equal to the CPU kernel's.

## Files

| File | What it holds |
|---|---|
| [gen-metal.ts](gen-metal.ts) | Writes `generated/`: the field and the four kernels in MSL, constants from `gpu/field.ts`'s `constantTable` |
| [generated/PssScan.metal](generated/PssScan.metal) | `gpu/scan-wgsl.ts` in MSL: same algorithm, same layout (381 state words per entry), 20 × 13-bit field |
| [generated/PssScanW32.metal](generated/PssScanW32.metal) | The variant: the same kernels over an 8 × 32-bit field with 64-bit (`ulong`) limb products, 153 state words per entry |
| [MetalScanner.swift](MetalScanner.swift) | The host: scalar recoding, chunks, dispatches, the candidate pass, timings |
| [check/](check/) | SwiftPM package: `PssMetal` (the scanner, linked from `../MetalScanner.swift`) and the `pss-metal-check` executable |
| [check/make-reference.ts](check/make-reference.ts) | The CPU side: inputs from `gpu/inputs.ts`, outputs and timings of the WASM kernel (`ScanPool`) |
| `results/` | The check's results files |

## Regenerate

```sh
cd examples/private-shielded-sync/ios/metal
node gen-metal.ts                                   # Node 24; writes generated/PssScan.metal and PssScanW32.metal
node gen-metal.ts --w32 mulhi compare /tmp/x.metal  # another form of the 32-bit field, for measuring (below)
```

The constant table has one source: `gen-metal.ts` imports `constantTable`, `SLOT`, `limbs` and `P` from
`gpu/field.ts` and the layout constants from `gpu/scan-wgsl.ts` (it stops if those change). The 13-bit file holds the
table as it is (595 slots × 20 words, a program-scope `constant uint` array of 47.6 KB); the 32-bit file holds the
same slots converted to its Montgomery form (R = 2^256), checked against p, R, 1 and 2 when generated.

Kernels: `pss_scan_decompress`, `pss_scan_ladder`, `pss_scan_finish`, `pss_scan_torsion` and `pss_scan_layout`
(`pss_scan32_…` in the variant). Buffers: 0 entries, 1 state, 2 outputs, 3 parameters (`setBytes`, 1,040 bytes: the
WGSL uniform's layout). Everything else sits in a namespace per file (`pss_scan13`, `pss_scan32`) and the macros are
`#undef`ed at the end of each file, so both files and the app's other `.metal` files can go into one library: the two
files plus `App/Metal/Multiply.metal` compiled as one source listed all eleven kernels and built the ten scan pipelines.

## Run the check

```sh
cd examples/private-shielded-sync/ios/metal/check
node make-reference.ts --out /tmp/pss-ref [--cpu-million]   # about 1 minute; --cpu-million adds about 90 s
swift run -c release pss-metal-check --ref /tmp/pss-ref               # the 13-bit kernels, about 30 s
swift run -c release pss-metal-check --ref /tmp/pss-ref --variant w32 # the variant
```

`make-reference.ts` builds the inputs of `gpu/check.ts` with `gpu/inputs.ts` (the 16,384 test vectors; the
70,000-entry set with subgroup points, points outside the subgroup, the identity, small-order points, undecodable
encodings, zero entries and forced 4-byte matches) and writes them with `ScanPool`'s values and hits (8 threads) and
the CPU timings. The check loads `../generated/PssScan.metal` (or `PssScanW32.metal`) at run time with
`device.makeLibrary(source:)` and:

1. compiles it, and once more with a salt in every kernel's bounds test (the time a first launch pays);
2. for both sets: one warm-up call, then three calls each of `scanValues` and `scan`, every value compared byte for
   byte and every hit list compared with the CPU's; the vectors' values and hits also with the ledger's (`pads.bin`,
   `mine.bin`);
3. 1,000,000 entries (the 70,000 set repeated; three calls each) and 2,000,000 (one call each), compared with the CPU's
   outputs repeated;
4. negative controls: one tag bit changed in a hit loses exactly that hit; one point byte changed changes exactly that
   entry's value;
5. refusals as the CPU kernel's: a 31-byte secret, the secret r and 2^256 − 1 (not canonical), 35 bytes of entries;
   no entries give no hits and no bytes; r − 1 is accepted;
6. writes `../results/check-<date>-<variant>.json` (unless `--quick`) and exits 1 if a check fails.

Options: `--variant w13|w32`, `--metal FILE`, `--chunk N`, `--digits N` (ladder digits per dispatch), `--tg N`
(threads per threadgroup), `--max-threads N` (the pipelines' `maxTotalThreadsPerThreadgroup`), `--quick` (the two sets
only), `--out FILE`.

## Results

[results/check-2026-11-15-w13.json](results/check-2026-11-15-w13.json),
[results/check-2026-11-15-w32.json](results/check-2026-11-15-w32.json): Apple M4 Max, macOS 15.7.3, Swift 6.2.3,
Node 24.9.0. The machine was shared (load average 8–11 during the Metal runs, up to 23 during the CPU reference).

Both variants pass all 20 checks: 16,384 + 70,000 + 1,000,000 + 2,000,000 entries' values byte-equal to the CPU's
(and the vectors' to the ledger's), every hit list equal (18, 82, 1,179 and 2,345 hits), both negative controls,
the five refusals. A run with 50-entry chunks, one 253-digit ladder dispatch and 32-thread threadgroups (1,400 chunks
for the 70,000 set, the candidate pass in two chunks) passes the same checks.

Scan, µs per entry: `scanValues`, best wall time of three calls (2,000,000: one call) and the least GPU execution time
(command buffers' `gpuEndTime − gpuStartTime`, summed). WebGPU: `gpu/README.md` (Deno 2.7.5, the same M4 Max). CPU:
`ScanPool`, 8 threads, best of three (1,000,000: one call, with the machine at load 23); one thread: 512 entries.

| Entries | Metal 13-bit wall | GPU | Metal 32-bit wall | GPU | WebGPU wall | GPU | CPU 8 threads | CPU one thread |
|---|---|---|---|---|---|---|---|---|
| 16,384 test vectors | 2.09 (34.3 ms) | 2.07 | 0.75 (12.2 ms) | 0.73 | 3.1 (51 ms) | 2.3 | 65.3 (1.07 s) | 516 |
| 70,000 edge cases | 1.97 (138 ms) | 1.95 | 0.72 (50.2 ms) | 0.71 | 2.8 (199 ms) | 2.2 | 64.3 (4.50 s) | 513 |
| 1,000,000 | 1.82 (1.82 s) | 1.80 | 0.66 (663 ms) | 0.65 | — | — | 87.6 (87.6 s) | — |
| 2,000,000 | 1.82 (3.64 s) | 1.81 | 0.66 (1.33 s) | 0.65 | — | — | — | — |

- Against the CPU on 8 threads (70,000 entries): 33× for the 13-bit kernels, 89× for the 32-bit ones.
- Against WebGPU, the same algorithm (13-bit): wall 1.42× (no ~12 ms floor per read-back, see below), GPU execution
  1.13×. Which part of the GPU's 11% comes from the MSL itself (constants in `constant` memory instead of a storage
  buffer, no WGSL bounds clamping) was not measured.
- `scan` costs the same as `scanValues` plus the candidate pass: 7.8–11.0 ms (13-bit) and 2.9–3.1 ms (32-bit) for 18 to
  2,345 candidates, about one entry's chain of products on one thread. That is also the least time any scan takes.
- The first call of a scanner (buffers allocated) took 69.5 ms for 16,384 entries against 34.3 ms after (13-bit).
- An earlier run of the 13-bit kernels with the machine at load 20 gave 2.29 µs per entry at 1,000,000; at load 6–11,
  1.80–1.82.

GPU time per phase, 1,000,000 entries (best `scanValues`):

| Phase | 13-bit | 32-bit |
|---|---|---|
| decompress | 299 ms (17%) | 121 ms (19%) |
| ladder, 7 dispatches a chunk | 883 ms (49%) | 313 ms (48%) |
| finish | 619 ms (34%) | 218 ms (33%) |
| longest command buffer | 21.1 ms | 7.2 ms |

## The variant: a 32-bit field

WGSL has no 64-bit integers and no high half of a 32-bit product, which is why `gpu/field.ts` uses 13-bit limbs (a
limb product fits 26 bits, sums of 40 fit 32). MSL has both `ulong` and `mulhi`. `PssScanW32.metal` keeps the kernels
and replaces the field: 8 limbs of 32 bits, Montgomery form with R = 2^256, products by CIOS (64 limb products and 64
reduction products, against the 13-bit field's 400 and 360), additions with carries, one conditional subtraction
of p. The squaring is the product (no separate squaring). The state is 153 words per entry (612 bytes, against 1,524).

Four forms of the same field, 70,000 entries, best wall, two alternating rounds with equal results (all byte-equal to
the CPU):

| Limb product | Carries of additions | µs per entry |
|---|---|---|
| `ulong(a) * ulong(b) + ulong(t) + ulong(c)` | 32-bit compares | **0.72** (generated) |
| `ulong` | 64-bit sums | 0.81 |
| `a * b`, `mulhi(a, b)`, carries by compares | 32-bit compares | 1.08 |
| `a * b`, `mulhi(a, b)`, carries by compares | 64-bit sums | 1.15 |

The single 64-bit expression is 1.5× faster than the same arithmetic spelled with `mulhi` and compares.

## The host

```swift
let device = MTLCreateSystemDefaultDevice()!
let library = device.makeDefaultLibrary()!                      // the app target compiles generated/*.metal into it
let scanner = try MetalScanner(device: device, library: library) // or options: .init(field: .limbs32)
let result = try scanner.scan(entries: entries, secret: secret)  // entries: Data (36 bytes each); secret: 32 bytes
result.positions                                                 // [Int], ascending
result.timings                                                   // wall, decompress, ladder, finish, torsion, gpu, chunks, …
let values = try scanner.scanValues(entries: entries, secret: secret) // Data, 32 bytes per entry
```

As `gpu/scan.ts`: the secret is recoded once into width-4 signed digits (a scalar not below r is refused before any GPU
work); each chunk runs `decompress`, the ladder in 7 dispatches of 37 digits, then `finish` (value and candidate
flag); the candidates of all chunks then run `decompress`, the ladder with r, and `torsion`. Each dispatch is its own
command buffer: no submission runs long, and each one's GPU time is attributed to its phase (`torsion` holds the whole
candidate pass). The calls of one scanner run one after another (a lock). The parameters' copy of the digits is
zeroed after each call; the state and output buffers keep the last chunk's points × secret and values until the next
call or `releaseBuffers()`.

### Chunk size: 32,768 entries

- GPU memory per chunk: 52.3 MB with the 13-bit field (state 1,524 bytes, entry 36, output 36 per entry), 22.4 MB with
  the 32-bit one. 2,000,000 entries run in 62 chunks of 32,259, through the same buffers.
- Speed does not depend on it here: 16,384 to 131,072 entries a chunk gave 1.97–2.05 µs per entry (70,000 entries,
  13-bit), within the noise of the shared machine; threadgroups of 32 to 256 threads and 19 to 253 digits per ladder
  dispatch likewise. Waiting for each chunk before the next costs under 1%: wall minus GPU time is 14 ms of 1,815 ms
  at 1,000,000 entries.
- The longest command buffer at this size is 21 ms (13-bit) and 7 ms (32-bit) on the M4 Max's 40-core GPU. A phone's
  GPU has fewer cores, so each takes longer there (not measured); `chunkEntries` and `digitsPerPass` shorten them.

## Metal findings

- **Compile time.** From source, uncached (salted): library 211 ms, pipelines 744 ms (13-bit); 78 ms and 251 ms
  (32-bit). Once Metal's cache holds them: 1 ms and 6 ms. An app that ships a compiled default library pays only the
  pipelines on its first launch. On this Mac, Xcode 26.2 cannot compile `.metal` files offline: `xcrun metal` fails
  with "missing Metal Toolchain" until `xcodebuild -downloadComponent MetalToolchain` is run; the check therefore
  compiles at run time, and so does the app (it bundles the sources as `.msl` text; see `../README.md`).
- **Pipeline limits.** All kernels of both files: `maxTotalThreadsPerThreadgroup` 1,024, `threadExecutionWidth` 32, no
  threadgroup memory. On the M4 (dynamic register allocation) that number does not show register pressure: setting the
  descriptor's `maxTotalThreadsPerThreadgroup` to 64 or 256 left the pipelines reporting 1,024 and the time unchanged.
  Register counts and occupancy were not read (Xcode's GPU profiler would show them).
- **Device limits (M4 Max).** `maxBufferLength` 28,991,029,248 bytes; `recommendedMaxWorkingSetSize` 38,654,705,664.
  The phone's values were not measured.
- **Differences from WGSL in the port.** MSL does not zero-initialize locals: every `Fe`/`W8` is initialized
  explicitly (WGSL's `words_of` relied on a zero array). Arrays cannot be returned, so a field element is
  `struct Fe { uint l[20]; }`. The constant table is a program-scope `constant` array, not a storage buffer. The
  uniform's `array<vec4<i32>, 64>` is `int digits[256]` (the same bytes; MSL has no 16-byte array stride in constant
  structs) and arrives through `setBytes`. Helpers take the state buffer as a pointer. `int >> 13` is an arithmetic
  shift, as in WGSL (the 13-bit `fsub` needs it).
- **Differences from WebGPU at run time.** No round-trip floor: a call's wall time is its GPU time plus under 1 ms
  (Deno's WebGPU answers every read-back after about 12 ms). Command buffers always carry GPU start and end times
  (Deno left short passes' timestamps unwritten). Buffers live in unified memory: the host writes entries into and
  reads outputs from `storageModeShared` buffers without staging copies; the state is `storageModePrivate`.
- **iOS, from Apple's documentation, not exercised here.** An app in the background cannot submit GPU work: its command
  buffers fail with `MTLCommandBufferError.notPermitted`, and `MetalScanner` throws `.gpu` with that error. A command
  buffer that runs too long is stopped (`.timeout`), hence one dispatch per command buffer and the chunk options.
  Unified memory means the chunk's buffers count toward the app's memory footprint.
- **Swift.** `MetalScanner.swift` type-checks against the iOS 26.2 SDK for `arm64-apple-ios17.0` and in Swift 6 language
  mode (no warnings).

## Not done

- No run on an iPhone: phone speed, `maxBufferLength`, the watchdog and the background refusal are not measured. The
  app's runs in the iOS Simulator are in `../README.md`; the Simulator runs on the Mac's GPU and does not refuse
  background GPU work.
- The machine was shared during every run (load average 6–23); numbers on an idle machine may be lower.
- The 32-bit field has no separate squaring (about 100 limb products instead of 128 per square); not tried.

# Native iOS client

The web step page of UmbraDB's private shielded sync as a native iOS app: the same steps, with the scan and the
client's PIR multiplications on the GPU through Metal, and the Midnight crypto from the ledger's own Rust crates. It
exists to measure what a phone can do and where it stops. Two tabs: **Wallet**, one button to add a key and then the
wallet as a user sees it, and **Details**, every step with its inputs, results and requests.

## Layout

| Folder | What it holds |
|---|---|
| `App/` | The app (SwiftUI): `Client/` the protocol (manifest, wire formats, records, SimplePIR, HTTP), `Wallet/` the steps, the wallet tab's key store and token names, and the Rust core's Swift face, `Views/` the two tabs, `Metal/Multiply.metal` |
| `metal/` | The scan (ownership test) ported from WGSL to Metal: generator, generated MSL, `MetalScanner.swift`, its byte-for-byte check (see `metal/README.md`) |
| `core/` | The Rust core as a static library for iOS (`PssCore.xcframework`): keys from a mnemonic, the scan kernel, decryption, commitments, nullifiers, Poseidon (see `core/`) |
| `check/` | A macOS check of `App/Client` against a live server: every PIR record equal to the TypeScript client's |
| `project.yml` | The Xcode project, generated with XcodeGen |
| `run-sim.sh` | Builds, installs and runs steps in the Simulator from the command line |
| `run-device.sh`, `lan-proxy.mjs` | The same on a connected iPhone, and the forwarder that lets it reach the server on this Mac |
| `icon/make-icon.swift` | Draws the app icon into `App/Assets.xcassets` |

## Build and run

```sh
core/build.sh                       # PssCore.xcframework (Rust 1.98.1 with the iOS targets)
xcodegen generate                   # PssSync.xcodeproj
open PssSync.xcodeproj              # or ./run-sim.sh
```

The script that writes the GPU scan code (`metal/gen-metal.ts`) and the two tests that compare the app with
UmbraDB's TypeScript client (the client check below, and the Metal check in `metal/README.md`) need code from UmbraDB's
private shielded sync example that this repository does not hold (`../gpu/`, `../client/`, `../pir/`, `../shared/`,
`../kernel/*.ts`), so they don't run on their own. The app doesn't need them: the GPU code the script writes is
committed (`metal/generated/`).

The server is the private shielded sync module's API (`umbradb run` with the module, port 10480 by default). The
Simulator reaches the Mac's `127.0.0.1`; a phone needs the server on an address it can reach: `node lan-proxy.mjs`
forwards the Mac's port 10482 on the local network to it while it runs. iOS asks once whether the app may use the
local network; until that is allowed, every request fails with "The Internet connection appears to be offline".

`./run-sim.sh [steps] [A|B|none]` runs the steps without touching the screen and prints each result; the mnemonic
comes from the environment file and is passed only to the app's environment. The step `wallet` runs the wallet tab's
sync with that mnemonic, without keeping it (`./run-sim.sh wallet A`).

## The wallet tab

With no key, the tab shows one button, **Add key**. It takes a BIP-39 mnemonic (12 to 24 words) or a 32-byte Zswap
seed in hex, derives the keys at once (a mistyped word is refused before anything is stored), keeps the key in the
Keychain (this device only, readable while it is unlocked) and syncs. The next launch opens the wallet from the
Keychain and syncs again; **Remove key** deletes it.

A sync is the Details tab's steps in order, each shown as a line with its time: derive the keys, download the public
snapshot, find the outputs (GPU scan), read the coins (one PIR call), check which are spent (one PIR call), catch up
with the chain (the tail). Their results also fill the Details tab. A later sync of the same snapshot (pull down,
**Sync now**, or coming back to the app after a minute) checks the manifest and runs only the tail. The screen then
shows the unspent balance by token, the coins (spent ones struck through, with their height), the shielded address
and what the server received in the last sync.

| Wallet A, Simulator, 1M slots | Time |
|---|---|
| First sync | 1.6 s: files 250 ms (93.6 MB over loopback), scan 733 ms, read 282 ms, nullifiers 167 ms, tail 23 ms |
| Later sync, same snapshot | 45 ms: manifest 9 ms, tail 10 ms |
| A new wallet with no coin | 1.2 s, sending the same two calls of 32 vectors |

Token names come from a table of the three Preprod test tokens (twETH, twUSDC, pssUSD); any other token type is shown
by its first bytes, in base units.

What the tab does not do yet:

- **Keep anything but the key.** The snapshot files and the coins found are held in memory, so each launch downloads
  the snapshot again (94 MB at 1M slots) and scans it. Kept on disk, a launch would fetch only the tail while the
  snapshot is unchanged.
- **Send.** A spend needs the coin's Merkle path, which the Details tab's step 6 reads by PIR (12.2 MB up per call);
  building and proving the transaction is not in the app.
- **Unshielded NIGHT and DUST.** Only shielded coins are shown.

## The client check

```sh
node check/read-reference.ts http://127.0.0.1:10480 /tmp/reference.json
swift run -c release pss-client-check http://127.0.0.1:10480 /tmp/reference.json
```

It reads positions of the read table, the path table and whole nullifier buckets with the CPU (all cores and one
thread) and the Metal multiplier, decoding with and without the padding vectors, and compares every record with the
TypeScript client's.

## Results, 2026-11-15

Measured on an iPhone 13 and, for comparison, in the iOS 26.3 Simulator (iPhone 17 Pro) on an Apple M4 Max (40-core
GPU, 16 CPU cores), which runs the app on the Mac's own GPU and CPU. The server was the module on a copy of a full
Preprod database, serving a snapshot at height 3,425,557 padded to 1,000,000 slots; the phone reached it over Wi-Fi
through `lan-proxy.mjs`.

### Correctness

- **Client:** `check/` read 7 read-table positions, 3 path records and 3 whole nullifier buckets with the CPU (16
  threads and 1 thread) and the Metal multiply, decoding with and without the padding vectors: every record equal to
  the TypeScript client's.
- **Rust core** (`core/`): keys from a mnemonic, nullifiers, commitments, leaves, Poseidon equal to the TypeScript
  client's packages (ledger-v9 1.0.1, wallet SDK HD) and to midnight-zswap 9.0.1's own key vectors; the scan,
  pads and decryption equal the kernel's fixtures.
- **Metal scan** (`metal/`): both kernels byte-equal to the CPU kernel on 16,384 + 70,000 + 1M + 2M entries, with the
  negative controls.
- **Wallet A in the Simulator and on the iPhone 13**, every step: the scan matched 10 positions; the read decrypted
  all 10; the nullifier lookups found the 3 spent ones (heights 2,793,447, 2,793,578, 3,399,948); the 6 lower paths
  read for a spend give block 0's root; the tail's root check passes. Unspent balances 5.3 twETH, 4,219.81 twUSDC
  and 3,850 pssUSD, as the command-line client found on the same database.

### The iPhone 13

iPhone14,5, iOS 27.0.1: A15 GPU (4 cores), 6 CPU cores (2 performance), 3.66 GB of memory, of which the app may use
2.08 GB (`os_proc_available_memory`). Metal reports a 2 GB `maxBufferLength`, a 2.73 GB recommended working set,
32 KB of threadgroup memory, 1,024 threads per group, GPU families apple6 to apple8 and metal3. The Metal sources
compile in 149, 278 and 127 ms at the first launch. Wallet A's sync found the same 10 coins and balances as in the
Simulator.

| Step, 1M slots | iPhone 13 | Simulator | Detail on the phone |
|---|---|---|---|
| Files | 2.4 s | 0.15–0.23 s | 94 MB over Wi-Fi; the scan file's 34.3 MB in 807 ms |
| Scan, Metal 32-bit limbs | 11.1 s | 0.69–0.73 s | 11.1 µs per entry; GPU time 10.9 s: decompress 2.0 s, ladder 5.2 s, finish 3.7 s |
| Read 10 positions | 421 ms | 336 ms | build 32 ms (AES 11, A·s 7, error 14), round trip 378 ms, decode 8 ms |
| Nullifiers, 10 lookups | 208 ms | 248 ms | build 30 ms, round trip 168 ms, decode 8 ms |
| Paths for a spend, 6 positions | 1.85 s | 0.86–1.17 s | path setup 17.8 MB in 469 ms; build 211 ms (AES 56, A·s 65, error 85), round trip 1,150 ms with 12.2 MB up, decode 13 ms |
| Tail | 20 ms | 5 ms | |
| Wallet tab, files already on the phone | 11.8 s | 1.0 s | the scan is 11.1 s of it |

Scan at larger sizes on the phone (the scan file's entries repeated):

| Entries | Metal, 32-bit limbs | Metal, WGSL port |
|---|---|---|
| 100k | 1.1 s (11.1 µs per entry) | 2.3 s (23.4 µs per entry) |
| 1M | 12.5 s (12.5 µs per entry) | failed: "Impacting Interactivity" |
| 2M | 42.6 s wall, 24.3 s of GPU time | failed: "Impacting Interactivity" |

The client's PIR work on the phone (random matrices of the real shapes, as in the Simulator table below):

| Outputs | Build, GPU / CPU | Decode 10 vectors, GPU / CPU | Memory left after |
|---|---|---|---|
| 1M | 29 / 59 ms | 7 / 7 ms | 1.95 GB |
| 10M | 265 / 69 ms | 65 / 8 ms | 1.80 GB |
| 100M | 177 / 193 ms | 84 / 110 ms | 1.39 GB |

The 10M GPU build spent 217 ms in A·s once, against 65 ms at 100M; one run, so take that row's GPU numbers as noisy.

### One sync in the Simulator (1M slots)

| Step | Time | Detail |
|---|---|---|
| Keys | 1–3 ms | BIP-39, BIP32, Zswap keys in Rust |
| Files | 150–230 ms | manifest and 94 MB over loopback: scan file 34.3 MB, read setup 36.8 MB, nullifier setup 22.5 MB |
| Scan, Metal 32-bit limbs | 687–731 ms | 0.69–0.73 µs per entry |
| Scan, Metal WGSL port | 1,904 ms | 1.90 µs per entry |
| Read 10 positions (5 columns) | 336 ms | build 14 ms (AES 4, A·s 4, error 6), round trip 318 ms, decode 3 ms; 1.1 MB each way |
| Nullifiers, 10 lookups | 248 ms | build 12 ms, round trip 233 ms, decode 2 ms; 1.0 MB up, 0.7 MB down |
| Paths for a spend, 6 positions | 863–1,174 ms | path setup 17.8 MB once; build 110 ms (AES 26, A·s 23, error 59), round trip 701 ms, decode 3 ms; 12.2 MB up |
| Tail | 5 ms | 17 outputs and 10 nullifiers since the snapshot |

### The client's PIR work at larger sizes (Simulator)

The read table of N outputs (98-byte records), one call of 32 vectors; random matrices of the real shapes.

| Outputs | Read table | Setup data H | One call, up / down | Build, GPU / CPU | Decode 10 vectors, GPU / CPU |
|---|---|---|---|---|---|
| 1M | 9,416 × 9,346 | 36.8 MB | 1.1 / 1.1 MB | 13 / 12 ms | 2 / 1 ms |
| 10M | 29,656 × 29,674 | 115.8 MB | 3.6 / 3.6 MB | 34 / 32 ms | 6 / 2 ms |
| 100M | 93,808 × 93,809 | 366.4 MB | 11.5 / 11.5 MB | 109 / 101 ms | 25 / 9 ms |

At 100M the build's 109 ms is the Gaussian error (57 ms for 3 million samples), AES for A (25 ms for 366 MB) and
A·s (25 ms). Scan at larger sizes (Metal, 32-bit / WGSL port): 100k entries 98 / 204 ms, 1M 687 / 1,904 ms, 2M
1,395 / 3,774 ms.

## Limits found

1. **The scan is what a phone pays for.** On the iPhone 13's GPU the scan costs 11.1 µs per output, 16 times the M4
   Max: 11 s for 1M outputs, so about 2 minutes for 10M and 18 minutes for 100M if the rate held (it did not hold at
   2M, see 3). Everything else in a sync is under half a second at 1M.
2. **Decoding does not need the GPU.** On the phone, decoding 10 vectors of a 100M-output table takes 84 ms on the
   GPU and 110 ms on the CPU, and building a call 177 and 193 ms; at 1M both are under 60 ms. Building is mostly the
   Gaussian error and AES, which run on the CPU.
3. **iOS stops long GPU work while the app is on screen.** Command buffers that hold the GPU too long fail with
   "Impacting Interactivity" (`kIOGPUCommandBufferCallbackErrorImpactingInteractivity`). The WGSL port's scan, whose
   command buffers ran up to 193 ms, failed at 1M and 2M entries; the 32-bit kernel's, up to 148–262 ms, passed, so
   the cut is not at a fixed length. At 2M the 32-bit scan took 42.6 s of wall time for 24.3 s of GPU time, gaps
   between command buffers that are not explained (the thermal state was not recorded). A scan on a phone has to
   keep each command buffer short; the scanner's passes per chunk (`digitsPerPass`, `chunkEntries`) set that length.
4. **Metal allows a faster scan than WebGPU.** WGSL has no 64-bit integers, so the WebGPU field uses 20 limbs of 13
   bits. Metal's 64-bit products allow 8 limbs of 32 bits: 2.1 times faster on the phone (11.1 against 23.4 µs per
   entry), 2.7 times on the Mac, with 612 instead of 1,524 bytes of GPU state per entry.
5. **No GPU in the background.** On the phone, about a second after the app leaves the screen, every new command
   buffer fails with "Insufficient Permission (to submit GPU work from background)"
   (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`), for the scan and the PIR multiply alike. A
   scan already running as the app left finished (50,000 entries in 1.0 s); the next ones failed at once, inside a
   `beginBackgroundTask` that still had time. The Simulator does not enforce this. So a wallet scans on the GPU only
   while it is open; a background sync would have to scan on the CPU, or leave the scan for the next time the app
   is opened.
6. **Memory.** The app may use 2.08 GB on the iPhone 13; a 1M sync leaves 1.70 GB, and the 100M PIR benchmark left
   1.39 GB. The app holds the scan file and the setup data in memory: at 100M outputs the scan file alone is 3.6 GB
   and the read setup 366 MB, so the download, its digest and the scan would have to stream in chunks (the scanner
   already works in chunks of 32,768 entries).
7. **Buffer size.** The phone's GPU takes buffers up to 2 GB. The Simulator reports 256 MB (and 16 KB of threadgroup
   memory, 512 threads per group, no GPU family); the Metal multiply splits a matrix it cannot place in one buffer
   into slices of rows.
8. **Shader compilation.** This Xcode has no Metal Toolchain, so the app compiles its Metal sources at launch: 149,
   278 and 127 ms on the phone, 626, 242 and 100 ms in the Simulator, cached by Metal after the first launch. A build
   with the toolchain (`xcodebuild -downloadComponent MetalToolchain`) would ship them compiled.
9. **The Simulator's GPU timestamps are wrong.** It reports command-buffer GPU times far below the wall time (16 ms
   for a 687 ms scan); on the phone and on macOS the two agree.
10. **Upload for a spend.** The path table is as wide as the noise check allows (100,000 columns), so reading a path
    uploads 12.2 MB, and its A is 410 MB of AES output per call: a 1.15 s round trip over Wi-Fi on the phone, longer
    on a mobile network.

## Decisions made on the way

- **Metal at launch.** The Metal sources are compiled at launch rather than downloading the Metal Toolchain (a large
  download); the cost is measured above.
- **Default scan kernel.** The 32-bit kernel; the WGSL port stays selectable for comparison.
- **Padding vectors.** Decoding skips them by default, which the server cannot see; a switch restores the TypeScript
  client's behaviour.
- **Rust targets.** The core adds the iOS targets to the Rust 1.98.1 toolchain with rustup.
- **The wallet's key in the Keychain**, `WhenUnlockedThisDeviceOnly`: not in backups, not synced. The Details tab's
  key fields are hidden fields, since the wallet fills them.
- **Calls with no real vector.** A wallet with no coin still sends its read and nullifier calls; with the padding not
  decoded there is nothing to multiply, and both multipliers now return at once (Metal refused a buffer of length 0;
  the CPU path read an empty array's pointer).
- **Remove key at any time.** It deletes the Keychain item and clears the screen at once; a sync in progress stops
  after its current step, and the keys leave memory when that step ends. A sync started while a Details step runs
  waits for it, and the Wallet tab shows which step runs.
- **The icon** is drawn with Core Graphics (a shield over a table with one record lit), not from SF Symbols, whose
  license excludes app icons.
- **No x86_64 Simulator slice.** Build for a concrete Apple-silicon Simulator; a generic Simulator build would try
  x86_64.

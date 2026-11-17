# ios-shielded-umbra-sync

A native iOS client for UmbraDB's private shielded sync. A wallet finds its shielded coins without telling the server
which ones are its: it downloads the same snapshot files as every other wallet, scans them on the phone's GPU for the
outputs encrypted to its key, and reads its coins and whether they are spent by private information retrieval
(SimplePIR). The app measures each step on an iPhone and shows where a phone stops.

## Contents

| Folder | What it holds |
|---|---|
| `ios/` | The app (SwiftUI, Metal, a Rust core), its scripts and the measurements: start with [ios/README.md](ios/README.md) |
| `kernel/` | The Rust scan kernel the app's core links (`pss-kernel`, crates.io dependencies only) |
| `test/fixtures/` | Scan and coin vectors made with the ledger's `encrypt` from a fixed seed, for the core's tests |

Not in this repository: the server, a module of UmbraDB that serves the snapshot files and answers the PIR calls
under `/pss/v1`, and the TypeScript of UmbraDB's private shielded sync example that the Metal generator and the two
checks import ([ios/README.md](ios/README.md#build-and-run) lists them).

## On an iPhone 13

One wallet with 10 coins, a snapshot of 1,000,000 outputs, over Wi-Fi:

| Step | Time |
|---|---|
| Download the snapshot files (94 MB) | 2.4 s |
| Find the wallet's outputs (GPU scan) | 11.1 s, 11.1 µs per output |
| Read the coins (one PIR call) | 421 ms |
| Check which are spent (one PIR call) | 208 ms |
| Catch up with the chain | 20 ms |

- The scan is the only step that grows with the chain. Each output costs a key exchange with the wallet's key, about
  4,600 multiplications of 256-bit numbers; the iPhone 13's 4-core GPU runs it 16 times slower than an M4 Max.
- iOS cancels long GPU command buffers while the app is on screen ("Impacting Interactivity"), so the scanner keeps
  each one short.
- iOS refuses GPU work about a second after the app leaves the screen: the scan runs only while the app is open.

The full results and limits are in [ios/README.md](ios/README.md#results-2026-11-15).

## Build

```sh
cd ios
core/build.sh            # PssCore.xcframework (Rust with the iOS targets)
xcodegen generate        # PssSync.xcodeproj
open PssSync.xcodeproj   # or ./run-sim.sh
```

## License

Apache-2.0 ([LICENSE](LICENSE)).

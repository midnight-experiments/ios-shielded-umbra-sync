#!/usr/bin/env bash
# Builds the native core (`pss-ios-core`) for the iOS app and packages it as build/PssCore.xcframework.
#
#   ./build.sh          release static libraries for aarch64-apple-ios (device), aarch64-apple-ios-sim (simulator on
#                       Apple silicon) and aarch64-apple-darwin (macOS), then build/PssCore.xcframework
#   ./build.sh --test   the crate's tests on this Mac (`cargo test`: TypeScript vectors, zswap vectors, kernel fixtures)
#
# Needs Xcode (built with 26.2) and the Rust toolchain 1.98.1; the two iOS targets are added to it with rustup if
# missing. The C library blst (BLS12-381, under midnight-curves) is compiled by the `cc` crate with Xcode's clang for
# each SDK, its aarch64 assembly included; nothing else is needed for it. midnight-base-crypto also pulls in reqwest
# with rustls and aws-lc-rs, whose C (aws-lc) the `cc` crate compiles too; none of it is reachable from the API, so
# it never reaches the packaged library.
#
# Each slice is one prelinked object (`ld -r`) that exports only the functions of include/pss_core.h: the Rust
# standard library, the kernel's own WebAssembly exports (`scan`, `alloc`, …) and blst stay internal, so the library
# links beside other static libraries, other Rust ones included, without duplicate symbols. The app links nothing
# beyond libSystem.
#
# IPHONEOS_DEPLOYMENT_TARGET (default 15.0) and MACOSX_DEPLOYMENT_TARGET (default 12.0) set the minimum versions.
set -euo pipefail

TOOLCHAIN=1.98.1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/build"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

cd "$HERE"

if [[ "${1:-}" == "--test" ]]; then
  shift
  exec cargo "+$TOOLCHAIN" test --locked "$@"
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--test [cargo test args]]" >&2
  exit 2
fi

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
installed="$(rustup "+$TOOLCHAIN" target list --installed)"
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  grep -qx "$target" <<<"$installed" || rustup target add --toolchain "$TOOLCHAIN" "$target"
done

# Keep this machine's paths out of the library (panic locations): crates, the toolchain's sources, this example.
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
SYSROOT="$(rustc "+$TOOLCHAIN" --print sysroot)"
export RUSTFLAGS="--remap-path-prefix=$CARGO_HOME/registry/src=/crates --remap-path-prefix=$SYSROOT=/rust --remap-path-prefix=$EXAMPLE=/private-shielded-sync"
CFLAGS_REMAP="-ffile-prefix-map=$CARGO_HOME/registry/src=/crates"
export CFLAGS_aarch64_apple_ios="$CFLAGS_REMAP" CFLAGS_aarch64_apple_ios_sim="$CFLAGS_REMAP" CFLAGS_aarch64_apple_darwin="$CFLAGS_REMAP"

# The exported symbols: every function the header declares.
SYMBOLS="$BUILD/exported-symbols.txt"
mkdir -p "$BUILD"
grep -oE '\bpss_[a-z0-9_]+\(' include/pss_core.h | tr -d '(' | sort -u | sed 's/^/_/' > "$SYMBOLS"
UNDEFINED=()
while read -r symbol; do UNDEFINED+=(-u "$symbol"); done < "$SYMBOLS"

# slice name, ld platform, minimum version, SDK
slice() {
  case "$1" in
    aarch64-apple-ios) echo "ios-arm64 ios $IPHONEOS_DEPLOYMENT_TARGET iphoneos" ;;
    aarch64-apple-ios-sim) echo "ios-arm64-simulator ios-simulator $IPHONEOS_DEPLOYMENT_TARGET iphonesimulator" ;;
    aarch64-apple-darwin) echo "macos-arm64 macos $MACOSX_DEPLOYMENT_TARGET macosx" ;;
  esac
}

LIBRARIES=()
for target in "${TARGETS[@]}"; do
  read -r name platform minimum sdk <<<"$(slice "$target")"
  cargo "+$TOOLCHAIN" build --locked --release --lib --target "$target"
  raw="target/$target/release/libpss_ios_core.a"
  out="$BUILD/$name"
  rm -rf "$out"
  mkdir -p "$out"
  # Pull from the archive only what the exported functions reach (blst included), as one object exporting only them.
  xcrun ld -r -arch arm64 -platform_version "$platform" "$minimum" "$(xcrun --sdk "$sdk" --show-sdk-version)" \
    "${UNDEFINED[@]}" -exported_symbols_list "$SYMBOLS" -o "$out/pss_core.o" "$raw"
  exported="$(nm -gU "$out/pss_core.o" | awk '{print $3}' | sort)"
  if [[ "$exported" != "$(cat "$SYMBOLS")" ]]; then
    echo "$target: the object exports something other than the header's functions:" >&2
    echo "$exported" >&2
    exit 1
  fi
  xcrun libtool -static -no_warning_for_no_symbols -o "$out/libpss_core.a" "$out/pss_core.o"
  rm "$out/pss_core.o"
  LIBRARIES+=(-library "$out/libpss_core.a" -headers "$BUILD/headers")
done

# Headers in a PssCore folder, so the module map does not collide with other libraries' in an app's include folder.
rm -rf "$BUILD/headers" "$BUILD/PssCore.xcframework"
mkdir -p "$BUILD/headers/PssCore"
cp include/pss_core.h include/module.modulemap "$BUILD/headers/PssCore/"
xcodebuild -create-xcframework "${LIBRARIES[@]}" -output "$BUILD/PssCore.xcframework" >/dev/null

echo "built $BUILD/PssCore.xcframework"
for target in "${TARGETS[@]}"; do
  read -r name _ <<<"$(slice "$target")"
  raw="target/$target/release/libpss_ios_core.a"
  packaged="$BUILD/PssCore.xcframework/$name/libpss_core.a"
  printf '  %-20s %9s bytes (cargo staticlib %s bytes)\n' "$name" "$(wc -c < "$packaged" | tr -d ' ')" "$(wc -c < "$raw" | tr -d ' ')"
done

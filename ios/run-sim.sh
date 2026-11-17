#!/usr/bin/env bash
# Builds the app for the iOS Simulator, installs it on a booted simulator and runs steps without touching the screen.
#
#   ./run-sim.sh [steps] [wallet]     steps: comma-separated (default device,keys,files,scan,read,nullifiers,paths,tail,summary);
#                                     "wallet" runs the wallet tab's sync with the wallet's key, without keeping it
#                                     wallet: A or B (a mnemonic from PSS_ENV_FILE), or none
#
# Environment: PSS_SIM_DEVICE (simulator name or UDID, default: the booted one), PSS_SERVER (default
# http://127.0.0.1:10480; the Simulator shares the Mac's network), PSS_ENV_FILE (file defining PSS_MNEMONIC_A/B;
# default ios/secrets.env, which git ignores), PSS_NO_BUILD=1 (reuse the last build), PSS_BACKGROUND_TEST=1. The
# mnemonic goes to the app's environment only; it is never printed. The app writes each step's result to the log with
# the prefix [pss]; this prints those lines.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
STEPS="${1:-device,keys,files,scan,read,nullifiers,paths,tail,summary}"
WALLET="${2:-A}"
DEVICE="${PSS_SIM_DEVICE:-booted}"
BUNDLE=local.umbradb.pss-sync
DD="$HERE/build/dd"

if [[ "${PSS_NO_BUILD:-0}" != 1 ]]; then
  xcodegen generate --spec project.yml --quiet
  UDID="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=[x for r in json.load(sys.stdin)["devices"].values() for x in r]; print(d[0]["udid"] if d else "")')"
  [[ "$DEVICE" != booted ]] && UDID="$DEVICE"
  [[ -n "$UDID" ]] || { echo "no booted simulator" >&2; exit 1; }
  xcodebuild -project PssSync.xcodeproj -scheme PssSync -configuration Release -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" -quiet build
fi
xcrun simctl install "$DEVICE" "$DD/Build/Products/Release-iphonesimulator/PssSync.app"

export SIMCTL_CHILD_PSS_AUTORUN="$STEPS"
export SIMCTL_CHILD_PSS_SERVER="${PSS_SERVER:-http://127.0.0.1:10480}"
export SIMCTL_CHILD_PSS_BACKGROUND_TEST="${PSS_BACKGROUND_TEST:-0}"
if [[ "$WALLET" == A || "$WALLET" == B ]]; then
  ENV_FILE="${PSS_ENV_FILE:-$HERE/secrets.env}"
  set -a; . "$ENV_FILE"; set +a
  var="PSS_MNEMONIC_$WALLET"
  export SIMCTL_CHILD_PSS_MNEMONIC="${!var}"
fi
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
xcrun simctl launch --terminate-running-process --console-pty "$DEVICE" "$BUNDLE" >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 1800); do
  if grep -q "\[pss\] autorun finished" "$LOG"; then break; fi
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1
done
kill "$PID" 2>/dev/null || true
grep -o "\[pss\].*" "$LOG" | grep -v "autorun finished" || cat "$LOG"

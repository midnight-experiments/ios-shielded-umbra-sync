#!/usr/bin/env bash
# Builds, installs and runs the app on a connected iPhone, printing each step's result (as run-sim.sh does).
#
#   DEVELOPMENT_TEAM=<team id> PSS_SERVER=http://<this Mac's LAN address>:10482 ./run-device.sh [steps] [A|B|none]
#   (PSS_NO_BUILD=1 installs the last build)
#
# Needs: the phone connected and trusted (`xcrun devicectl list devices` shows it "available"), Developer Mode on, and
# an Xcode account for the team so automatic signing can make a profile. The phone cannot reach the module's API on
# the Mac's 127.0.0.1: run `node lan-proxy.mjs` (forwards the Mac's LAN port 10482 to 127.0.0.1:10480) and pass the
# Mac's LAN address. The mnemonic reaches the app as a launch environment variable; it is never printed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
STEPS="${1:-device,keys,files,scan,read,nullifiers,paths,tail,summary,wallet,benchScan,benchPir}"
WALLET="${2:-A}"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the signing team id}"
: "${PSS_SERVER:?set PSS_SERVER to an address the phone can reach, e.g. http://192.168.1.10:10482}"
DEVICE="${PSS_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep -E '(available|connected).*iPhone' | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)}"
[[ -n "$DEVICE" ]] || { echo "no available iPhone (xcrun devicectl list devices)" >&2; exit 1; }
DD="$HERE/build/dd-device"
BUNDLE=local.umbradb.pss-sync

if [[ "${PSS_NO_BUILD:-0}" != 1 ]]; then
  xcodegen generate --spec project.yml --quiet
  # A generic destination: xcodebuild does not take devicectl's CoreDevice identifiers.
  xcodebuild -project PssSync.xcodeproj -scheme PssSync -configuration Release -sdk iphoneos -destination "generic/platform=iOS" \
    -derivedDataPath "$DD" -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -quiet build
fi
xcrun devicectl device install app --device "$DEVICE" "$DD/Build/Products/Release-iphoneos/PssSync.app" >/dev/null

ENVJSON="$(
  if [[ "$WALLET" == A || "$WALLET" == B ]]; then
    set -a; . "${PSS_ENV_FILE:-$HERE/secrets.env}"; set +a
    export PSS_LAUNCH_MNEMONIC_VAR="PSS_MNEMONIC_$WALLET"
  fi
  PSS_AUTORUN="$STEPS" PSS_SERVER_URL="$PSS_SERVER" python3 -c '
import json, os
env = {"PSS_AUTORUN": os.environ["PSS_AUTORUN"], "PSS_SERVER": os.environ["PSS_SERVER_URL"],
       "PSS_BACKGROUND_TEST": os.environ.get("PSS_BACKGROUND_TEST", "0")}
var = os.environ.get("PSS_LAUNCH_MNEMONIC_VAR")
if var: env["PSS_MNEMONIC"] = os.environ[var]
print(json.dumps(env))'
)"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console \
  --environment-variables "$ENVJSON" "$BUNDLE" >"$LOG" 2>&1 &
PID=$!
unset ENVJSON
for _ in $(seq 1 3600); do
  if grep -q "\[pss\] autorun finished" "$LOG"; then break; fi
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1
done
grep -o "\[pss\].*" "$LOG" | grep -v "autorun finished" || cat "$LOG"
echo "(the app keeps running on the phone: leave it with the Home gesture to try the background test, if it was on)"

#!/bin/bash
# Builds Enka for a physical iPhone and installs it over the cable.
#
# Separate from `make ios`, which targets the simulator, because a device build
# has two requirements a simulator build does not: a real signing identity, and
# a phone that has agreed to run development builds. Both fail in ways whose
# error text does not say what to do, so most of this file is saying it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
PROJECT="$ROOT/Enka.xcodeproj"
DD="$ROOT/build-device"
APP="$DD/Build/Products/Debug-iphoneos/Enka.app"
BUNDLE="com.enka.ios"

# ---------------------------------------------------------------- team -----
# The ten-character Apple Developer team id that signs the build. From the
# environment if it is there and from .env otherwise, the way the Mac app's
# signing identity is, so it is set once and forgotten.
TEAM="${IOS_DEVELOPMENT_TEAM:-$(grep -E '^IOS_DEVELOPMENT_TEAM=' "$REPO/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'')}"
if [ -z "$TEAM" ]; then
    echo "!!! no signing team." >&2
    echo "    Put IOS_DEVELOPMENT_TEAM=<team id> in .env. The teams this Mac can" >&2
    echo "    sign with are the ones in the profiles it already holds:" >&2
    for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
        [ -e "$p" ] || continue
        security cms -D -i "$p" 2>/dev/null | plutil -extract TeamIdentifier.0 raw - 2>/dev/null
    done | sort -u | sed 's/^/      /' >&2
    exit 1
fi

# -------------------------------------------------------------- device -----
# The cable, not the network. A device on Wi-Fi is listed too and installs to
# it work, but "install on the phone in front of me" is what this is for, and
# picking the wired one makes that unambiguous when both are the same phone.
UDID="${DEVICE:-}"
if [ -z "$UDID" ]; then
    JSON="$(mktemp)"
    trap 'rm -f "$JSON"' EXIT
    xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
    UDID="$(python3 - "$JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
wired = [d for d in devices
         if d.get("connectionProperties", {}).get("transportType") == "wired"]
if wired:
    print(wired[0]["hardwareProperties"]["udid"])
PY
)"
fi
if [ -z "$UDID" ]; then
    echo "!!! no iPhone on the cable." >&2
    echo "    Plug one in and unlock it. If it is plugged in already, it may be" >&2
    echo "    waiting for you to tap Trust:  xcrun devicectl list devices" >&2
    echo "    Or name one yourself:  make ios-device DEVICE=<udid>" >&2
    exit 1
fi

echo "==> building for $UDID, team $TEAM"
xcodebuild -quiet -project "$PROJECT" -scheme Enka -configuration Debug \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DD" \
    DEVELOPMENT_TEAM="$TEAM" \
    -allowProvisioningUpdates \
    build

echo "==> installing"
# The failure worth explaining. Developer Mode is off on a phone that has never
# run a development build, the toggle only appears once one has been attempted,
# and turning it on needs a restart — so the first run of this script fails
# here by design, and the second one works.
if ! xcrun devicectl device install app --device "$UDID" "$APP"; then
    echo >&2
    echo "    If that said Developer Mode is disabled: on the phone, Settings →" >&2
    echo "    Privacy & Security → Developer Mode → on, restart it, then confirm" >&2
    echo "    after it comes back. Run this again afterwards." >&2
    exit 1
fi

echo "==> launching"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null
echo "==> done — Enka is on the phone."

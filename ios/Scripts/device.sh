#!/bin/bash
# Builds Enka for a physical iPhone and installs it, over the cable or Wi-Fi.
#
# Separate from `make ios`, which targets the simulator, because a device build
# has two requirements a simulator build does not: a real signing identity, and
# a phone that has agreed to run development builds. Both fail in ways whose
# error text does not say what to do, so most of this file is saying it.
#
# Always installs over what is there, never removes it first: removing the app
# would take everything it keeps on the phone with it.
#
#   IOS_LAUNCH=0   install without opening the app (the daily install does this)
#   DEVICE=<udid>  pick the phone yourself
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
PROJECT="$ROOT/Enka.xcodeproj"
DD="$ROOT/build-device"
APP="$DD/Build/Products/Debug-iphoneos/Enka.app"
BUNDLE="ru.tirinox.enka"

# ---------------------------------------------------------------- team -----
# The ten-character Apple Developer team that signs the build.
#
# Normally the project's own DEVELOPMENT_TEAM, which is where Xcode puts it and
# where it has to be for Xcode to sign anything itself. IOS_DEVELOPMENT_TEAM in
# .env overrides it, for signing with something other than what the project
# says without editing the project to do it.
TEAM="${IOS_DEVELOPMENT_TEAM:-$(grep -E '^IOS_DEVELOPMENT_TEAM=' "$REPO/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'')}"
if [ -z "$TEAM" ]; then
    TEAM="$(grep -m1 -E '^[[:space:]]*DEVELOPMENT_TEAM = ' "$PROJECT/project.pbxproj" 2>/dev/null \
            | sed -E 's/.*= *([A-Za-z0-9]+);.*/\1/')"
fi
if [ -z "$TEAM" ]; then
    echo "!!! no signing team." >&2
    echo "    Open $PROJECT, pick one under the target's Signing &" >&2
    echo "    Capabilities tab, or set IOS_DEVELOPMENT_TEAM in .env." >&2
    exit 1
fi

# -------------------------------------------------------------- server -----
# The address a fresh install starts with, from the environment or .env. Empty
# is fine: the app falls back to localhost.
SERVER="${CLIENT_DEFAULT_SERVER:-$(grep -E '^CLIENT_DEFAULT_SERVER=' "$REPO/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'')}"

# -------------------------------------------------------------- device -----
# The cable first, then Wi-Fi. A phone on the cable is the one in front of you,
# and preferring it makes that unambiguous when it is on the network as well.
# One that is only on the same network as this Mac is reachable too — that is
# how the daily install finds it, with nobody plugging anything in. CoreDevice
# calls a phone that is nowhere near "unavailable".
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
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
phones.sort(key=lambda d: d["connectionProperties"].get("transportType") != "wired")
if phones:
    print(phones[0]["hardwareProperties"]["udid"])
PY
)"
fi
if [ -z "$UDID" ]; then
    echo "!!! no iPhone in reach." >&2
    echo "    Unlock it, and plug it in or put it on the same Wi-Fi as this Mac." >&2
    echo "    If it is plugged in already, it may be waiting for you to tap" >&2
    echo "    Trust:  xcrun devicectl list devices" >&2
    echo "    Or name one yourself:  make ios-device DEVICE=<udid>" >&2
    exit 1
fi

# ------------------------------------------------------------- profile -----
# A free team's profile lasts seven days, and xcodebuild reuses the one it has
# cached for as long as it is valid at all — so installing every day would put
# the same expiry date on the phone every day, and the app would stop opening
# on that date all the same. A profile with under two days left is set aside,
# which makes -allowProvisioningUpdates ask Apple for a fresh week. If that
# fails, it is put back and this build uses it once more.
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
STALE="$DD/stale-profiles"
SOON="$(date -u -v+2d +%Y-%m-%dT%H:%M:%SZ)"
for f in "$PROFILES"/*.mobileprovision; do
    [ -f "$f" ] || continue
    id="$(security cms -D -i "$f" 2>/dev/null \
          | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)"
    [ "$id" = "$TEAM.$BUNDLE" ] || continue
    expires="$(security cms -D -i "$f" 2>/dev/null \
               | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
    if [[ "$expires" < "$SOON" ]]; then
        echo "==> the profile runs out $expires; asking for a fresh one"
        mkdir -p "$STALE"
        mv "$f" "$STALE/"
    fi
done

echo "==> building for $UDID, team $TEAM"
# Aimed at this device, not at `generic/platform=iOS`. The generic destination
# builds and signs perfectly well and then fails at install with 0xe8008012,
# "this provisioning profile cannot be installed on this device" — because a
# profile only covers the devices it was told about, and a generic build tells
# it about none. Naming the device is what makes -allowProvisioningUpdates
# register it and reissue the profile to include it.
#
# All of xcodebuild's output goes to a log and only its errors to the screen:
# the rest is a thousand lines of compiler invocations.
BUILD_LOG="$DD/build.log"
mkdir -p "$DD"
build() {
    xcodebuild -project "$PROJECT" -scheme Enka -configuration Debug \
        -destination "platform=iOS,id=$UDID" \
        -derivedDataPath "$DD" \
        DEVELOPMENT_TEAM="$TEAM" \
        CLIENT_DEFAULT_SERVER="$SERVER" \
        -allowProvisioningUpdates \
        build >"$BUILD_LOG" 2>&1 && return
    grep -E 'error:' "$BUILD_LOG" >&2 || true
    return 1
}
if ! build; then
    if ! ls "$STALE"/*.mobileprovision >/dev/null 2>&1; then
        echo "!!! build failed — the whole log is in $BUILD_LOG" >&2
        exit 1
    fi
    echo "!!! Apple gave no fresh profile, so this install runs out when the old" >&2
    echo "    one does. One run from Xcode (⌘R with the phone selected) gets one." >&2
    mv "$STALE"/*.mobileprovision "$PROFILES/"
    build || { echo "!!! build failed — the whole log is in $BUILD_LOG" >&2; exit 1; }
fi
rm -rf "$STALE"

echo "==> installing"
# The failure worth explaining. Developer Mode is off on a phone that has never
# run a development build, the toggle only appears once one has been attempted,
# and turning it on needs a restart — so the first run of this script fails
# here by design, and the second one works.
if ! xcrun devicectl device install app --device "$UDID" "$APP"; then
    echo >&2
    echo "    Developer Mode disabled: on the phone, Settings → Privacy &" >&2
    echo "    Security → Developer Mode → on, restart it, confirm after it comes" >&2
    echo "    back, and run this again." >&2
    echo >&2
    echo "    0xe8008012, or a profile that does not cover this device: the" >&2
    echo "    phone is not in the profile. Run once from Xcode (⌘R with the" >&2
    echo "    phone selected) to register it — see ios/README.md, which says" >&2
    echo "    why the command line cannot do that part on a free team." >&2
    exit 1
fi

EXPIRY="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract ExpirationDate raw - 2>/dev/null | cut -dT -f1)"
if [ "${IOS_LAUNCH:-1}" = 0 ]; then
    echo "==> installed, not launched.${EXPIRY:+ Signature good until $EXPIRY.}"
    exit 0
fi

echo "==> launching"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null
echo "==> done — Enka is on the phone.${EXPIRY:+ Signature good until $EXPIRY.}"

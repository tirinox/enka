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
# Aimed at this device, not at `generic/platform=iOS`. The generic destination
# builds and signs perfectly well and then fails at install with 0xe8008012,
# "this provisioning profile cannot be installed on this device" — because a
# profile only covers the devices it was told about, and a generic build tells
# it about none. Naming the device is what makes -allowProvisioningUpdates
# register it and reissue the profile to include it.
xcodebuild -quiet -project "$PROJECT" -scheme Enka -configuration Debug \
    -destination "platform=iOS,id=$UDID" \
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

echo "==> launching"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null
EXPIRY="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract ExpirationDate raw - 2>/dev/null | cut -dT -f1)"
echo "==> done — Enka is on the phone.${EXPIRY:+ Signature good until $EXPIRY.}"

#!/bin/bash
# Builds Enka.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
#
# A bundle, not a bare binary, and not only for tidiness. `LSUIElement` is what
# keeps the app out of the Dock, `SMAppService` refuses to register anything
# that is not a bundle, and the keychain scopes items by code identity — run
# straight from `.build/`, the app would ask for keychain access on every launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Enka.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Enka"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Enka"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Enka</string>
    <key>CFBundleDisplayName</key><string>Enka</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIdentifier</key><string>com.enka.app</string>
    <key>CFBundleExecutable</key><string>Enka</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Which identity signs the bundle.
#
# Ad-hoc by default, so a fresh clone builds with no setup at all. The cost is
# paid at the keychain: an ad-hoc identity *is* the binary's hash, so every
# rebuild looks to macOS like a different application asking for the same
# keychain item — which is the "Enka wants to access key com.enka.app" dialog,
# and why "Always Allow" does not stick past the next build. The same churn
# makes `SMAppService` re-register the login item each time.
#
# Set CODESIGN_IDENTITY to the name of a code-signing certificate and the
# identity stops moving: the keychain ACL is granted once and holds. A
# self-signed certificate from Keychain Access is enough — no Apple Developer
# account, no notarisation, because nothing here leaves this Mac.
#
#   security find-identity -v -p codesigning     # what you have
#   CODESIGN_IDENTITY="Enka Dev" ./Scripts/bundle.sh
#
# `make mac` also reads MACOS_CODESIGN_IDENTITY out of the repository's .env,
# which is the place to put it so it survives.
IDENTITY="${CODESIGN_IDENTITY:--}"

if [ "$IDENTITY" != "-" ]; then
    # Checked before signing rather than after failing: codesign's own error for
    # a name it cannot find is "no identity found", which reads like the
    # keychain is broken rather than like a typo.
    if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
        echo "!!! no code-signing identity matching \"$IDENTITY\"" >&2
        echo "    available:" >&2
        security find-identity -v -p codesigning | sed 's/^/    /' >&2
        exit 1
    fi
    echo "==> signing as \"$IDENTITY\""
else
    echo "==> ad-hoc signing"
fi
# Extended attributes come off first. iCloud hangs com.apple.FinderInfo on
# files, and codesign refuses to sign anything carrying one — "resource fork,
# Finder information, or similar detritus not allowed". The Desktop folder syncs
# to iCloud by default for many people, so a clone kept there stops signing the
# moment it is moved in.
xattr -cr "$APP"

# The failure is not softened to a warning. A refusal that prints a friendly
# line and returns zero leaves a bundle in build/ that codesign describes as
# "not signed at all" — and the only symptom is keychain prompts coming back,
# for somebody who has already installed it.
codesign --force --deep --sign "$IDENTITY" "$APP" || {
    echo "!!! codesign could not sign the bundle — see above" >&2
    exit 1
}
codesign --verify --strict "$APP" || {
    echo "!!! the signature did not verify" >&2
    exit 1
}

echo "==> done: $APP"

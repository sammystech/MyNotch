#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MyNotch.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "▸ Cleaning…"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "▸ Compiling…"
swiftc -parse-as-library -O \
    -o "$MACOS/MyNotch" \
    Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework AVFoundation -framework EventKit -framework Combine -framework ServiceManagement -framework QuickLookThumbnailing

echo "▸ Bundling…"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$RES/AppIcon.icns"

SIGN_ID="MyNotch Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "▸ Signing (stable cert: $SIGN_ID — permissions survive rebuilds)…"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "▸ Signing (ad-hoc — WARNING: camera/calendar/automation grants will reset on every rebuild; run setup_signing_identity.sh once to fix)…"
    codesign --force --deep --sign - "$APP"
fi

echo "✓ Built $APP"

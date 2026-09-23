#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# 1. Fresh release build of the .app
./build.sh

APP="build/MyNotch.app"
DIST="dist"
DMG="$DIST/MyNotch.dmg"
VOL="My Notch"

mkdir -p "$DIST"
rm -f "$DMG"

# 2. Stage the DMG contents: the app + a shortcut to /Applications
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# LOCAL builds only (self-signed, not notarized). Public releases come from
# ./release.sh, which signs with Developer ID and notarizes.
# Include a short read-me for recipients (Gatekeeper bypass).
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
My Notch — install

1. Drag "MyNotch" onto the Applications folder.
2. The first time you open it, macOS may say it can't verify the developer.
   Right-click (or Control-click) MyNotch in Applications, choose "Open",
   then click "Open" again in the dialog. You only do this once.
3. Approve the Camera and Calendar prompts to use the Mirror and Calendar.

It lives in the notch at the top of your screen — click it to open,
move your mouse away to close. Quit from its menu-bar icon.
TXT

# 3. Build a compressed DMG
hdiutil create -volname "$VOL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

rm -rf "$STAGE"
echo "✓ Built $DMG"
ls -lh "$DMG"

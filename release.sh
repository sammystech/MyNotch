#!/bin/bash
# Cut a new release: bump version, archive, sign with Developer ID, notarize
# with Apple, staple, package the DMG, tag, push, and publish to GitHub
# Releases — which is exactly where the in-app updater looks.
#
#   ./release.sh 1.4.0 "What changed in this version"
#
# If Apple is slow and the wait times out, pick up the SAME upload (no new
# version bump, no re-archive) with:
#
#   RESUME=1 ./release.sh 1.4.0 "notes"
#
# Requirements:
#   * Xcode signed in to team CH6CSBA54G (Settings → Accounts), with its
#     "Developer ID Application" certificate in the login keychain.
#     Notarization goes through that same Xcode sign-in — no app-specific
#     password or notarytool profile needed.
#   * xcodegen (brew install xcodegen) and gh (logged in).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh <version> [release notes]"
    echo "   eg: ./release.sh 1.4.0 \"Added the file shelf\""
    exit 1
fi

die() { echo "✗ $*" >&2; exit 1; }
say() { echo "▸ $*"; }

TEAM_ID="CH6CSBA54G"
BUILD_DIR=".release-build"
APP_NAME="MyNotch"

SIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application:.*($TEAM_ID)" | head -1 | sed -E 's/.*"(.+)"/\1/' || true)
[ -n "$SIGN_IDENTITY" ] || die "No 'Developer ID Application' certificate for team $TEAM_ID in the keychain.
  Xcode → Settings → Accounts → (team) → Manage Certificates → + → Developer ID Application"
echo "  signing as: $SIGN_IDENTITY"

RESUME="${RESUME:-}"
WAIT_MIN="${NOTARY_WAIT_MIN:-30}"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"

if [ "$RESUME" = 1 ]; then
    [ -d "$ARCHIVE" ] || die "Nothing to resume: no archive at $ARCHIVE"
    CUR=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
    [ "$CUR" = "$VERSION" ] || die "Info.plist is at $CUR, not $VERSION — resume the version you uploaded."
    say "Resuming $VERSION: waiting on the upload already with Apple…"
else
say "Bumping to $VERSION…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" Info.plist

say "Archiving…"
xcodegen generate >/dev/null
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
xcodebuild -project MyNotch.xcodeproj -scheme MyNotch -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$BUILD_DIR/dd" -allowProvisioningUpdates archive \
    > "$BUILD_DIR/archive.log" 2>&1 \
    || { grep -E "error:" "$BUILD_DIR/archive.log" | sort -u | head -20; die "Archive failed. Log: $BUILD_DIR/archive.log"; }

say "Signing with Developer ID and submitting to Apple for notarization…"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$BUILD_DIR/upload-receipt" -allowProvisioningUpdates > "$BUILD_DIR/export.log" 2>&1 \
    || { grep -iE "error" "$BUILD_DIR/export.log" | sort -u | head -20; die "Export/upload failed. Log: $BUILD_DIR/export.log"; }
echo "  uploaded; waiting for Apple (usually a few minutes, first ones can take hours)"
fi

NOTARIZED="$BUILD_DIR/notarized"
rm -rf "$NOTARIZED"      # a previous (resumed) run may have exported it already
TRIES=$(( WAIT_MIN * 60 / 25 ))
for attempt in $(seq 1 "$TRIES"); do    # every 25s for WAIT_MIN minutes
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$NOTARIZED" \
            > "$BUILD_DIR/notarize.log" 2>&1; then
        echo "  notarized after ~$((attempt * 25))s"
        break
    fi
    if grep -q "No Accounts" "$BUILD_DIR/notarize.log"; then
        die "Xcode is signed out, so it can't ask Apple for the result.
  Sign in: Xcode → Settings → Accounts → + → Apple ID (team $TEAM_ID), then:
  RESUME=1 ./release.sh $VERSION \"notes\""
    fi
    if grep -qiE "invalid|rejected|not accepted" "$BUILD_DIR/notarize.log"; then
        grep -iE "error|invalid|reject" "$BUILD_DIR/notarize.log" | head -10
        die "Apple rejected the submission. Details: Xcode → Window → Organizer → this archive."
    fi
    [ "$attempt" -eq "$TRIES" ] && die "Still not notarized after $WAIT_MIN minutes. Apple is still processing it.
  Resume (same upload, nothing re-sent): RESUME=1 ./release.sh $VERSION \"notes\""
    sleep 25
done

APP="$NOTARIZED/$APP_NAME.app"
[ -d "$APP" ] || die "Notarized app not found at $APP"
xcrun stapler validate "$APP" >/dev/null 2>&1 || die "No notarization ticket stapled to the app."
ASSESS=$(spctl -a -t exec -vv "$APP" 2>&1 || true)
echo "$ASSESS" | grep -q "source=Notarized Developer ID" \
    || { echo "$ASSESS"; die "Gatekeeper doesn't accept this as a notarized Developer ID app."; }
echo "  Gatekeeper: accepted (Notarized Developer ID)"

say "Packaging the DMG…"
mkdir -p dist
DMG="dist/MyNotch.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "My Notch" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
# Signed so the download itself is attributable; the app inside carries its
# own stapled notarization ticket, which is what Gatekeeper checks.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" || die "Couldn't sign the DMG."
ls -lh "$DMG"

say "Committing + tagging…"
git add -A
git commit -m "Release v$VERSION" || echo "(nothing to commit)"
git tag -f "v$VERSION"
git push origin HEAD
git push -f origin "v$VERSION"

say "Publishing release…"
gh release create "v$VERSION" "$DMG" \
    --title "MyNotch $VERSION" \
    --notes "${NOTES:-See the commit history for what changed.}" \
    || gh release upload "v$VERSION" "$DMG" --clobber

echo "✓ Released v$VERSION — signed, notarized, and live. Existing installs will offer it within a day."
echo "  Install locally with: rm -rf /Applications/MyNotch.app && cp -R \"$APP\" /Applications/"

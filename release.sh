#!/bin/bash
# Cut a new release: bump version, build, tag, push, and publish the DMG
# to GitHub Releases — which is exactly where the in-app updater looks.
#
#   ./release.sh 1.1.0 "What changed in this version"
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh <version> [release notes]"
    echo "   eg: ./release.sh 1.1.0 \"Added the file shelf\""
    exit 1
fi

echo "▸ Bumping to $VERSION…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" Info.plist

./build_dmg.sh

echo "▸ Committing + tagging…"
git add -A
git commit -m "Release v$VERSION" || echo "(nothing to commit)"
git tag -f "v$VERSION"
git push origin HEAD
git push -f origin "v$VERSION"

echo "▸ Publishing release…"
gh release create "v$VERSION" dist/MyNotch.dmg \
    --title "MyNotch $VERSION" \
    --notes "${NOTES:-See the commit history for what changed.}" \
    || gh release upload "v$VERSION" dist/MyNotch.dmg --clobber

echo "✓ Released v$VERSION — existing installs will offer the update within a day."

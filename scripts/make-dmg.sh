#!/bin/bash
# Produces dist/SuperScreenshot-<version>.dmg: universal (Apple silicon + Intel) app, drag-to-Applications layout,
# and install notes for Gatekeeper (the app is self-signed, not notarized).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

UNIVERSAL=1 ./scripts/build-extensions.sh
UNIVERSAL=1 ./scripts/build-app.sh

STAGE="$ROOT/build/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R build/SuperScreenshot.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install Super Screenshot.txt" <<TXT
Installing Super Screenshot $VERSION
====================================

1. Drag Super Screenshot into the Applications folder.
2. Open Super Screenshot from Applications. macOS will say it "cannot be opened" because the app
   is not notarized by Apple. Click Done.
3. Open System Settings → Privacy & Security, scroll down and click "Open Anyway" next to
   the Super Screenshot message, then confirm with your password.
   (Alternatively, in Terminal: xattr -dr com.apple.quarantine /Applications/SuperScreenshot.app)
4. Super Screenshot appears in the menu bar. Follow the welcome window to grant Screen Recording
   permission, then relaunch when asked.

Requirements: macOS 14 Sonoma or later, Apple silicon or Intel.
TXT

mkdir -p dist
DMG="dist/SuperScreenshot-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "Super Screenshot $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null && echo "Created $DMG ($(du -h "$DMG" | cut -f1))"

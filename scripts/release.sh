#!/bin/bash
# Builds the universal DMG and publishes it as a GitHub release.
#   ./scripts/release.sh 1.0.1
# The asset is uploaded twice: "Shotcraft-<version>.dmg" and a stable "Shotcraft.dmg", which the one-line installer
# and the website download from (https://github.com/<repo>/releases/latest/download/Shotcraft.dmg).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="${1:?usage: release.sh <version>}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD=$(git rev-list --count HEAD); /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
./scripts/make-dmg.sh
cp "dist/Shotcraft-$VERSION.dmg" dist/Shotcraft.dmg
SHA=$(shasum -a 256 dist/Shotcraft.dmg | cut -d' ' -f1)
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## \\["v"\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md)
git tag -s "v$VERSION" -m "Shotcraft $VERSION" 2>/dev/null || git tag "v$VERSION" -m "Shotcraft $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "dist/Shotcraft-$VERSION.dmg" dist/Shotcraft.dmg --title "Shotcraft $VERSION" \
  --notes "$NOTES

**Install:** \`curl -fsSL https://udsy19.github.io/CleanShotX/install.sh | bash\` — or download the DMG below.

SHA-256 (Shotcraft.dmg): \`$SHA\`"

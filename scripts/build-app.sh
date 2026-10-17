#!/bin/bash
# Builds build/Shotcraft.app (release by default; `--debug` for a fast debug build) and signs it with the
# project-local identity from scripts/signing-setup.sh (falls back to ad-hoc).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CONFIG=release; [ "${1:-}" = "--debug" ] && CONFIG=debug
if [ "${UNIVERSAL:-0}" = 1 ]; then
  # Build each architecture separately (the CLT toolchain has no multi-arch build) and merge with lipo.
  for arch in arm64 x86_64; do swift build -c "$CONFIG" --product Shotcraft --triple "$arch-apple-macosx14.0"; done
  BIN="$ROOT/build/universal"; mkdir -p "$BIN"
  lipo -create -output "$BIN/Shotcraft" "$(swift build -c "$CONFIG" --triple arm64-apple-macosx14.0 --show-bin-path)/Shotcraft" "$(swift build -c "$CONFIG" --triple x86_64-apple-macosx14.0 --show-bin-path)/Shotcraft"
else
  swift build -c "$CONFIG" --product Shotcraft
  BIN="$(swift build -c "$CONFIG" --show-bin-path)"
fi

APP="$ROOT/build/Shotcraft.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Shotcraft" "$APP/Contents/MacOS/Shotcraft"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# SwiftPM resource bundles (if any module declares resources).
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
# Extensions built by scripts/build-extensions.sh, if present.
[ -d "$ROOT/build/PlugIns" ] && cp -R "$ROOT/build/PlugIns" "$APP/Contents/PlugIns"

ICONSET="$ROOT/build/AppIcon.iconset"
if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET" && iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

KC="$ROOT/.signing/shotcraft.keychain-db"
ENT="$ROOT/Resources/Shotcraft.entitlements"
if [ -f "$KC" ]; then
  security unlock-keychain -p shotcraft "$KC"
  ORIG=()
  while IFS= read -r line; do line="${line#"${line%%[![:space:]]*}"}"; line="${line//\"/}"; [ -n "$line" ] && ORIG+=("$line"); done < <(security list-keychains -d user)
  restore() { security list-keychains -d user -s "${ORIG[@]}"; }
  trap restore EXIT
  security list-keychains -d user -s "${ORIG[@]}" "$KC"
  [ -d "$APP/Contents/PlugIns" ] && for ext in "$APP"/Contents/PlugIns/*.appex; do
    codesign -f -s "Shotcraft Local Signing" --keychain "$KC" -o runtime --entitlements "$ROOT/Resources/Extension.entitlements" "$ext"
  done
  codesign -f -s "Shotcraft Local Signing" --keychain "$KC" -o runtime --entitlements "$ENT" "$APP"
  restore; trap - EXIT
else
  codesign -f -s - --entitlements "$ENT" "$APP"
fi
echo "Built $APP"

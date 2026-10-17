#!/bin/bash
# Shotcraft installer.
#
#   Install / update:  curl -fsSL https://udsy19.github.io/CleanShotX/install.sh | bash
#   Uninstall:         curl -fsSL https://udsy19.github.io/CleanShotX/install.sh | bash -s -- --uninstall
#
# Downloads the latest release from GitHub, installs it into /Applications (or ~/Applications when /Applications
# isn't writable) and opens it. Nothing else on your system is changed.
set -euo pipefail

REPO="udsy19/CleanShotX"
APP="Shotcraft.app"
DMG_URL="https://github.com/$REPO/releases/latest/download/Shotcraft.dmg"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '%s→%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf '%s✗ %s%s\n' "$red" "$*" "$reset" >&2; exit 1; }

quit_running() {
  if pgrep -x Shotcraft >/dev/null 2>&1; then
    step "Quitting the running copy of Shotcraft"
    osascript -e 'tell application id "com.udsy.shotcraft" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Shotcraft >/dev/null 2>&1 || break; sleep 0.5; done
    pkill -x Shotcraft 2>/dev/null || true
  fi
}

installed_path() {
  for dir in "/Applications" "$HOME/Applications"; do
    [ -d "$dir/$APP" ] && { printf '%s\n' "$dir/$APP"; return 0; }
  done
  return 1
}

[ "$(uname -s)" = "Darwin" ] || fail "Shotcraft runs on macOS only."

if [ "${1:-}" = "--uninstall" ]; then
  path="$(installed_path)" || fail "Shotcraft isn't installed."
  quit_running
  step "Removing $path"
  rm -rf "$path"
  say "${green}✓ Shotcraft was uninstalled.${reset}"
  say "${dim}Your captures and settings were kept in ~/Library/Application Support/Shotcraft and${reset}"
  say "${dim}~/Library/Preferences/com.udsy.shotcraft.plist — delete them to remove everything.${reset}"
  exit 0
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Shotcraft needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."

say "${bold}Installing Shotcraft${reset} ${dim}— screenshots & screen recording for macOS${reset}"
tmp="$(mktemp -d -t shotcraft-install)"
mnt="$tmp/mount"
cleanup() { hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

step "Downloading the latest release"
curl -fL --progress-bar -o "$tmp/Shotcraft.dmg" "$DMG_URL" || fail "Download failed — check your connection and try again."

step "Verifying the disk image"
hdiutil verify "$tmp/Shotcraft.dmg" -quiet || fail "The download is damaged. Please try again."
mkdir -p "$mnt"
hdiutil attach "$tmp/Shotcraft.dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet || fail "Couldn't open the disk image."
[ -d "$mnt/$APP" ] || fail "The disk image doesn't contain $APP."

dest="/Applications"
if [ ! -w "$dest" ]; then
  dest="$HOME/Applications"; mkdir -p "$dest"
fi

quit_running
step "Installing to $dest"
rm -rf "$dest/$APP"
ditto "$mnt/$APP" "$dest/$APP"
# Downloads made with curl aren't quarantined; clear the flag anyway in case the image was cached by a browser.
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/$APP/Contents/Info.plist" 2>/dev/null || echo "")"
say "${green}✓ Shotcraft ${version} is installed.${reset} Opening it now — look for the icon in your menu bar."
open "$dest/$APP"

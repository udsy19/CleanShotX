#!/bin/bash
# Super Screenshot installer.
#
#   Install / update:  curl -fsSL https://udsy19.github.io/super-screenshot/install.sh | bash
#   Uninstall:         curl -fsSL https://udsy19.github.io/super-screenshot/install.sh | bash -s -- --uninstall
#
# Downloads the latest release from GitHub, installs it into /Applications (or ~/Applications when /Applications
# isn't writable) and opens it. A copy installed under the app's previous name (Shotcraft.app) is replaced.
# Nothing else on your system is changed.
# Options (environment): SUPERSCREENSHOT_INSTALL_DIR=<folder> to install elsewhere, SUPERSCREENSHOT_NO_OPEN=1 to skip
# launching.
set -euo pipefail

REPO="udsy19/super-screenshot"
APP="SuperScreenshot.app"
DMG_URL="https://github.com/$REPO/releases/latest/download/SuperScreenshot.dmg"
# The same app before it was renamed.
LEGACY_APP="Shotcraft.app"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '%s→%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf '%s✗ %s%s\n' "$red" "$*" "$reset" >&2; exit 1; }

# quit_running <process> <bundle id>
quit_running() {
  if pgrep -x "$1" >/dev/null 2>&1; then
    step "Quitting the running copy of Super Screenshot"
    osascript -e "tell application id \"$2\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$1" >/dev/null 2>&1 || break; sleep 0.5; done
    pkill -x "$1" 2>/dev/null || true
  fi
}
quit_all() {
  quit_running SuperScreenshot com.udsy.superscreenshot
  quit_running Shotcraft com.udsy.shotcraft
}

# installed_paths <app>: every copy in /Applications and ~/Applications.
installed_paths() {
  for dir in "/Applications" "$HOME/Applications"; do
    [ -d "$dir/$1" ] && printf '%s\n' "$dir/$1"
  done
  return 0
}

[ "$(uname -s)" = "Darwin" ] || fail "Super Screenshot runs on macOS only."

if [ "${1:-}" = "--uninstall" ]; then
  paths="$(installed_paths "$APP"; installed_paths "$LEGACY_APP")"
  [ -n "$paths" ] || fail "Super Screenshot isn't installed."
  quit_all
  while IFS= read -r path; do
    step "Removing $path"
    rm -rf "$path"
  done <<<"$paths"
  say "${green}✓ Super Screenshot was uninstalled.${reset}"
  say "${dim}Your captures and settings were kept in ~/Library/Application Support/SuperScreenshot and${reset}"
  say "${dim}~/Library/Preferences/com.udsy.superscreenshot.plist — delete them to remove everything.${reset}"
  [ -f "$HOME/Library/Preferences/com.udsy.shotcraft.plist" ] && \
    say "${dim}Settings from before the rename are in ~/Library/Preferences/com.udsy.shotcraft.plist.${reset}"
  exit 0
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Super Screenshot needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."

say "${bold}Installing Super Screenshot${reset} ${dim}— screenshots & screen recording for macOS${reset}"
tmp="$(mktemp -d -t superscreenshot-install)"
mnt="$tmp/mount"
cleanup() { hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

step "Downloading the latest release"
curl -fL --progress-bar -o "$tmp/SuperScreenshot.dmg" "$DMG_URL" || fail "Download failed — check your connection and try again."

step "Verifying the disk image"
hdiutil verify "$tmp/SuperScreenshot.dmg" -quiet || fail "The download is damaged. Please try again."
mkdir -p "$mnt"
hdiutil attach "$tmp/SuperScreenshot.dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet || fail "Couldn't open the disk image."
[ -d "$mnt/$APP" ] || fail "The disk image doesn't contain $APP."

dest="${SUPERSCREENSHOT_INSTALL_DIR:-/Applications}"
mkdir -p "$dest" 2>/dev/null || true
if [ ! -w "$dest" ]; then
  dest="$HOME/Applications"; mkdir -p "$dest"
fi

[ "${SUPERSCREENSHOT_NO_OPEN:-0}" = 1 ] || quit_all
step "Installing to $dest"
rm -rf "$dest/$APP"
ditto "$mnt/$APP" "$dest/$APP"
# Downloads made with curl aren't quarantined; clear the flag anyway in case the image was cached by a browser.
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

# The copy installed under the previous name is the same app; the new one takes over its settings and captures.
legacy="$(installed_paths "$LEGACY_APP")"
if [ -n "$legacy" ]; then
  quit_running Shotcraft com.udsy.shotcraft
  while IFS= read -r path; do
    step "Removing the copy installed under the previous name ($path)"
    rm -rf "$path"
  done <<<"$legacy"
fi

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/$APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "${SUPERSCREENSHOT_NO_OPEN:-0}" = 1 ]; then
  say "${green}✓ Super Screenshot ${version} is installed in $dest.${reset}"
else
  say "${green}✓ Super Screenshot ${version} is installed.${reset} Opening it now — look for the icon in your menu bar."
  open "$dest/$APP"
fi

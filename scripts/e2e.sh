#!/bin/bash
# Automated end-to-end checks against a running build/Shotcraft.app.
#
# Every capture targets a pinned synthetic test card (pins float above other windows), so no other screen content is
# meant to be captured; captures created by the run are deleted afterwards (pre-existing files are never touched). Preferences are backed up first and restored on exit; exports/uploads go to a temporary folder.
# Requirements: the terminal running this has Accessibility permission (for synthetic input), Shotcraft has Screen
# Recording permission. The script takes over the mouse for ~2 minutes — don't use the Mac meanwhile.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t shotcraft-e2e)"
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/export" "$WORK/uploads"
DOMAIN=com.udsy.shotcraft
MEDIA="$HOME/Library/Application Support/Shotcraft/Media"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

for t in ui testcard avgcolor clipboard videoframe windows; do
  swiftc -O -o "$BIN/$t" "$ROOT/Tools/e2e/$t.swift" 2>/dev/null || { echo "failed to build $t"; exit 2; }
done
UI="$BIN/ui"

defaults export $DOMAIN "$WORK/prefs-backup.plist" 2>/dev/null
RECS="$HOME/Library/Application Support/Shotcraft/Recordings"
# Remember exactly which captures existed before the run; only files created by this run are removed afterwards.
( /bin/ls "$MEDIA"; /bin/ls "$RECS" ) 2>/dev/null | sort > "$WORK/before.txt"
restore() {
  defaults import $DOMAIN "$WORK/prefs-backup.plist" 2>/dev/null
  for dir in "$MEDIA" "$RECS"; do
    /bin/ls "$dir" 2>/dev/null | while IFS= read -r f; do
      grep -Fxq -- "$f" "$WORK/before.txt" || rm -f -- "$dir/$f"
    done
  done
}
trap restore EXIT
defaults write $DOMAIN allowURLSchemeAPI -bool true
defaults write $DOMAIN exportLocation "$WORK/export"
defaults write $DOMAIN uploadDestination folder
defaults write $DOMAIN uploadFolderPath "$WORK/uploads"
defaults write $DOMAIN uploadFolderURLPrefix "https://example.test/u/"
defaults write $DOMAIN freezeScreenWhenCapturing -bool false

pgrep -x Shotcraft >/dev/null || { open "$ROOT/build/Shotcraft.app"; sleep 3; }
"$BIN/testcard" "$WORK/testcard.png"
latest() { /bin/ls -t "$MEDIA"/*.$1 2>/dev/null | head -1; }
is_blue() { read -r w h r g b <<<"$("$BIN/avgcolor" "$1")"; [ "$b" -gt 200 ] && [ "$r" -lt 120 ]; }

# The pin appears at a deterministic spot: centred, scaled to fit the main screen. Find its blue quadrant.
open "shotcraft://pin?filepath=$WORK/testcard.png"; sleep 1.5
read -r PX PY PW PH <<<"$("$BIN/windows" | awk '$2==3 && $5>600 {print $3, $4, $5, $6; exit}')"
[ -n "${PW:-}" ] || { echo "pin not found"; exit 2; }
SCREEN_H=$("$BIN/windows" screen)
BX=$((PX + PW/16)); BY=$((PY + PH/16))        # CG point inside the blue (top-left) quadrant
CY=$((SCREEN_H - BY - 150))                    # Cocoa y for a 200×150 rect starting at BY

echo "Screenshots"
open "shotcraft://capture-area?x=$BX&y=$CY&width=200&height=150"; sleep 2.5
F=$(latest png); is_blue "$F" && ok "URL capture-area pixels" || bad "URL capture-area pixels ($F)"
open "shotcraft://capture-area?x=$BX&y=$CY&width=200&height=150&action=copy"; sleep 2
"$BIN/clipboard" | grep -q "png: 400 300" && ok "capture & copy to clipboard" || bad "capture & copy to clipboard"
open "shotcraft://capture-area"; sleep 1.5; "$UI" move $((BX+40)) $((BY+40)); sleep 0.3
"$UI" drag $BX $BY $((BX+200)) $((BY+150)); sleep 2.5
F=$(latest png); is_blue "$F" && ok "interactive area selection" || bad "interactive area selection"
open "shotcraft://capture-window"; sleep 1.5; "$UI" move $((PX+PW/2)) $((PY+PH/2)); sleep 0.4; "$UI" click $((PX+PW/2)) $((PY+PH/2)); sleep 2.5
F=$(latest png); W=$(sips -g pixelWidth "$F" | awk '/pixelWidth/{print $2}')
[ "$W" -ge $((PW*2)) ] && ok "window capture (${W}px wide)" || bad "window capture ($W px)"

echo "Text recognition"
osascript -e 'set the clipboard to "x"'
open "shotcraft://capture-text"; sleep 1.5; "$UI" move $((PX+PW/2)) $((PY+PH/2)); sleep 0.3
"$UI" drag $((PX+PW/8)) $((PY+PH/3)) $((PX+PW*7/8)) $((PY+PH*3/4)); sleep 3.5
"$BIN/clipboard" | grep -q "Shotcraft E2E 4721" && ok "OCR copies recognized text" || bad "OCR"

echo "Recording"
open "shotcraft://record-screen?x=$BX&y=$CY&width=300&height=200"; sleep 2; "$UI" press "Record Video" >/dev/null; sleep 7
open "shotcraft://stop-recording"; sleep 4
V=$(/bin/ls -t "$HOME/Library/Application Support/Shotcraft/Recordings/"*.mp4 2>/dev/null | head -1)
"$BIN/videoframe" "$V" "$WORK/frame.png" 1 | grep -q "frame 600 400" && ok "video recording" || bad "video recording ($V)"
open "shotcraft://record-gif?x=$BX&y=$CY&width=300&height=200"; sleep 2; "$UI" press "Record GIF" >/dev/null; sleep 6
open "shotcraft://stop-recording"; sleep 8
G=$(/bin/ls -t "$HOME/Library/Application Support/Shotcraft/Recordings/"*.gif 2>/dev/null | head -1)
[ -n "$G" ] && [ "$(sips -g pixelWidth "$G" | awk '/pixelWidth/{print $2}')" = 600 ] && ok "GIF recording" || bad "GIF recording"

echo "Upload & save"
open "shotcraft://capture-area?x=$BX&y=$CY&width=200&height=150&action=upload"; sleep 3
[ "$(ls "$WORK/uploads" | wc -l)" -ge 1 ] && "$BIN/clipboard" | grep -q "https://example.test/u/" && ok "upload to folder + link copied" || bad "upload"
open "shotcraft://capture-area?x=$BX&y=$CY&width=200&height=150&action=save"; sleep 2.5
[ "$(ls "$WORK/export" | wc -l)" -ge 1 ] && ok "save to export location" || bad "save to export location"

echo "Other"
open "shotcraft://hide-desktop-icons"; sleep 1
"$BIN/windows" | awk '$2<-1000' | grep -q . && ok "hide desktop icons" || bad "hide desktop icons"
open "shotcraft://show-desktop-icons"; sleep 1
"$BIN/windows" | awk '$2<-1000' | grep -q . && bad "show desktop icons" || ok "show desktop icons"
open "shotcraft://open-settings?tab=about"; sleep 1.5
"$UI" windows | grep -q "^About " && ok "settings window" || bad "settings window"
"$UI" closewin About >/dev/null

echo
echo "$PASS passed, $FAIL failed  (artifacts: $WORK)"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Build and install Panewright's patched AeroSpace over the brew-cask install.
#
#   Scripts/patch-aerospace.sh
#
# Why this exists: two behaviors Panewright needs live inside AeroSpace and
# aren't configurable upstream —
#
#   1. Dock-aware hide corner. Hidden workspaces park windows at the visible
#      frame's bottom-right corner, and macOS clamps windows to stay a point
#      inside the visible area. With the Dock on the right edge that parks
#      them ~50pt short of the physical screen, visibly peeking out around
#      the Dock. The patch parks bottom-left whenever the right corner is
#      Dock-obstructed.
#   2. A hideable menu bar icon (`defaults write bobko.aerospace
#      menu-bar-icon-hidden -bool true`), because Panewright's bar owns that
#      surface.
#
# Source of truth: the `panewright` branch of github.com/nitschw/AeroSpace
# (fork of nikitabobko/AeroSpace at the tag matching the installed cask).
# The same diffs live in Patches/ for review.
#
# Run it again after `brew upgrade` replaces the cask with stock AeroSpace —
# but first rebase the fork branch onto the new tag and re-verify, since the
# patched tree must match the cask version the CLI protocol expects.
#
# Re-signing changes the app's identity, so macOS drops its Accessibility
# grant: System Settings → Privacy & Security → Accessibility → toggle
# AeroSpace off and on. That step can't be scripted, by design.
set -euo pipefail

CHECKOUT="$HOME/src/AeroSpace-patched"
APP=/Applications/AeroSpace.app
BACKUPS="$HOME/.config/panewright/backups/aerospace-stock"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

bold "Checkout"
if [ ! -d "$CHECKOUT/.git" ]; then
    git clone --branch panewright git@github.com:nitschw/AeroSpace.git "$CHECKOUT"
fi
cd "$CHECKOUT"
git fetch origin panewright 2>/dev/null || true
echo "  at: $(git log --oneline -1)"

bold "Version check"
CASK_VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
echo "  installed cask: $CASK_VERSION — fork must be based on the matching tag"

bold "Build"
export PATH="/opt/homebrew/bin:$PATH"
./generate.sh --ignore-xcodeproj --ignore-cmd-help --build-version "$CASK_VERSION"
swift build -c release --product AeroSpaceApp
swift build -c release --product aerospace

bold "Install"
CLI="$(readlink -f /opt/homebrew/bin/aerospace)"
mkdir -p "$BACKUPS"
[ -f "$BACKUPS/AeroSpace" ] || cp "$APP/Contents/MacOS/AeroSpace" "$BACKUPS/AeroSpace"
[ -f "$BACKUPS/aerospace-cli" ] || cp "$CLI" "$BACKUPS/aerospace-cli"
osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
sleep 2
cp .build/release/AeroSpaceApp "$APP/Contents/MacOS/AeroSpace"
cp .build/release/aerospace "$CLI"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --force --options runtime --sign "$IDENTITY" "$CLI"
defaults write bobko.aerospace menu-bar-icon-hidden -bool true

bold "Done"
echo "  Relaunch AeroSpace, then re-grant Accessibility (toggle off/on):"
echo "  System Settings → Privacy & Security → Accessibility → AeroSpace"
echo "  Stock binaries preserved in $BACKUPS for revert."

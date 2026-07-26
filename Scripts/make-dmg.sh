#!/bin/bash
# Build a signed disk image around an already-built Panewright.app.
#
#   Scripts/make-dmg.sh 0.3.5
#
# Why a DMG exists alongside the zip: Homebrew Cask extracts a .zip with
# `unzip`, which materialises AppleDouble sidecar files ("._Installer") inside
# Sparkle.framework. Those files aren't covered by the signature, so the seal
# breaks and Gatekeeper refuses to launch what it just installed. Homebrew
# extracts a .dmg with `ditto`, which handles them correctly.
# (unpack_strategy/zip.rb uses unzip; unpack_strategy/dmg.rb uses ditto.)
#
# Sparkle keeps using the zip — it extracts properly, and changing the update
# feed's format is a separate decision from how people first install.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/make-dmg.sh <version>}"
APP="build/Panewright.app"
DMG="build/Panewright-$VERSION.dmg"
STAGING="build/dmg-staging"

[ -d "$APP" ] || { echo "no $APP — run Scripts/bundle.sh first" >&2; exit 1; }

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
# ditto rather than cp: it preserves the symlinks inside Sparkle.framework and
# the extended attributes the signature was computed over.
ditto "$APP" "$STAGING/Panewright.app"
# The drag-to-install target. Cask ignores it and copies the .app directly,
# but anyone who opens the DMG by hand expects it.
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Panewright" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGING"

# Sign the image itself, so the download is verifiable before it's opened.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -n "${IDENTITY:-}" ]; then
    codesign --force --sign "$IDENTITY" "$DMG"
    echo "signed $DMG with: $IDENTITY"
else
    echo "warning: no Developer ID — $DMG is unsigned and Gatekeeper will refuse it"
fi

echo "built $DMG"

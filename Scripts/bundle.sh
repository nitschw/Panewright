#!/bin/bash
# Assemble and sign Panewright.app from the SwiftPM build.
#
#   Scripts/bundle.sh [debug|release]   (default: release)
#
# Signing: uses your "Apple Development" identity if one exists (sign into
# Xcode → Settings → Accounts with any Apple ID to get one — free), else
# falls back to ad-hoc. Ad-hoc is fine until Panewright itself needs TCC
# permissions (the drag layer will), because macOS ties permission grants
# to a stable signing identity.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP="build/Panewright.app"

swift build -c "$CONFIGURATION" --product panewright

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp ".build/$CONFIGURATION/panewright" "$APP/Contents/MacOS/panewright"
cp Assets/logo.png "$APP/Contents/Resources/logo.png"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Embed the tiling engine (the patched AeroSpace fork) as a helper
# executable. A direct child inherits Panewright's TCC responsibility, so one
# Accessibility grant covers the whole product. Skipped when the fork build
# isn't present — the app then falls back to launching /Applications/AeroSpace.
ENGINE="$HOME/src/AeroSpace-patched/.build/apple/Products/Release/AeroSpaceApp"
CLI_BIN="$HOME/src/AeroSpace-patched/.build/apple/Products/Release/aerospace"
if [ -f "$ENGINE" ]; then
    mkdir -p "$APP/Contents/Helpers"
    cp "$ENGINE" "$APP/Contents/Helpers/AeroSpace"
    # Named aerospace-cli, not aerospace: APFS is case-insensitive by
    # default, so "aerospace" beside "AeroSpace" would be the same file.
    [ -f "$CLI_BIN" ] && cp "$CLI_BIN" "$APP/Contents/Helpers/aerospace-cli"
    echo "embedded engine + CLI from fork build"
else
    echo "note: no fork build at $ENGINE — engine not embedded"
fi

# Embed Sparkle (SwiftPM links it from build artifacts; ship a copy).
SPARKLE_FW="$(find .build/artifacts -name "Sparkle.framework" -type d | head -1)"
if [ -n "$SPARKLE_FW" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/panewright" 2>/dev/null || true
fi

# Prefer the distribution-grade identity once the paid program provides it.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -z "${IDENTITY:-}" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [ -n "${IDENTITY:-}" ]; then
    if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
        codesign --force --options runtime --deep --sign "$IDENTITY" \
            "$APP/Contents/Frameworks/Sparkle.framework"
    fi
    if [ -f "$APP/Contents/Helpers/AeroSpace" ]; then
        codesign --force --options runtime --sign "$IDENTITY" \
            "$APP/Contents/Helpers/AeroSpace"
    fi
    if [ -f "$APP/Contents/Helpers/aerospace-cli" ]; then
        codesign --force --options runtime --sign "$IDENTITY" \
            "$APP/Contents/Helpers/aerospace-cli"
    fi
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY"
else
    if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
        codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
    fi
    codesign --force --sign - "$APP"
    echo "warning: no Apple Development identity found — ad-hoc signed."
    echo "         TCC permission grants to Panewright won't survive rebuilds."
fi

echo "built $APP"

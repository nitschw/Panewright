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

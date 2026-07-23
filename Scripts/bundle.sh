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

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "${IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "warning: no Apple Development identity found — ad-hoc signed."
    echo "         TCC permission grants to Panewright won't survive rebuilds."
fi

echo "built $APP"

#!/bin/bash
# Cut a Panewright release:
#
#   Scripts/release.sh 0.1.0
#
# Bumps versions, tests, bundles, zips, builds a signed disk image, notarizes
# (when a 'panewright-notary'
# keychain profile exists — requires the paid Apple Developer program),
# signs the update for Sparkle, appends the appcast entry, tags, pushes,
# and creates the GitHub release (when `gh` is installed and authed).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version>}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Support/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Support/Info.plist

swift test
Scripts/bundle.sh release

ZIP="build/Panewright-$VERSION.zip"
ditto -c -k --keepParent build/Panewright.app "$ZIP"

if xcrun notarytool history --keychain-profile panewright-notary >/dev/null 2>&1; then
    echo "notarizing…"
    xcrun notarytool submit "$ZIP" --keychain-profile panewright-notary --wait
    xcrun stapler staple build/Panewright.app
    rm "$ZIP"
    ditto -c -k --keepParent build/Panewright.app "$ZIP"
else
    echo "note: notarization skipped — no 'panewright-notary' keychain profile."
    echo "      (Requires the paid Apple Developer program; set up with:"
    echo "       xcrun notarytool store-credentials panewright-notary)"
fi

# The disk image is built *after* stapling, so the .app inside carries its
# notarization ticket and works offline. Homebrew Cask installs from this;
# Sparkle keeps using the zip, which it extracts correctly.
DMG="build/Panewright-$VERSION.dmg"
Scripts/make-dmg.sh "$VERSION"

if xcrun notarytool history --keychain-profile panewright-notary >/dev/null 2>&1; then
    echo "notarizing disk image…"
    xcrun notarytool submit "$DMG" --keychain-profile panewright-notary --wait
    xcrun stapler staple "$DMG"
fi

DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "dmg sha256: $DMG_SHA"

SIGN_UPDATE="$(find .build/artifacts -name sign_update -type f | head -1)"
ED_ATTRS="$("$SIGN_UPDATE" "$ZIP" | tr -d '\n')"
URL="https://github.com/nitschw/Panewright/releases/download/v$VERSION/Panewright-$VERSION.zip"
PUB_DATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"

python3 - "$VERSION" "$BUILD_NUMBER" "$URL" "$ED_ATTRS" "$PUB_DATE" << 'EOF'
import sys
version, build, url, ed_attrs, pub_date = sys.argv[1:6]
item = f"""    <item>
      <title>{version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="{url}" type="application/octet-stream" {ed_attrs} />
    </item>
"""
path = "appcast.xml"
content = open(path).read()
content = content.replace("  </channel>", item + "  </channel>")
open(path, "w").write(content)
print(f"appcast: added {version} ({build})")
EOF

# Maintain the docs release table.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Support/Info.plist)"
python3 - "$VERSION" "$MIN_MACOS" "$URL" << 'EOF'
import sys, datetime
version, min_macos, url = sys.argv[1:4]
# Version history only — the docs deliberately carry no download links;
# Homebrew is the supported install path and Sparkle handles updates.
row = (f'    <tr><td>{version}</td>'
       f'<td>{datetime.date.today().isoformat()}</td>'
       f'<td>{min_macos}+</td></tr>\n')
path = "docs/docs.html"
content = open(path).read()
content = content.replace("    <!-- RELEASES -->\n", "    <!-- RELEASES -->\n" + row)
open(path, "w").write(content)
print(f"docs: release table row added for {version}")
EOF

python3 - "$VERSION" "$DMG_SHA" << 'EOF'
import re, sys
version, sha = sys.argv[1:3]
path = "Casks/panewright.rb"
cask = open(path).read()
cask = re.sub(r'version "[^"]*"', f'version "{version}"', cask, count=1)
cask = re.sub(r'sha256 "[^"]*"', f'sha256 "{sha}"', cask, count=1)
open(path, "w").write(cask)
print(f"cask: updated to {version}")
EOF

git add Support/Info.plist appcast.xml docs/docs.html Casks/panewright.rb
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push && git push --tags

# Push the cask to the tap.
#
# The tap is a separate repository, so a release that only updates the copy in
# this repo leaves `brew install` pointing at the previous version and a
# sha256 that no longer matches — which fails the download rather than
# installing something stale, but fails it for everyone until someone notices.
sync_tap() {
    local tap_dir
    tap_dir="$(mktemp -d)"
    if ! git clone -q git@github.com:nitschw/homebrew-tap.git "$tap_dir" 2>/dev/null; then
        echo "note: couldn't reach the tap — update it by hand:"
        echo "      cp Casks/panewright.rb <tap>/Casks/panewright.rb"
        rm -rf "$tap_dir"
        return
    fi
    cp Casks/panewright.rb "$tap_dir/Casks/panewright.rb"
    # A fresh clone has no identity — Will's lives in per-repo config, so
    # without these the commit dies with "Author identity unknown" and the
    # tap silently keeps shipping the previous release.
    git -C "$tap_dir" config user.email "$(git config user.email)"
    git -C "$tap_dir" config user.name "$(git config user.name)"
    if git -C "$tap_dir" diff --quiet; then
        echo "tap: already up to date"
    else
        git -C "$tap_dir" add Casks/panewright.rb
        git -C "$tap_dir" commit -q -m "panewright $VERSION"
        git -C "$tap_dir" push -q origin HEAD
        echo "tap: published $VERSION"
    fi
    rm -rf "$tap_dir"
}

if command -v gh >/dev/null 2>&1; then
    gh release create "v$VERSION" "$ZIP" "$DMG" \
        --title "Panewright $VERSION" --generate-notes
    # After the release exists, so the cask never points at a missing asset.
    sync_tap
else
    echo
    echo "gh not installed — create the release manually:"
    echo "  brew install gh && gh auth login"
    echo "  gh release create v$VERSION $ZIP $DMG --title 'Panewright $VERSION' --generate-notes"
    echo "(The appcast points at that release URL; updates go live when it exists.)"
fi

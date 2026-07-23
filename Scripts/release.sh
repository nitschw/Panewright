#!/bin/bash
# Cut a Panewright release:
#
#   Scripts/release.sh 0.1.0
#
# Bumps versions, tests, bundles, zips, notarizes (when a 'panewright-notary'
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
row = (f'    <tr><td>{version}</td>'
       f'<td>{datetime.date.today().isoformat()}</td>'
       f'<td>{min_macos}+</td>'
       f'<td><a href="{url}">Panewright-{version}.zip</a></td></tr>\n')
path = "docs/docs.html"
content = open(path).read()
content = content.replace("    <!-- RELEASES -->\n", "    <!-- RELEASES -->\n" + row)
open(path, "w").write(content)
print(f"docs: release table row added for {version}")
EOF

git add Support/Info.plist appcast.xml docs/docs.html
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push && git push --tags

if command -v gh >/dev/null 2>&1; then
    gh release create "v$VERSION" "$ZIP" --title "Panewright $VERSION" --generate-notes
else
    echo
    echo "gh not installed — create the release manually:"
    echo "  brew install gh && gh auth login"
    echo "  gh release create v$VERSION $ZIP --title 'Panewright $VERSION' --generate-notes"
    echo "(The appcast points at that release URL; updates go live when it exists.)"
fi

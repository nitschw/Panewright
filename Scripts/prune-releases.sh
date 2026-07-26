#!/bin/bash
# Trim old releases, and the two places that reference them.
#
#   Scripts/prune-releases.sh [--keep N] [--delete-tags] [--yes]
#
# Deleting a GitHub release on its own is a trap: the appcast keeps advertising
# its download, so Sparkle offers an update whose enclosure 404s. The docs
# release table keeps linking it too. So all three move together, or none do.
#
# Safe for people on old versions: Sparkle picks the newest item in the feed,
# so someone still on 0.1.0 updates straight to the latest whether or not
# 0.1.0's own entry survives. Old entries are history, not upgrade path.
set -euo pipefail
cd "$(dirname "$0")/.."

KEEP=5
DELETE_TAGS=false
ASSUME_YES=false
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
        --delete-tags) DELETE_TAGS=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { echo "needs gh" >&2; exit 1; }

# Newest first, as GitHub orders them.
ALL=$(gh release list --limit 200 --json tagName --jq '.[].tagName')
TOTAL=$(printf '%s\n' "$ALL" | grep -c . || true)
DOOMED=$(printf '%s\n' "$ALL" | tail -n +$((KEEP + 1)))
DOOMED_COUNT=$(printf '%s\n' "$DOOMED" | grep -c . || true)

echo "$TOTAL releases, keeping the newest $KEEP."
if [ "$DOOMED_COUNT" -eq 0 ]; then
    echo "Nothing to remove."
    exit 0
fi
echo "Would remove $DOOMED_COUNT:"
printf '  %s\n' $DOOMED

if ! $ASSUME_YES; then
    echo
    read -r -p "Delete these releases, their appcast entries and docs rows? [y/N] " reply
    case "$reply" in [yY]*) ;; *) echo "Nothing changed."; exit 0 ;; esac
fi

for tag in $DOOMED; do
    if $DELETE_TAGS; then
        gh release delete "$tag" --yes --cleanup-tag >/dev/null
    else
        # Keeping the tag leaves the history navigable; only the published
        # release and its assets go.
        gh release delete "$tag" --yes >/dev/null
    fi
    echo "  removed release $tag"
done

python3 - "$DOOMED" << 'PY'
import re, sys

# Tags are "v0.1.0"; the files record bare versions.
versions = {t.lstrip("v") for t in sys.argv[1].split() if t.strip()}

appcast = open("appcast.xml").read()
removed = 0
for version in versions:
    # Match a whole <item> whose shortVersionString is this one, so an item
    # is never half-removed and the feed stays parseable.
    pattern = re.compile(
        r"[ \t]*<item>(?:(?!</item>).)*?"
        r"<sparkle:shortVersionString>" + re.escape(version) +
        r"</sparkle:shortVersionString>(?:(?!</item>).)*?</item>\n?",
        re.DOTALL,
    )
    appcast, n = pattern.subn("", appcast)
    removed += n
open("appcast.xml", "w").write(appcast)
print(f"appcast: removed {removed} item(s)")

docs = open("docs/docs.html").read()
rows = 0
for version in versions:
    pattern = re.compile(
        r"[ \t]*<tr><td>" + re.escape(version) + r"</td>.*?</tr>\n?", re.DOTALL)
    docs, n = pattern.subn("", docs)
    rows += n
open("docs/docs.html", "w").write(docs)
print(f"docs: removed {rows} table row(s)")
PY

echo
echo "appcast.xml and docs/docs.html edited — review and commit:"
echo "  git diff --stat appcast.xml docs/docs.html"

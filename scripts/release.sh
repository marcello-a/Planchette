#!/bin/sh
# Cut a stable release from master and publish it so the in-app updater finds it.
#
#   scripts/release.sh X.Y.Z
#
# Steps:
#   1. Verify you're on master with a clean tree.
#   2. Tag vX.Y.Z and push the tag.
#   3. Build dist/Planchette.dmg at that version.
#   4. Create a GitHub Release for the tag and upload the DMG as an asset.
#
# The updater (UpdateService) queries /releases/latest and compares the tag to
# the running app's CFBundleShortVersionString, so uploading the DMG here is
# what makes "new stable version in master → offered as update" work.
#
# Requires: gh (authenticated), a clean master.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Version comes from the argument, else the VERSION file (same source CI uses).
VERSION="${1:-}"
[ -n "$VERSION" ] || VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null)"
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh [X.Y.Z]  (or set VERSION file)" >&2; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "master" ] || [ "$BRANCH" = "main" ] || {
    echo "error: releases are cut from master/main (you're on $BRANCH)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "error: working tree not clean" >&2; exit 1; }

TAG="v$VERSION"
git tag -a "$TAG" -m "Planchette $VERSION"
git push origin "$TAG"

sh scripts/package.sh "$VERSION"

# Release notes = this version's CHANGELOG section. The app reads them back off
# the release body and shows the entry titles in the update dialog
# (ReleaseNotes.swift), so "what's new" has exactly one source.
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT INT TERM
awk -v ver="$VERSION" '
    $0 ~ "^## \\[" ver "\\]" { inside = 1; next }
    inside && /^## \[/       { exit }
    inside                    { print }
' CHANGELOG.md | sed -e '/^$/{ /./!d; }' > "$NOTES"
if [ ! -s "$NOTES" ]; then
    echo "warning: no CHANGELOG section for $VERSION — publishing without notes" >&2
fi
cat >> "$NOTES" <<EOF

---
Existing users get this automatically via the in-app updater (Install & Relaunch).
New users: \`curl -fsSL https://raw.githubusercontent.com/$(git config --get remote.origin.url | sed -E 's#.*github.com[:/]([^/]+/[^.]+)(\.git)?#\1#')/main/scripts/install.sh | sh\`
EOF

gh release create "$TAG" \
    "dist/Planchette.dmg" \
    "dist/Planchette.zip" \
    "dist/screen-rules.json" \
    "dist/SHA256SUMS" \
    --title "Planchette $VERSION" \
    --notes-file "$NOTES" \
    --target "$BRANCH"

echo "→ released $TAG with dist/Planchette.dmg"
echo "  Users on older versions will be offered this update on next launch."

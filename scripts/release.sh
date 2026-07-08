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

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh X.Y.Z" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "master" ] || [ "$BRANCH" = "main" ] || {
    echo "error: releases are cut from master/main (you're on $BRANCH)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "error: working tree not clean" >&2; exit 1; }

TAG="v$VERSION"
git tag -a "$TAG" -m "Planchette $VERSION"
git push origin "$TAG"

sh scripts/package.sh "$VERSION"

gh release create "$TAG" \
    "dist/Planchette.dmg" \
    --title "Planchette $VERSION" \
    --notes "Stable release $VERSION. Download Planchette.dmg and drag it into Applications." \
    --target "$BRANCH"

echo "→ released $TAG with dist/Planchette.dmg"
echo "  Users on older versions will be offered this update on next launch."

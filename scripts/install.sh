#!/bin/sh
# Install or update Planchette from its GitHub releases.
#
#   sh install.sh              # latest stable
#   sh install.sh 0.2.15       # a specific version
#   PLANCHETTE_DEST=~/Applications sh install.sh
#
# What it does that dragging the DMG does not: it verifies the download against
# the release's SHA256SUMS, and it strips the quarantine flag afterwards. The
# app is ad-hoc signed (no paid Developer ID, so no notarization), and macOS
# blocks a quarantined app from an "unidentified developer" on first launch.
# Removing the flag is the same decision as clicking "Open Anyway" in System
# Settings — do it only because you trust this source, and the checksum above
# is what tells you the bytes are the ones the release published.
set -eu

REPO="marcello-a/Planchette"
DEST="${PLANCHETTE_DEST:-/Applications}"
VERSION="${1:-}"

if [ -n "$VERSION" ]; then
    BASE="https://github.com/$REPO/releases/download/v${VERSION#v}"
    LABEL="v${VERSION#v}"
else
    # GitHub redirects this to whatever the latest release is — no API, no token.
    BASE="https://github.com/$REPO/releases/latest/download"
    LABEL="the latest release"
fi

# Replacing a bundle while it runs corrupts the running app: let the user quit
# it themselves rather than killing agents that may be mid-turn.
if pgrep -f "$DEST/Planchette.app/Contents/MacOS/Planchette" >/dev/null 2>&1; then
    echo "Planchette is running from $DEST — quit it first, then run this again." >&2
    echo "(Durable terminals survive the quit; ordinary ones do not.)" >&2
    exit 1
fi

TMP="$(mktemp -d)"
MOUNT=""
cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "→ downloading Planchette ($LABEL)"
curl -fsSL "$BASE/Planchette.dmg" -o "$TMP/Planchette.dmg"
curl -fsSL "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS"

echo "→ verifying checksum"
( cd "$TMP" && grep ' Planchette\.dmg$' SHA256SUMS | shasum -a 256 -c - ) || {
    echo "checksum mismatch — refusing to install this download" >&2
    exit 1
}

echo "→ mounting"
MOUNT="$(hdiutil attach "$TMP/Planchette.dmg" -nobrowse -readonly -quiet -mountpoint "$TMP/mnt" >/dev/null 2>&1 && echo "$TMP/mnt")"
[ -d "$MOUNT/Planchette.app" ] || { echo "no Planchette.app in the disk image" >&2; exit 1; }

echo "→ installing into $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/Planchette.app"
ditto "$MOUNT/Planchette.app" "$DEST/Planchette.app"

# The actual "unidentified developer" bypass: without this, the first launch is
# blocked and has to be approved by hand in System Settings.
xattr -dr com.apple.quarantine "$DEST/Planchette.app" 2>/dev/null || true

VERSION_INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$DEST/Planchette.app/Contents/Info.plist" 2>/dev/null || echo "?")"
echo
echo "✔ Planchette $VERSION_INSTALLED installed in $DEST"
echo "  open \"$DEST/Planchette.app\""

#!/bin/sh
# Builds Planchette.app and Planchette.dmg.
#
#   scripts/package.sh [version]
#
# version defaults to the current git tag (vX.Y.Z → X.Y.Z) or 0.0.0-dev.
# Produces:
#   dist/Planchette.app   — double-clickable, drag to /Applications
#   dist/Planchette.dmg   — distributable disk image with an Applications alias
#   dist/Planchette.zip   — the .app zipped (used by the in-app auto-updater)
#   dist/SHA256SUMS       — checksums the updater verifies the download against
#
# The GhosttyKit static lib is linked into the executable, so the only runtime
# data we must bundle is the Ghostty resources dir (terminfo, shell
# integration); GhosttyRuntime points at it inside the bundle automatically.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/macos/Planchette"
GHOSTTY_SHARE="$ROOT/vendor/ghostty/zig-out/share/ghostty"
DIST="$ROOT/dist"
APP="$DIST/Planchette.app"
BUNDLE_ID="build.planchette.app"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
    [ -z "$VERSION" ] && VERSION="0.0.0-dev"
fi
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "→ building Planchette $VERSION (build $BUILD)"

[ -d "$GHOSTTY_SHARE" ] || {
    echo "error: $GHOSTTY_SHARE missing — build GhosttyKit first:" >&2
    echo "  cd vendor/ghostty && ../../.tooling/zig/zig build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast" >&2
    exit 1
}

# 1. Release build of the executable.
( cd "$PKG" && swift build -c release )
EXE="$(cd "$PKG" && swift build -c release --show-bin-path)/Planchette"

# 2. Assemble the .app bundle.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/Planchette"
cp -R "$GHOSTTY_SHARE" "$APP/Contents/Resources/ghostty"
# terminfo (sibling of the ghostty resources dir) so `xterm-ghostty` resolves.
if [ -d "$GHOSTTY_SHARE/../terminfo" ]; then
    cp -R "$GHOSTTY_SHARE/../terminfo" "$APP/Contents/Resources/terminfo"
fi
[ -f "$PKG/Resources/AppIcon.icns" ] && cp "$PKG/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Bundle the Claude Code hook script so the app can auto-install it on launch.
cp "$ROOT/hook/planchette-hook" "$APP/Contents/Resources/planchette-hook"
chmod +x "$APP/Contents/Resources/planchette-hook"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Planchette</string>
    <key>CFBundleDisplayName</key><string>Planchette</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Planchette</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Planchette reads the working directories of your open iTerm2 and Terminal windows to migrate them.</string>
</dict>
</plist>
PLIST

# 3. Ad-hoc codesign so Gatekeeper lets it run locally. For distribution to
#    others, replace with a Developer ID identity + notarization.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (ad-hoc codesign skipped)"

echo "→ built $APP"

# 4. Build the DMG (staging folder with an Applications alias).
DMG="$DIST/Planchette.dmg"
STAGE="$(mktemp -d)/Planchette"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Planchette" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "→ built $DMG"

# 5. Zip the .app for the in-app updater (ditto preserves the bundle + signature).
ZIP="$DIST/Planchette.zip"
rm -f "$ZIP"
( cd "$DIST" && ditto -c -k --keepParent "Planchette.app" "Planchette.zip" )
echo "→ built $ZIP"

# 6. Checksums the updater verifies the download against.
( cd "$DIST" && shasum -a 256 "Planchette.zip" "Planchette.dmg" > "SHA256SUMS" )
echo "→ built $DIST/SHA256SUMS"
echo
echo "Install: open dist/Planchette.dmg and drag Planchette to Applications."

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
# "-" signs ad-hoc. A Developer ID identity here signs the app and the hook helper
# alike, with the hardened runtime and a timestamp (step 3).
SIGN_IDENTITY="-"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
    [ -z "$VERSION" ] && VERSION="0.0.0-dev"
fi
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "→ building Planchette $VERSION (build $BUILD)"

[ -d "$GHOSTTY_SHARE" ] || {
    echo "error: $GHOSTTY_SHARE missing — build GhosttyKit first:" >&2
    echo "  sh scripts/apply-ghostty-patches.sh && cd vendor/ghostty && ../../.tooling/zig/zig build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast" >&2
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
# The Claude Code hook forwarder, which the app installs on launch (HookInstaller.deployHook):
# the native helper, universal and built warning-free from hook/planchette-hook.c, and the
# shell script it replaces, installed instead where the helper does not run. Code goes in
# Contents/Helpers, where codesign treats it as nested code, not as a resource file.
mkdir -p "$APP/Contents/Helpers"
# --no-werror: a warning from a newer clang must not stop a release. CI's tests build the
# same source with every warning an error before this runs.
sh "$ROOT/hook/build-hook-helper.sh" --no-werror "$APP/Contents/Helpers/planchette-hook"
cp "$ROOT/hook/planchette-hook" "$APP/Contents/Resources/planchette-hook"
chmod +x "$APP/Contents/Resources/planchette-hook"
# The control CLI agents use to drive Planchette (see skills/planchette).
cp "$ROOT/hook/planchette" "$APP/Contents/Resources/planchette"
chmod +x "$APP/Contents/Resources/planchette"
# Detection rules are bundled AND published as their own release asset, so a
# pattern fix reaches users without a new binary (see docs/LIVE-UPDATE.md).
cp "$ROOT/rules/screen-rules.json" "$APP/Contents/Resources/screen-rules.json"
# The default review-pr skill, installed when a user without their own starts a review (ReviewSkill).
mkdir -p "$APP/Contents/Resources/skills"
cp -R "$ROOT/skills/review-pr" "$APP/Contents/Resources/skills/review-pr"
find "$APP/Contents/Resources/skills" -name __pycache__ -prune -exec rm -rf {} +
# The pictures of the feature hints (hints/<name>.gif).
[ -d "$ROOT/hints" ] && cp -R "$ROOT/hints" "$APP/Contents/Resources/hints"

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

# 3. Codesign. Ad-hoc (SIGN_IDENTITY="-") so Gatekeeper lets it run locally. For
#    distribution to others, set SIGN_IDENTITY to a Developer ID identity; notarizing
#    the result (`xcrun notarytool submit`, then `xcrun stapler staple`) is still a
#    step of its own. Not tried with a real identity yet: under the hardened runtime
#    the iTerm2 / Terminal migration (AppleScript) also needs the
#    com.apple.security.automation.apple-events entitlement.
# Signing must succeed: Apple Silicon SIGKILLs an unsigned arm64 binary at exec, so a
# build that skipped signing would ship an app that cannot launch. Fail the build
# rather than publish it.
#
# Ad-hoc, the designated requirement is pinned to the bundle identifier. Left to
# itself, an ad-hoc signature's requirement is the cdhash of this exact build, and
# macOS keys every privacy answer (Documents, Desktop, Downloads, network volumes, ...)
# on that requirement: each update became a new app, and every terminal asked for its
# folders again. With the identifier, an answer survives updates. The price: any ad-hoc
# app that claims this identifier matches too. Only a Developer ID signature closes
# that, with its default requirement (the identifier AND the team's certificate), so
# that one is left alone: pinning it to the identifier would drop the team anchor. A
# Developer ID signature also gets the hardened runtime and a secure timestamp, which
# notarization requires.
#
# No --deep: it would stamp the app's requirement on the nested hook helper too. The
# helper is signed first, on its own and with its own identifier; the app's signature
# then seals it as nested code.
sign() {   # sign <path> <identifier>
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - -i "$2" -r="designated => identifier \"$2\"" "$1"
    else
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp -i "$2" "$1"
    fi
}
HELPER="$APP/Contents/Helpers/planchette-hook"
sign "$HELPER" "$BUNDLE_ID.hook" || {
    echo "codesign of the hook helper failed — refusing to package an unsigned bundle" >&2
    exit 1
}
sign "$APP" "$BUNDLE_ID" || {
    echo "codesign failed — refusing to package an unsigned bundle" >&2
    exit 1
}
# The check the in-app updater makes on a download (UpdateService), nested code included.
codesign --verify --deep --strict "$APP" || {
    echo "the signed bundle does not verify (is the hook helper sealed?)" >&2
    exit 1
}
# Ad-hoc: the pinned requirement. Developer ID: its default requirement starts the same way.
codesign -d -r- "$APP" 2>&1 | grep -qF "designated => identifier \"$BUNDLE_ID\"" || {
    echo "codesign did not pin the designated requirement — every update would ask for permissions again" >&2
    exit 1
}
# The signed helper must start: without PLANCHETTE_SESSION it is a no-op that exits 0.
env -i "$HELPER" claude < /dev/null || {
    echo "the signed hook helper does not run" >&2
    exit 1
}

echo "→ built $APP"

# 4. Build the DMG (staging folder with an Applications alias).
DMG="$DIST/Planchette.dmg"
STAGE="$(mktemp -d)/Planchette"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
# `create -srcfolder` attaches a device to lay the volume out, which not every
# environment allows (it fails with "Resource busy" where disk-image attachment
# is restricted). `makehybrid` writes the filesystem directly, no attach — so it
# is the fallback rather than the default, keeping the well-trodden path first.
if ! hdiutil create -volname "Planchette" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1; then
    echo "  (hdiutil create could not attach a device — building via makehybrid)"
    RAW="$(mktemp -d)/raw.dmg"
    hdiutil makehybrid -hfs -hfs-volume-name "Planchette" -o "$RAW" "$STAGE" >/dev/null
    hdiutil convert "$RAW" -format UDZO -o "$DMG" >/dev/null
    rm -f "$RAW"
fi
echo "→ built $DMG"

# 5. Zip the .app for the in-app updater (ditto preserves the bundle + signature).
ZIP="$DIST/Planchette.zip"
rm -f "$ZIP"
( cd "$DIST" && ditto -c -k --keepParent "Planchette.app" "Planchette.zip" )
echo "→ built $ZIP"

# 6. Checksums the updater verifies the download against.
cp "$ROOT/rules/screen-rules.json" "$DIST/screen-rules.json"
echo "→ built $DIST/screen-rules.json"
( cd "$DIST" && shasum -a 256 "Planchette.zip" "Planchette.dmg" "screen-rules.json" > "SHA256SUMS" )
echo "→ built $DIST/SHA256SUMS"
echo
echo "Install: open dist/Planchette.dmg and drag Planchette to Applications."

#!/bin/sh
# Renders the app icon into macos/Planchette/Resources/AppIcon.icns.
# Uses macos/Planchette/Resources/icon-1024.png (AI-generated artwork) as the
# source, masked to the macOS squircle with transparent margins. Falls back to
# the 🔮 emoji renderer if the PNG is missing. Regenerate only when the icon
# changes. Requires macOS (uses `iconutil` and a tiny Swift renderer).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/macos/Planchette/Resources"
SRC_PNG="$OUT_DIR/icon-1024.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$OUT_DIR"

render() { # size file
    swift - "$1" "$2" "$SRC_PNG" <<'SWIFT'
import AppKit
let size = Double(CommandLine.arguments[1])!
let path = CommandLine.arguments[2]
let srcPath = CommandLine.arguments[3]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: size*0.06, dy: size*0.06),
                            xRadius: size*0.22, yRadius: size*0.22)
if let src = NSImage(contentsOfFile: srcPath) {
    squircle.addClip()
    src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
} else {
    NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.16, alpha: 1).setFill()
    squircle.fill()
    let emoji = "🔮" as NSString
    let font = NSFont.systemFont(ofSize: size*0.62)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let s = emoji.size(withAttributes: attrs)
    emoji.draw(at: NSPoint(x: (size-s.width)/2, y: (size-s.height)/2 - size*0.02), withAttributes: attrs)
}
image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: path))
SWIFT
}

for s in 16 32 64 128 256 512 1024; do
    render "$s" "$ICONSET/icon_${s}x${s}.png"
done
# @2x variants
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICONSET/icon_64x64.png"

iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
echo "wrote $OUT_DIR/AppIcon.icns"

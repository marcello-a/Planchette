#!/bin/sh
# Renders the app icon into macos/Planchette/Resources/AppIcon.icns following
# Apple's macOS icon guidelines: an 824/1024 squircle (corner radius ~185/1024)
# with a subtle baked drop shadow, purple-black fill, and the AI-generated
# white planchette glyph (macos/Planchette/Resources/icon-glyph.png, white on
# transparent) composited on top. Falls back to the 🔮 emoji if the glyph PNG
# is missing. Requires macOS (uses `iconutil` and a tiny Swift renderer).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/macos/Planchette/Resources"
GLYPH_PNG="$OUT_DIR/icon-glyph.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$OUT_DIR"

render() { # size file
    swift - "$1" "$2" "$GLYPH_PNG" <<'SWIFT'
import AppKit
let size = Double(CommandLine.arguments[1])!
let path = CommandLine.arguments[2]
let glyphPath = CommandLine.arguments[3]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
// Apple macOS icon grid: 824x824 squircle centered on a 1024 canvas,
// corner radius ~185.4, drop shadow y-offset -10 / blur 25 (at 1024).
let inset = size * 100.0/1024.0
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
let radius = size * 185.4/1024.0
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -size * 10.0/1024.0)
shadow.shadowBlurRadius = size * 25.0/1024.0
shadow.set()
// dark purple
NSColor(calibratedRed: 0x2E/255.0, green: 0x1A/255.0, blue: 0x52/255.0, alpha: 1).setFill()
squircle.fill()
NSGraphicsContext.current!.restoreGraphicsState()
if let glyphRep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: glyphPath))) {
    // the glyph artwork carries generous transparent padding, so crop to the
    // alpha bounding box, then scale the visible glyph to ~70% of the squircle
    let w = glyphRep.pixelsWide, h = glyphRep.pixelsHigh
    var minX = w, minY = h, maxX = 0, maxY = 0
    let data = glyphRep.bitmapData!
    let spp = glyphRep.samplesPerPixel, bpr = glyphRep.bytesPerRow
    for y in 0..<h {
        for x in 0..<w where data[y*bpr + x*spp + spp - 1] > 16 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
    // source rect in image coordinates (flipped y)
    let src = NSRect(x: Double(minX), y: Double(h - 1 - maxY), width: bw, height: bh)
    let target = rect.width * 0.70
    let scale = min(target / bw, target / bh)
    let g = NSRect(x: rect.midX - bw*scale/2, y: rect.midY - bh*scale/2,
                   width: bw*scale, height: bh*scale)
    let glyph = NSImage(size: NSSize(width: w, height: h))
    glyph.addRepresentation(glyphRep)
    squircle.addClip()
    glyph.draw(in: g, from: src, operation: .sourceOver, fraction: 1.0)
} else {
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

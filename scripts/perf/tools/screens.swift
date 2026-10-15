import AppKit
// usage: screens  -> "x y width height scale" of the visible frame of each display, one line each
// (AppKit coordinates, origin at the bottom left of the main display: what a saved window frame uses).
for screen in NSScreen.screens {
    let f = screen.visibleFrame
    print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height), Int(screen.backingScaleFactor))
}

import CoreGraphics
import Foundation
// usage: winlist2 <pid>  -> "id layer WxH alpha name" for each on-screen window of that process
let pid = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? 0
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any]
    let id = w[kCGWindowNumber as String] ?? "?"
    let layer = w[kCGWindowLayer as String] ?? "?"
    let alpha = w[kCGWindowAlpha as String] ?? "?"
    let name = (w[kCGWindowName as String] as? String) ?? ""
    print("\(id) layer=\(layer) \(Int((b?["Width"] as? Double) ?? 0))x\(Int((b?["Height"] as? Double) ?? 0)) alpha=\(alpha) name=\(name)")
}

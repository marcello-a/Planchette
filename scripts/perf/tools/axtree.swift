import ApplicationServices
import Foundation

// usage: axtree <pid> [maxDepth]
// Prints every accessibility element of the process, one JSON object per line:
//   {"d":depth,"role":..,"sub":..,"title":..,"desc":..,"value":..,"enabled":..,"x":..,"y":..,"w":..,"h":..}
// Frames are in global display coordinates (origin top left), the ones CGEvent uses.
// Needs the Accessibility permission for the process that runs it.

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String {
    (attr(element, name) as? String) ?? ""
}

func point(_ element: AXUIElement) -> CGPoint? {
    guard let raw = attr(element, kAXPositionAttribute as String) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(raw as! AXValue, .cgPoint, &p) ? p : nil
}

func size(_ element: AXUIElement) -> CGSize? {
    guard let raw = attr(element, kAXSizeAttribute as String) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(raw as! AXValue, .cgSize, &s) ? s : nil
}

func json(_ string: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [string], options: [])
    let array = String(data: data ?? Data(), encoding: .utf8) ?? "[\"\"]"
    return String(array.dropFirst().dropLast())
}

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    FileHandle.standardError.write(Data("usage: axtree <pid> [maxDepth]\n".utf8))
    exit(2)
}
let maxDepth = args.count > 2 ? Int(args[2]) ?? 30 : 30
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("not trusted for accessibility\n".utf8))
    exit(3)
}

var visited = 0
func walk(_ element: AXUIElement, depth: Int) {
    guard depth <= maxDepth, visited < 20000 else { return }
    visited += 1
    let p = point(element), s = size(element)
    var value = ""
    if let raw = attr(element, kAXValueAttribute as String) {
        value = (raw as? String) ?? ((raw as? NSNumber).map { "\($0)" } ?? "")
    }
    print("{\"d\":\(depth),\"role\":\(json(text(element, kAXRoleAttribute as String))),"
        + "\"sub\":\(json(text(element, kAXSubroleAttribute as String))),"
        + "\"title\":\(json(text(element, kAXTitleAttribute as String))),"
        + "\"desc\":\(json(text(element, kAXDescriptionAttribute as String))),"
        + "\"value\":\(json(value)),"
        + "\"enabled\":\((attr(element, kAXEnabledAttribute as String) as? Bool) ?? true),"
        + "\"x\":\(Int(p?.x ?? -1)),\"y\":\(Int(p?.y ?? -1)),\"w\":\(Int(s?.width ?? 0)),\"h\":\(Int(s?.height ?? 0))}")
    if let children = attr(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children { walk(child, depth: depth + 1) }
    }
}

walk(AXUIElementCreateApplication(pid), depth: 0)

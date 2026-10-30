import ApplicationServices
import Foundation

// usage: axpress <pid> <text> [nth]
// Presses (kAXPressAction) the nth (default 0) button, radio button or checkbox of the process
// whose title, description or value equals <text> — or, with <text> ending in "*", starts with
// it. No mouse, no keyboard: the pointer you work with stays where it is.
// Exit 0 pressed, 1 not found, 3 not trusted for accessibility.

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String {
    (attr(element, name) as? String) ?? ""
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    FileHandle.standardError.write(Data("usage: axpress <pid> <text> [nth]\n".utf8))
    exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("not trusted for accessibility\n".utf8))
    exit(3)
}
let wanted = args[2]
var skip = args.count > 3 ? Int(args[3]) ?? 0 : 0
let prefix = wanted.hasSuffix("*") ? String(wanted.dropLast()) : nil
let roles: Set<String> = ["AXButton", "AXRadioButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle"]

func matches(_ element: AXUIElement) -> Bool {
    guard roles.contains(text(element, kAXRoleAttribute as String)) else { return false }
    let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { text(element, $0 as String) }
    return names.contains { prefix.map($0.hasPrefix) ?? ($0 == wanted) }
}

var visited = 0
func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth <= 40, visited < 20000 else { return nil }
    visited += 1
    if matches(element) {
        if skip == 0 { return element }
        skip -= 1
    }
    for child in (attr(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] {
        if let hit = find(child, depth: depth + 1) { return hit }
    }
    return nil
}

guard let hit = find(AXUIElementCreateApplication(pid), depth: 0) else { exit(1) }
exit(AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success ? 0 : 1)

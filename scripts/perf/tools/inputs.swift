import ApplicationServices
import Foundation

// usage: inputs <command> ...
//   move X Y
//   click X Y [count]
//   rclick X Y
//   drag X1 Y1 X2 Y2 [steps=40] [holdMs=300]     press, wait, move in steps, wait, release
//   dragpath holdMs X1 Y1 X2 Y2 X3 Y3 ...        press at the first point, visit the others, release at the last
//   key <char|name> [cmd] [shift] [opt] [ctrl]   a key press (a, d, t, w, return, escape, tab)
//   type <text>                                  the text, typed key by key as Unicode
// Coordinates are global display coordinates, origin top left. The pointer goes back where it was.

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "return": 36, "tab": 48, "space": 49, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
]

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { exit(2) }
func number(_ i: Int, _ fallback: Double? = nil) -> Double {
    if i < args.count, let v = Double(args[i]) { return v }
    if let fallback { return fallback }
    FileHandle.standardError.write(Data("missing number at \(i)\n".utf8)); exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("not trusted for accessibility\n".utf8)); exit(3)
}

let source = CGEventSource(stateID: .hidSystemState)
let origin = CGEvent(source: nil)?.location ?? .zero
func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }
func sleepMs(_ ms: Double) { usleep(UInt32(ms * 1000)) }
func mouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks)
    post(e)
}
func move(to p: CGPoint) { mouse(.mouseMoved, p) }

switch command {
case "move":
    move(to: CGPoint(x: number(1), y: number(2)))
case "click":
    let p = CGPoint(x: number(1), y: number(2))
    move(to: p); sleepMs(80)
    for n in 1...Int(number(3, 1)) {
        mouse(.leftMouseDown, p, clicks: Int64(n)); sleepMs(40)
        mouse(.leftMouseUp, p, clicks: Int64(n)); sleepMs(60)
    }
case "rclick":
    let p = CGPoint(x: number(1), y: number(2))
    move(to: p); sleepMs(80)
    mouse(.rightMouseDown, p, button: .right); sleepMs(40)
    mouse(.rightMouseUp, p, button: .right)
case "drag", "dragpath":
    var points: [CGPoint] = []
    var hold = 300.0, steps = 40
    if command == "drag" {
        points = [CGPoint(x: number(1), y: number(2)), CGPoint(x: number(3), y: number(4))]
        steps = Int(number(5, 40)); hold = number(6, 300)
    } else {
        hold = number(1)
        var i = 2
        while i + 1 < args.count { points.append(CGPoint(x: number(i), y: number(i + 1))); i += 2 }
    }
    guard points.count >= 2 else { exit(2) }
    move(to: points[0]); sleepMs(120)
    mouse(.leftMouseDown, points[0]); sleepMs(hold)
    // Move along the polyline: from each point to the next, in `steps` small moves.
    var from = points[0]
    for target in points.dropFirst() {
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let p = CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
            mouse(.leftMouseDragged, p); sleepMs(14)
        }
        from = target
        sleepMs(220)   // let the drop zone under the pointer react before the next leg
    }
    sleepMs(Double(ProcessInfo.processInfo.environment["HOVER_MS"] ?? "") ?? 250)   // HOVER_MS: stay over the target
    mouse(.leftMouseUp, from)
case "key":
    guard args.count >= 2, let code = keyCodes[args[1].lowercased()] else { exit(2) }
    var flags = CGEventFlags()
    for mod in args.dropFirst(2) {
        switch mod {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        post(e); sleepMs(50)
    }
case "type":
    // Real key codes for what a test types (letters, digits, space, dash): Ghostty reads the key
    // that was pressed, not the Unicode string an event carries. Anything else goes as Unicode.
    var extra: [Character: CGKeyCode] = [" ": 49, "-": 27]
    for (name, code) in keyCodes where name.count == 1 { extra[Character(name)] = code }
    for ch in (args.count > 1 ? args[1] : "") {
        for down in [true, false] {
            if let code = extra[ch] {
                post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down))
            } else {
                let units = Array(String(ch).utf16)
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(e)
            }
            sleepMs(25)
        }
    }
default:
    FileHandle.standardError.write(Data("unknown command\n".utf8)); exit(2)
}
sleepMs(150)
move(to: origin)

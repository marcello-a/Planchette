import ApplicationServices
import Carbon.HIToolbox
import Foundation

// usage: inputs <command> ...
//   where                                         prints the pointer position: "X Y"
//   move X Y
//   click X Y [count]
//   rclick X Y
//   optclick X Y                                  a click with ⌥ held
//   drag X1 Y1 X2 Y2 [steps=40] [holdMs=300]     press, wait, move in steps, wait, release
//   dragpath holdMs X1 Y1 X2 Y2 X3 Y3 ...        press at the first point, visit the others, release at the last
//   key <char|name> [cmd] [shift] [opt] [ctrl]   a key press (a, d, t, w, return, escape, tab)
//   type <text>                                  the text, typed key by key as Unicode
// Coordinates are global display coordinates, origin top left. The pointer goes back where it was —
// unless KEEP_POINTER is set: a pointer that returns over another app can pull that app's focus
// (iTerm2's "focus follows mouse"), and the next key press then goes to the wrong app.

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "return": 36, "tab": 48, "space": 49, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
]

/// The key that types `character` in the keyboard layout that is active now — a German layout puts
/// y and z where an American one has z and y, and a key code is a place on the keyboard, not a letter.
/// Falls back to the fixed table (and nil for what no key types).
func keyCode(for character: Character) -> CGKeyCode? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        return keyCodes[String(character).lowercased()]
    }
    let layout = unsafeBitCast(raw, to: CFData.self)
    let data = CFDataGetBytePtr(layout)
    let target = String(character)
    for code in 0..<128 {
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data!.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == target {
            return CGKeyCode(code)
        }
    }
    return keyCodes[target.lowercased()]
}

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
/// A modifier key going down or up: `flags` is what is held afterwards.
func flagsChanged(_ code: CGKeyCode, _ flags: CGEventFlags) {
    let e = CGEvent(source: source)
    e?.type = .flagsChanged
    e?.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
    e?.flags = flags
    post(e); sleepMs(30)
}

switch command {
case "where":
    print(Int(origin.x), Int(origin.y))
    exit(0)
case "move":
    move(to: CGPoint(x: number(1), y: number(2)))
case "click":
    let p = CGPoint(x: number(1), y: number(2))
    move(to: p); sleepMs(80)
    for n in 1...Int(number(3, 1)) {
        mouse(.leftMouseDown, p, clicks: Int64(n)); sleepMs(40)
        mouse(.leftMouseUp, p, clicks: Int64(n)); sleepMs(60)
    }
case "optclick":
    let p = CGPoint(x: number(1), y: number(2))
    move(to: p); sleepMs(80)
    flagsChanged(58, .maskAlternate)
    for down in [true, false] {
        let e = CGEvent(mouseEventSource: source, mouseType: down ? .leftMouseDown : .leftMouseUp,
                        mouseCursorPosition: p, mouseButton: .left)
        e?.flags = .maskAlternate
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(e); sleepMs(40)
    }
    flagsChanged(58, CGEventFlags())
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
    let name = args.count >= 2 ? args[1].lowercased() : ""
    guard args.count >= 2, let code = (name.count == 1 ? keyCode(for: Character(name)) : keyCodes[name]) ?? keyCodes[name]
    else { exit(2) }
    // The modifiers go down as keys of their own and come up again. Flags on the key events alone
    // leave the system believing the modifier is still held: the letters typed afterwards then act
    // as shortcuts (⌘T opened tabs, ⌘D split them), in this run and in the next one.
    var held: [(CGKeyCode, CGEventFlags)] = []
    for mod in args.dropFirst(2) {
        switch mod {
        case "cmd": held.append((55, .maskCommand))
        case "shift": held.append((56, .maskShift))
        case "opt": held.append((58, .maskAlternate))
        case "ctrl": held.append((59, .maskControl))
        default: break
        }
    }
    var flags = CGEventFlags()
    for (modifierCode, flag) in held {
        flags.insert(flag)
        flagsChanged(modifierCode, flags)
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        post(e); sleepMs(50)
    }
    for (modifierCode, flag) in held.reversed() {
        flags.remove(flag)
        flagsChanged(modifierCode, flags)
    }
case "type":
    flagsChanged(55, CGEventFlags())   // nothing is held when the typing starts
    // The key that types each character in the current layout. Ghostty reads the key that was
    // pressed, not the Unicode string an event carries; a character no key types goes as Unicode.
    let special: [Character: CGKeyCode] = [" ": 49, "\t": 48]
    for ch in (args.count > 1 ? args[1] : "") {
        for down in [true, false] {
            if let code = special[ch] ?? keyCode(for: ch) {
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
if ProcessInfo.processInfo.environment["KEEP_POINTER"] == nil { move(to: origin) }

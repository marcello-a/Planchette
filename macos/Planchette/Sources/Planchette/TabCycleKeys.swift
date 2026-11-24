import AppKit

/// ⌃Tab and ⌃⇧Tab: the next tab, the next project — the keys every tabbed app has.
///
/// Not menu items: each action has one, in Terminal → Go to tab / Go to project with ⌥⌘→ and
/// ⌥⌘↓, and a menu item carries one shortcut. Two items per action made the menu say everything
/// twice. A *local* monitor sees the key before the window does, so AppKit's key-view loop does
/// not move the keyboard out of the terminal into the project panel — the reason ⌃Tab was a menu
/// shortcut in the first place.
///
/// Only over a Planchette window (`WindowRegistry`): in Settings or a dialog, ⌃Tab keeps its
/// own job of moving the focus between fields.
final class TabCycleKeys {
    enum Action: Equatable {
        case nextTab, nextProject
    }

    private var monitor: Any?

    init(perform: @escaping (Action) -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = Self.action(keyCode: event.keyCode, flags: event.modifierFlags),
                  WindowRegistry.shared.keyWindowID() != nil
            else { return event }
            perform(action)
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// The Tab key's virtual key code, the same on every keyboard layout.
    static let tabKeyCode: UInt16 = 48

    /// Pure: what a key press asks for. ⌃Tab the next tab, ⌃⇧Tab the next project; with ⌘ or ⌥
    /// as well it is someone else's chord.
    static func action(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Action? {
        guard keyCode == tabKeyCode else { return nil }
        let chord = flags.intersection([.command, .option, .control, .shift])
        switch chord {
        case [.control]: return .nextTab
        case [.control, .shift]: return .nextProject
        default: return nil
        }
    }
}

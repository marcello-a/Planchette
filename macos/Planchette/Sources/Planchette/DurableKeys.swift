import AppKit

/// ⌃↩ and ⇧↩ for Claude Code in a durable terminal.
///
/// tmux cannot pass the terminal's keyboard protocol through (verified against tmux 3.7b at
/// `extended-keys on` and `always`, see `PersistedState.durableTerminals`): a modified Return
/// reaches the program inside as a plain Return. Claude Code then submits where you asked for
/// a new line (⇧↩), and sends normally where you asked to send now (⌃↩, `chat:sendNow`).
///
/// Claude Code has a plain control key for each, which every terminal delivers: ⌃J is
/// `chat:newline`, the chord ⌃X ⌃S is `chat:sendNow` (Claude Code 2.1.275 and later). So in a
/// durable terminal with a live Claude, the view presses those instead. Only there: a shell
/// reads ⌃J as Return and ⌃X ⌃S as something else again.
enum DurableKeys {
    enum Action: Equatable {
        /// ⇧↩: a new line in the prompt.
        case newline
        /// ⌃↩: send what is queued, and the draft with it, right away.
        case sendNow

        /// The control keys that do it, in order: the letter and its virtual key code.
        var presses: [(letter: Character, keyCode: UInt32)] {
            switch self {
            case .newline: [("j", 38)]               // kVK_ANSI_J
            case .sendNow: [("x", 7), ("s", 1)]      // kVK_ANSI_X, kVK_ANSI_S
            }
        }

        /// Whether holding the key down repeats it: a new line per repeat is what you would
        /// type; "send now" once is enough.
        var repeats: Bool { self == .newline }
    }

    /// Pure: what a key press in a durable terminal with a live Claude asks for. Return and
    /// the keypad's Enter, with exactly Shift or exactly Control held; anything else is the
    /// terminal's.
    static func action(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Action? {
        guard keyCode == 36 || keyCode == 76 else { return nil }   // kVK_Return, kVK_ANSI_KeypadEnter
        switch flags.intersection([.command, .option, .control, .shift]) {
        case [.shift]: return .newline
        case [.control]: return .sendNow
        default: return nil
        }
    }
}

import AppKit
import GhosttyKit

/// Asking the user before a terminal touches the clipboard in a way they did not
/// start themselves.
///
/// libghostty has three protections, all configurable, and each ends in a
/// callback that hands the question to the host app:
///
/// - **OSC 52 read.** Any program that prints `ESC ] 52 ; c ; ? BEL` is answered
///   with the clipboard — and the answer is typed into that program's input. Run
///   `cat` on an untrusted file, `ssh` into a hostile host, or open a log with a
///   crafted line, and whatever you last copied (a password, a token) can be read
///   out by it. Asked through `confirm_read_clipboard_cb`.
/// - **Unsafe paste.** Text with a line break, pasted into a program that does not
///   use bracketed paste, runs as commands the moment it arrives. Pastes from web
///   pages can carry text you never saw. Asked through the same callback.
/// - **OSC 52 write** (only when the user's config says `clipboard-write = ask`;
///   the default is `allow`). Asked through `write_clipboard_cb(confirm: true)`.
///
/// The first two used to be approved without asking (the callback answered
/// "confirmed" to everything — a "v1" shortcut), which switched the protections
/// off, and the third's `confirm` flag was ignored. Here the user decides, as in
/// Ghostty itself.
///
/// What counts as a prompt is libghostty's call, not ours: it asks only for a
/// paste that is actually unsafe (an ordinary bracketed paste is framed and does
/// not qualify) and only for a clipboard read when `clipboard-read` is `ask`. A
/// user who set `allow` or `deny` in their own Ghostty config is not asked.
///
/// **A dialog is only ever a sheet on the window of the terminal that asked.**
/// Never `runModal()`: it is app-modal and, started from the main queue, stops the
/// queue (see `ModalAlert`) — libghostty's tick and with it every terminal would
/// freeze until somebody clicked, and a program in a background tab could cause
/// that. A terminal that is not in a visible window (a background tab, a hidden
/// app) cannot show a sheet the user could connect to its question; a request that
/// a program started there is refused.
enum ClipboardConfirmation {
    enum Kind: Equatable {
        /// A paste libghostty flagged as unsafe. The user started it.
        case unsafePaste
        /// A program asked to read the clipboard (OSC 52).
        case read
        /// A program asked to replace the clipboard (OSC 52).
        case write

        init(_ request: ghostty_clipboard_request_e) {
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: self = .read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE: self = .write
            default: self = .unsafePaste
            }
        }

        /// Did a program, rather than the user, start this? Those are the requests
        /// a hostile program can repeat, so those are the ones that get rationed.
        var startedByProgram: Bool { self != .unsafePaste }
    }

    /// The text to complete a paste/read request with once the user has answered,
    /// or nil to leave the request unanswered.
    ///
    /// Denying completes with an empty string: nothing is pasted, and a program
    /// that asked to read gets an empty clipboard rather than a hang. A write is
    /// not completed through libghostty at all (its confirmation is the
    /// `confirm` flag of the write callback, see `requestWrite`), so for `.write`
    /// a denial is simply "do nothing": completing one would write the string, and
    /// an empty one would clear the user's clipboard.
    static func answer(for kind: Kind, text: String, allowed: Bool) -> String? {
        if allowed { return text }
        switch kind {
        case .unsafePaste, .read: return ""
        case .write: return nil
        }
    }

    /// What the dialog shows of the text: bounded, with a count of what is left
    /// out, and with everything invisible made visible. The point of looking at a
    /// risky paste is to see what is in it.
    ///
    /// - control characters become their "control picture" (ESC is ␛);
    /// - format characters — bidirectional overrides (U+202E reverses what follows
    ///   it, so `rm -rf x` can be shown backwards), zero-width characters, line and
    ///   paragraph separators — and C1 controls become `⟨U+XXXX⟩`, because rendered
    ///   they are exactly the characters that hide something.
    static func preview(_ text: String, limit: Int = 4000) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if index >= limit {
                let omitted = scalars.count - index
                out.append(contentsOf: ("\n" + L10n.t(.clipboardPreviewMore, omitted)).unicodeScalars)
                break
            }
            switch scalar.value {
            case 0x0A, 0x09:
                out.append(scalar)
            case 0x00..<0x20:
                // The "control pictures" block: ESC (0x1B) becomes ␛.
                out.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 0x7F:
                out.append(Unicode.Scalar(0x2421)!)
            default:
                switch scalar.properties.generalCategory {
                case .format, .control, .lineSeparator, .paragraphSeparator:
                    out.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
                default:
                    out.append(scalar)
                }
            }
        }
        return String(out)
    }

    /// Who may be asked, and when.
    ///
    /// One dialog per window: a window can carry one sheet at a time, and a program
    /// that prints the request in a loop must not stack them. And a request a
    /// program started, after the user said no to the same terminal (or it had no
    /// window to ask in), is refused quietly for a while — the answer is not going
    /// to change in the next half minute, and a prompt that reappears on every
    /// refusal is a denial-of-service on the user's attention.
    struct Gate {
        static let quietPeriod: TimeInterval = 30

        private var windowsAsking: Set<Int> = []
        private var quietUntil: [UUID: Date] = [:]

        /// May a dialog be shown now, as a sheet on window `window` (its number; nil
        /// when the terminal is not in a visible window)? If so the window is held
        /// until `finish`.
        mutating func admit(_ kind: Kind, terminal: UUID, window: Int?, now: Date) -> Bool {
            if kind.startedByProgram, let until = quietUntil[terminal], now < until {
                return false
            }
            guard let window else {
                // Nowhere to ask: refuse, and quiet the program that keeps asking.
                if kind.startedByProgram {
                    quietUntil[terminal] = now.addingTimeInterval(Self.quietPeriod)
                }
                return false
            }
            return windowsAsking.insert(window).inserted
        }

        mutating func finish(_ kind: Kind, terminal: UUID, window: Int, allowed: Bool, now: Date) {
            windowsAsking.remove(window)
            if kind.startedByProgram, !allowed {
                quietUntil[terminal] = now.addingTimeInterval(Self.quietPeriod)
            }
            // A closed terminal's entry would sit here for good otherwise.
            quietUntil = quietUntil.filter { $0.value > now }
        }
    }

    @MainActor
    private static var gate = Gate()

    // MARK: Presenting

    /// The window a sheet may go on: the terminal's own, if it is on screen.
    @MainActor
    private static func visibleWindow(of view: GhosttySurfaceNSView) -> NSWindow? {
        guard let window = view.window, window.isVisible else { return nil }
        return window
    }

    /// Answer a libghostty paste/read confirmation. Call on the main actor, from
    /// outside libghostty's own callback (completing a request from inside the
    /// callback that reported it re-enters the library).
    ///
    /// `text` is libghostty's own copy of what is at stake — the paste, or the
    /// clipboard it would send. The dialog shows it and an approval completes with
    /// exactly it, so what the user reviewed is what goes through even if the
    /// clipboard changed while the dialog was open.
    @MainActor
    static func request(
        kind: Kind, text: String, state: UnsafeMutableRawPointer?,
        view: GhosttySurfaceNSView
    ) {
        let complete: (String?) -> Void = { answer in
            // The terminal may have been closed while the dialog was up.
            guard let answer, let surface = view.surface else { return }
            answer.withCString {
                ghostty_surface_complete_clipboard_request(surface, $0, state, true)
            }
        }
        let terminal = view.sessionID
        let window = visibleWindow(of: view)
        guard gate.admit(kind, terminal: terminal, window: window?.windowNumber, now: Date()),
              let window
        else {
            complete(answer(for: kind, text: text, allowed: false))
            return
        }
        present(kind, text: text, window: window) { allowed in
            gate.finish(
                kind, terminal: terminal, window: window.windowNumber,
                allowed: allowed, now: Date())
            complete(answer(for: kind, text: text, allowed: allowed))
        }
    }

    /// Ask about a write a program wants to do (`clipboard-write = ask`). `allow`
    /// performs it; a refusal does nothing, and there is nothing to complete.
    @MainActor
    static func requestWrite(
        text: String, view: GhosttySurfaceNSView, allow: @escaping () -> Void
    ) {
        let terminal = view.sessionID
        let window = visibleWindow(of: view)
        guard gate.admit(.write, terminal: terminal, window: window?.windowNumber, now: Date()),
              let window
        else { return }
        present(.write, text: text, window: window) { allowed in
            gate.finish(
                .write, terminal: terminal, window: window.windowNumber,
                allowed: allowed, now: Date())
            if allowed { allow() }
        }
    }

    /// The dialog for a request. Separate from showing it so what is on it can be
    /// tested.
    ///
    /// The safe answer is the FIRST button, which makes it the default one: the
    /// paste that opened this dialog was a keystroke, and a reflexive second Return
    /// must not approve it. The approving button is always the second.
    ///
    /// The safe button is deliberately never titled "Cancel". AppKit gives a button
    /// with that title the Escape key and, in the same stroke, drops the default
    /// button altogether (measured: with [Cancel, Paste] no button is default and
    /// Return does nothing; with [Don't Paste, Paste] the first one is). "Don't …"
    /// keeps Return on the safe answer. Escape then does nothing — Return always
    /// dismisses it safely, which is the point.
    @MainActor
    static func makeAlert(_ kind: Kind, text: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .unsafePaste:
            alert.messageText = L10n.t(.clipboardPasteTitle)
            alert.informativeText = L10n.t(.clipboardPasteBody)
            alert.addButton(withTitle: L10n.t(.clipboardPasteDeny))
            alert.addButton(withTitle: L10n.t(.clipboardPasteConfirm))
            alert.accessoryView = previewView(text)
        case .read:
            alert.messageText = L10n.t(.clipboardReadTitle)
            alert.informativeText = L10n.t(.clipboardReadBody)
            alert.addButton(withTitle: L10n.t(.clipboardDeny))
            alert.addButton(withTitle: L10n.t(.clipboardAllow))
        case .write:
            alert.messageText = L10n.t(.clipboardWriteTitle)
            alert.informativeText = L10n.t(.clipboardWriteBody)
            alert.addButton(withTitle: L10n.t(.clipboardDeny))
            alert.addButton(withTitle: L10n.t(.clipboardAllow))
            alert.accessoryView = previewView(text)
        }
        return alert
    }

    /// Always a sheet: it returns at once, so nothing stops while it is up.
    @MainActor
    private static func present(
        _ kind: Kind, text: String, window: NSWindow, done: @escaping (Bool) -> Void
    ) {
        makeAlert(kind, text: text).beginSheetModal(for: window) { response in
            done(response == .alertSecondButtonReturn)
        }
    }

    @MainActor
    private static func previewView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = preview(text)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return scroll
    }
}

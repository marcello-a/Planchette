import Foundation

/// The notepad of a terminal: a strip of text at the right of the tab. A prompt runs until the
/// Returns that end it — two by default, which is a blank line — so it can be several lines long.
/// Everything here is pure and unit-tested; the views are in `Views/NotepadView.swift`.

/// Whether the pad is open, how wide it is, and how many Returns end a prompt — one setting for
/// the whole app, like the notifications panel: it stays where you left it while you go from
/// terminal to terminal. Persisted as `PersistedState.notepad`.
struct NotepadLook: Codable, Equatable {
    static let defaultWidth: Double = 280
    /// Narrower than this, a line of a prompt is no longer readable; wider than the room leaves,
    /// the terminal is gone — `clamped(width:in:)` keeps it between these and the window.
    static let minimumWidth: Double = 180
    /// The room the terminal keeps however wide the pad is dragged.
    static let terminalMinimumWidth: Double = 280
    /// One Return ends a prompt (every line is one), two (a blank line between prompts), or three.
    static let returnsRange = 1...3
    static let defaultReturns = 2

    var isOpen = false
    var width: Double = NotepadLook.defaultWidth
    var returnsPerPrompt = NotepadLook.defaultReturns

    init(isOpen: Bool = false, width: Double = NotepadLook.defaultWidth,
         returnsPerPrompt: Int = NotepadLook.defaultReturns) {
        self.isOpen = isOpen
        self.width = NotepadLook.sanitized(width)
        self.returnsPerPrompt = NotepadLook.sanitized(returns: returnsPerPrompt)
    }

    // A state written by another build, or by hand, must not cost the whole workspace.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOpen = (try? c.decodeIfPresent(Bool.self, forKey: .isOpen)) ?? false
        width = Self.sanitized((try? c.decodeIfPresent(Double.self, forKey: .width)) ?? Self.defaultWidth)
        returnsPerPrompt = Self.sanitized(
            returns: (try? c.decodeIfPresent(Int.self, forKey: .returnsPerPrompt)) ?? Self.defaultReturns)
    }

    /// A width that can be stored: a number, and not below the minimum.
    static func sanitized(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return max(width, minimumWidth)
    }

    static func sanitized(returns: Int) -> Int {
        min(max(returns, returnsRange.lowerBound), returnsRange.upperBound)
    }

    /// The width the pad gets in a tab `available` points wide: what was asked for, but never
    /// under the minimum and never so wide that the terminal has less than its own minimum.
    static func clamped(width: Double, in available: Double) -> Double {
        let room = available - terminalMinimumWidth
        guard room >= minimumWidth else { return minimumWidth }   // a tiny window: the minimum wins
        return min(max(sanitized(width), minimumWidth), room)
    }
}

enum NotepadPrompts {
    /// The characters that end a line. A text view shows each of them as a new line; `NSString`
    /// paragraphs know only some, so lines are cut here, by hand.
    private static func isBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }

    /// One prompt of the pad.
    struct Prompt: Equatable {
        /// From the first character of its first line to the end of its last line's text, in
        /// UTF-16 units (what a text view counts in). The Return that ends it is not part of it.
        let range: NSRange
        /// What goes into the terminal: the lines as typed, joined by "\n", without the space
        /// around them.
        let text: String
    }

    private struct Line {
        /// The line with its break.
        let full: NSRange
        /// The line without its break.
        let content: NSRange
        let isBlank: Bool
    }

    private static func lines(in text: NSString) -> [Line] {
        var result: [Line] = []
        var start = 0, index = 0
        func add(end: Int, breakLength: Int) {
            let content = NSRange(location: start, length: end - start)
            let blank = text.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty
            result.append(Line(full: NSRange(location: start, length: end + breakLength - start),
                               content: content, isBlank: blank))
        }
        while index < text.length {
            if isBreak(text.character(at: index)) {
                // "\r\n" is one break.
                let length = text.character(at: index) == 0x0D && index + 1 < text.length
                    && text.character(at: index + 1) == 0x0A ? 2 : 1
                add(end: index, breakLength: length)
                start = index + length
                index = start
            } else {
                index += 1
            }
        }
        if start < text.length { add(end: text.length, breakLength: 0) }
        return result
    }

    /// Every prompt, top to bottom. A prompt is the lines from one that holds text to the last one
    /// before `returns` Returns in a row (blank lines between prompts are gaps). With one Return
    /// every line is a prompt; with two, a blank line ends one; with three, two blank lines do.
    /// Blank lines that do not reach that count stay inside the prompt.
    static func prompts(in text: String, returns: Int) -> [Prompt] {
        let ns = text as NSString
        let all = lines(in: ns)
        let needed = NotepadLook.sanitized(returns: returns)
        let filled = all.indices.filter { !all[$0].isBlank }
        var groups: [[Int]] = []
        for index in filled {
            if let last = groups.last?.last, index - last - 1 + 1 < needed {
                groups[groups.count - 1].append(index)      // too few Returns between: same prompt
            } else {
                groups.append([index])
            }
        }
        return groups.map { group in
            let first = all[group[0]], last = all[group[group.count - 1]]
            let range = NSRange(location: first.content.location, length: NSMaxRange(last.content) - first.content.location)
            return Prompt(range: range, text: normalized(ns.substring(with: range)))
        }
    }

    /// The prompt the insertion point is in, or nil in a gap between prompts. At the very end of
    /// the text, after a final Return, there is an empty line and so no prompt.
    static func prompt(at location: Int, in text: String, returns: Int) -> String? {
        let length = (text as NSString).length
        let at = min(max(location, 0), length)
        return prompts(in: text, returns: returns)
            .first { $0.range.location <= at && at <= NSMaxRange($0.range) }?.text
    }

    /// Typed text for a terminal: one kind of line break, nothing around it.
    private static func normalized(_ text: String) -> String {
        var result = text
        for separator in ["\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"] {
            result = result.replacingOccurrences(of: separator, with: "\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

/// The notepad of a terminal: a strip of text at the right of the tab. A prompt runs until the
/// Returns that end it — two by default, which is a blank line — so it can be several lines long.
/// Everything here is pure and unit-tested; the views are in `Views/NotepadView.swift`.

/// What happens to a prompt of the pad once it has been loaded into the terminal.
enum NotepadAfterLoading: String, Codable, CaseIterable, Identifiable {
    /// It leaves the pad: what is in the pad is what is still to do.
    case remove
    /// It stays, struck through. It is written into the text as `~~…~~` (the pad is plain text,
    /// and what a restart keeps has to be text), and shown with a line through it.
    case strike
    /// Nothing happens.
    case keep

    static let `default` = NotepadAfterLoading.remove
    var id: String { rawValue }
}

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

    /// The terminals whose pad is open — per terminal: one you write prompts for keeps its pad, the
    /// others stay wide. The width and the other settings are the same for every pad.
    var openTerminals: Set<UUID> = []
    /// A state from before the pad was per terminal had one switch for all of them. When it was
    /// on, every terminal comes up with its pad open, once (`AppState.applyRestore`); not stored.
    var openForAllFromOldState = false
    var width: Double = NotepadLook.defaultWidth
    var returnsPerPrompt = NotepadLook.defaultReturns
    var afterLoading = NotepadAfterLoading.default

    func isOpen(for id: UUID?) -> Bool { id.map(openTerminals.contains) ?? false }

    mutating func setOpen(_ open: Bool, for id: UUID) {
        if open { openTerminals.insert(id) } else { openTerminals.remove(id) }
    }

    init(openTerminals: Set<UUID> = [], width: Double = NotepadLook.defaultWidth,
         returnsPerPrompt: Int = NotepadLook.defaultReturns,
         afterLoading: NotepadAfterLoading = .default) {
        self.openTerminals = openTerminals
        self.width = NotepadLook.sanitized(width)
        self.returnsPerPrompt = NotepadLook.sanitized(returns: returnsPerPrompt)
        self.afterLoading = afterLoading
    }

    // A state written by another build, or by hand, must not cost the whole workspace.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let open = try? c.decodeIfPresent([UUID].self, forKey: .openTerminals) {
            openTerminals = Set(open)
        } else {
            openForAllFromOldState = (try? c.decodeIfPresent(Bool.self, forKey: .isOpen)) ?? false
        }
        width = Self.sanitized((try? c.decodeIfPresent(Double.self, forKey: .width)) ?? Self.defaultWidth)
        returnsPerPrompt = Self.sanitized(
            returns: (try? c.decodeIfPresent(Int.self, forKey: .returnsPerPrompt)) ?? Self.defaultReturns)
        // A word a newer build wrote falls back; a state from before this setting gets the default.
        afterLoading = (try? c.decodeIfPresent(NotepadAfterLoading.self, forKey: .afterLoading)) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(openTerminals.map(\.uuidString).sorted().compactMap(UUID.init), forKey: .openTerminals)
        try c.encode(width, forKey: .width)
        try c.encode(returnsPerPrompt, forKey: .returnsPerPrompt)
        try c.encode(afterLoading, forKey: .afterLoading)
    }

    /// `isOpen` is read only: the one switch for all pads that states before 0.2.47 wrote.
    private enum CodingKeys: String, CodingKey {
        case isOpen, openTerminals, width, returnsPerPrompt, afterLoading
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
        /// around them — and without the `~~` of a struck-through prompt.
        let text: String
        /// Written as `~~…~~`: it was loaded already, and the setting said to strike it through.
        var isDone = false
    }

    /// The mark of a struck-through prompt: the text between two of these.
    static let doneMark = "~~"

    private struct Line {
        /// The line with its break.
        let full: NSRange
        /// The line without its break.
        let content: NSRange
        let isBlank: Bool
        /// Inside a fenced code block, fences included: a blank line there is part of the code.
        var inFence = false
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
        var open = false
        for index in result.indices {
            let content = text.substring(with: result[index].content).trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("```") {
                open.toggle()
                result[index].inFence = true
            } else {
                result[index].inFence = open
            }
        }
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
        // A blank line inside a code fence does not end a prompt: the block is one prompt.
        let filled = all.indices.filter { !all[$0].isBlank || all[$0].inFence }
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
            let text = normalized(ns.substring(with: range))
            // ~~like this~~: struck through, and what goes into the terminal is what is inside.
            if text.count > 2 * doneMark.count, text.hasPrefix(doneMark), text.hasSuffix(doneMark) {
                let inner = text.dropFirst(doneMark.count).dropLast(doneMark.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return Prompt(range: range, text: inner, isDone: true) }
            }
            return Prompt(range: range, text: text)
        }
    }

    /// The prompt the insertion point is in, or nil in a gap between prompts. At the very end of
    /// the text, after a final Return, there is an empty line and so no prompt.
    static func prompt(at location: Int, in text: String, returns: Int) -> String? {
        promptValue(at: location, in: text, returns: returns)?.text
    }

    /// The same, with where it is — what is needed to do something to it afterwards.
    static func promptValue(at location: Int, in text: String, returns: Int) -> Prompt? {
        let length = (text as NSString).length
        let at = min(max(location, 0), length)
        return prompts(in: text, returns: returns)
            .first { $0.range.location <= at && at <= NSMaxRange($0.range) }
    }

    /// Typed text for a terminal: one kind of line break, nothing around it.
    private static func normalized(_ text: String) -> String {
        var result = text
        for separator in ["\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"] {
            result = result.replacingOccurrences(of: separator, with: "\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: After a prompt was loaded

    /// A change to the text: `range` is replaced by `replacement`.
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// The prompt that was loaded, found again in the text as it is now: the same words, nearest to
    /// where it was. The text can have changed between the click and the end of the load; a prompt
    /// that is gone is not found, and nothing is done to something else.
    static func locate(_ text: String, near location: Int, in current: String, returns: Int) -> Prompt? {
        let candidates = prompts(in: current, returns: returns).filter { $0.text == text }
        return candidates.min { abs($0.range.location - location) < abs($1.range.location - location) }
    }

    /// What the setting does to a prompt that was loaded: its removal, its marks, or nothing.
    static func edit(
        afterLoading action: NotepadAfterLoading, _ prompt: Prompt, in text: String
    ) -> Edit? {
        let ns = text as NSString
        switch action {
        case .keep:
            return nil
        case .strike:
            guard !prompt.isDone else { return nil }
            return Edit(range: prompt.range, replacement: doneMark + ns.substring(with: prompt.range) + doneMark)
        case .remove:
            return Edit(range: removalRange(of: prompt, in: text), replacement: "")
        }
    }

    /// The prompt, and the Returns and blank lines that separated it from the next one — so that
    /// removing it leaves the rest as it was, not with a growing gap. The last prompt takes the gap
    /// before it instead, so the pad does not end in empty lines.
    static func removalRange(of prompt: Prompt, in text: String) -> NSRange {
        let ns = text as NSString
        let all = lines(in: ns)
        guard let first = all.firstIndex(where: { $0.content.location >= prompt.range.location }),
              let last = all.lastIndex(where: { NSMaxRange($0.content) <= NSMaxRange(prompt.range) })
        else { return prompt.range }
        // Everything after the prompt's last line up to the next line that holds text.
        var after = last + 1
        while after < all.count, all[after].isBlank { after += 1 }
        if after < all.count {
            let start = all[first].full.location
            return NSRange(location: start, length: all[after].full.location - start)
        }
        // The last prompt: take the blank lines and the Return before it as well.
        var before = first
        while before > 0, all[before - 1].isBlank { before -= 1 }
        let start = before > 0 ? NSMaxRange(all[before - 1].content) : 0
        return NSRange(location: start, length: ns.length - start)
    }
}

/// Whether the input box of Claude Code already holds text, read off the viewport. A prompt that
/// is added and run by the notepad then starts on a line of its own, so it does not run into what
/// was typed there. Without a Claude input box on screen (a plain shell) there is no answer, and
/// the prompt is added as it is.
enum ClaudeInputDraft {
    /// The text of the input box's first line: the last line that starts with `>` or `❯`, inside
    /// the box's border or not. Earlier lines with a `>` are the conversation.
    static func text(in viewport: String) -> String? {
        for raw in viewport.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("│") || line.hasPrefix("┃") { line.removeFirst() }
            if line.hasSuffix("│") || line.hasSuffix("┃") { line.removeLast() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard let mark = line.first, mark == ">" || mark == "❯" else { continue }
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Typed text, not the grey suggestion (`Try "…"`) Claude Code shows in an empty box.
    static func hasDraft(in viewport: String) -> Bool {
        guard let text = text(in: viewport), !text.isEmpty else { return false }
        return !text.hasPrefix("Try \"")
    }
}

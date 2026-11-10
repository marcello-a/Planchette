import Foundation

/// What the notepad does to a Return and a Tab, the way a Markdown editor does: a list goes on by
/// itself, an empty item ends it, a code block keeps its indent and gets its closing fence. Every
/// answer is one change to the text and where the insertion point goes; nil means the key does
/// what it always does. Pure and unit-tested; the text view applies it (`Views/NotepadView.swift`).
enum NotepadEditing {
    /// Replace `range` with `replacement`, then put the insertion point at `caret` (in the new text).
    struct Change: Equatable {
        let range: NSRange
        let replacement: String
        let caret: Int
    }

    /// The start of a list item, cut into its parts. All lengths in UTF-16 units.
    struct ListMarker: Equatable {
        enum Kind: Equatable {
            case bullet(Character)
            /// `1.` or `1)`.
            case number(Int, delimiter: Character)
            /// `> `: a quote goes on like a list.
            case quote
        }

        let indent: String
        let kind: Kind
        /// `[ ] ` or `[x] ` after the bullet: a task.
        let task: Bool
        /// From the start of the line to the first character of the item's text.
        let length: Int

        /// The marker of the item after this one: the next number, an open task box.
        var next: String {
            indent + symbol(number: { $0 + 1 }) + (task ? "[ ] " : "")
        }

        /// The marker as written, with the number `number` gives.
        func symbol(number: (Int) -> Int = { $0 }) -> String {
            switch kind {
            case .bullet(let mark): "\(mark) "
            case .number(let n, let delimiter): "\(number(n))\(delimiter) "
            case .quote: "> "
            }
        }
    }

    /// The list marker a line starts with, if any.
    static func marker(of line: String) -> ListMarker? {
        if let prefix = NotepadMarkdown.listPrefix(of: line) {
            let ns = line as NSString
            let indent = ns.substring(to: prefix.indent)
            let symbol = ns.substring(with: NSRange(location: prefix.indent, length: prefix.total - prefix.indent - 1))
            let kind: ListMarker.Kind
            if let last = symbol.last, last == "." || last == ")", let n = Int(symbol.dropLast()) {
                kind = .number(n, delimiter: last)
            } else {
                kind = .bullet(symbol.first ?? "-")
            }
            var length = prefix.total
            let rest = ns.substring(from: length)
            let isBullet: Bool = { if case .bullet = kind { return true }; return false }()
            let task = isBullet && taskBox(at: rest) != nil
            if task { length += 4 }
            return ListMarker(indent: indent, kind: kind, task: task, length: length)
        }
        let body = line.prefix { $0 == " " }
        let rest = line.dropFirst(body.count)
        if body.count <= 3, rest.hasPrefix("> ") {
            return ListMarker(indent: String(body), kind: .quote, task: false, length: body.utf16.count + 2)
        }
        return nil
    }

    /// `[ ] `, `[x] ` or `[X] ` at the start: whether it is ticked.
    static func taskBox(at text: String) -> Bool? {
        let box = text.prefix(4)
        if box == "[ ] " { return false }
        if box == "[x] " || box == "[X] " { return true }
        return nil
    }

    // MARK: Lines

    private struct Line {
        /// The line without its break.
        let range: NSRange
        let text: String
    }

    private static func line(at location: Int, in ns: NSString) -> Line {
        let full = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        var end = NSMaxRange(full)
        while end > full.location, isBreak(ns.character(at: end - 1)) { end -= 1 }
        let range = NSRange(location: full.location, length: end - full.location)
        return Line(range: range, text: ns.substring(with: range))
    }

    private static func isBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }

    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// Where the fences are: for every fence line, whether it opens a block (and not closes one).
    private static func fences(in ns: NSString) -> [(range: NSRange, opens: Bool)] {
        var result: [(NSRange, Bool)] = []
        var open = false
        var location = 0
        while location < ns.length {
            let line = line(at: location, in: ns)
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            if isFence(line.text) {
                open.toggle()
                result.append((line.range, open))
            }
            location = next
        }
        return result
    }

    /// Whether `location` is inside a fenced block, between its fences.
    static func isInCode(_ location: Int, in text: String) -> Bool {
        let ns = text as NSString
        let current = line(at: location, in: ns)
        guard !isFence(current.text) else { return false }
        let before = fences(in: ns).filter { $0.range.location < current.range.location }
        return before.last?.opens ?? false
    }

    // MARK: Return

    /// Return, pressed with the insertion point at `location` and nothing selected.
    static func newline(at location: Int, in text: String) -> Change? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }
        let current = line(at: location, in: ns)
        let column = location - current.range.location

        // "```swift" and Return, with no fence after it: the block gets its closing fence.
        if isFence(current.text), location == NSMaxRange(current.range) {
            let all = fences(in: ns)
            if let index = all.firstIndex(where: { $0.range.location == current.range.location }),
               all[index].opens, index == all.count - 1 {
                let indent = String(current.text.prefix { $0 == " " })
                return Change(range: NSRange(location: location, length: 0),
                              replacement: "\n" + indent + "\n" + indent + "```",
                              caret: location + 1 + indent.utf16.count)
            }
            return nil
        }

        // Code keeps the indent of the line above.
        if isInCode(location, in: text) {
            let indent = String(current.text.prefix { $0 == " " || $0 == "\t" })
            guard !indent.isEmpty, column >= indent.utf16.count else { return nil }
            return Change(range: NSRange(location: location, length: 0), replacement: "\n" + indent,
                          caret: location + 1 + indent.utf16.count)
        }

        guard let marker = marker(of: current.text), column >= marker.length else { return nil }
        let content = (current.text as NSString).substring(from: marker.length)
        // An empty item and Return: the list ends here, the marker goes.
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return Change(range: current.range, replacement: "", caret: current.range.location)
        }
        let inserted = "\n" + marker.next
        let caret = location + inserted.utf16.count
        guard case .number(let n, _) = marker.kind else {
            return Change(range: NSRange(location: location, length: 0), replacement: inserted, caret: caret)
        }
        // The items below count on from the new one: 1, 2, (new) 3, 3 → 4.
        guard let below = renumber(after: current.range, in: ns, indent: marker.indent, from: n + 2) else {
            return Change(range: NSRange(location: location, length: 0), replacement: inserted, caret: caret)
        }
        let between = ns.substring(with: NSRange(location: location, length: below.range.location - location))
        return Change(range: NSRange(location: location, length: NSMaxRange(below.range) - location),
                      replacement: inserted + between + below.text, caret: caret)
    }

    /// The numbered items right below `line` at the same indent, numbered from `first` on, with
    /// their line breaks. Nested items keep their own numbers. Nil when there are none, or when
    /// they already have those numbers.
    private static func renumber(
        after line: NSRange, in ns: NSString, indent: String, from first: Int
    ) -> (range: NSRange, text: String)? {
        let start = NSMaxRange(ns.lineRange(for: NSRange(location: line.location, length: 0)))
        var location = start
        var rebuilt = ""
        var number = first
        var changed = false
        while location < ns.length {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            let next = self.line(at: location, in: ns)
            guard let marker = marker(of: next.text) else { break }
            var content = next.text
            if marker.indent.count <= indent.count {
                guard marker.indent == indent, case .number(let n, let delimiter) = marker.kind else { break }
                if n != number { changed = true }
                content = indent + "\(number)\(delimiter) " + (next.text as NSString).substring(from: marker.length)
                number += 1
            }
            rebuilt += content + ns.substring(with: NSRange(location: NSMaxRange(next.range),
                                                            length: NSMaxRange(full) - NSMaxRange(next.range)))
            location = NSMaxRange(full)
        }
        guard changed else { return nil }
        return (NSRange(location: start, length: location - start), rebuilt)
    }

    // MARK: Tab

    /// How far Tab moves a list item in: two spaces under a bullet, three under a number, so
    /// the item lines up under the text of the one above.
    private static func indentUnit(for marker: ListMarker) -> Int {
        if case .number = marker.kind { return 3 }
        return 2
    }

    /// Tab (or Shift-Tab, `outdent`) on a list item: the whole item moves, wherever the insertion
    /// point is in it. Nil on a line that is not a list item.
    static func indent(at location: Int, in text: String, outdent: Bool) -> Change? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }
        let current = line(at: location, in: ns)
        guard let marker = marker(of: current.text), marker.kind != .quote else { return nil }
        let unit = indentUnit(for: marker)
        if outdent {
            let remove = min(marker.indent.count, unit)
            guard remove > 0 else { return nil }
            return Change(range: NSRange(location: current.range.location, length: remove), replacement: "",
                          caret: max(location - remove, current.range.location))
        }
        let pad = String(repeating: " ", count: unit)
        return Change(range: NSRange(location: current.range.location, length: 0), replacement: pad,
                      caret: location + unit)
    }

    // MARK: Marks around a selection

    /// ⌘B (`**`), ⌘I (`*`), ⌘E and a typed backtick (`` ` ``): the marks go around the selection,
    /// or come off when they are already there — inside the selection or right around it. With
    /// nothing selected, a pair goes in with the insertion point between.
    static func toggleMarks(_ mark: String, around selection: NSRange, in text: String) -> Change? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let width = (mark as NSString).length
        if selection.length == 0 {
            return Change(range: selection, replacement: mark + mark, caret: selection.location + width)
        }
        let selected = ns.substring(with: selection)
        // `**word**` selected: the marks come off.
        if selection.length >= 2 * width + 1, selected.hasPrefix(mark), selected.hasSuffix(mark),
           !isLongerRun(of: mark, in: selected) {
            let inner = (selected as NSString).substring(with: NSRange(location: width, length: selection.length - 2 * width))
            return Change(range: selection, replacement: inner, caret: selection.location + (inner as NSString).length)
        }
        // `word` selected inside `**word**`: the marks around it come off.
        if selection.location >= width, NSMaxRange(selection) + width <= ns.length,
           ns.substring(with: NSRange(location: selection.location - width, length: width)) == mark,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: width)) == mark,
           !surroundedByLongerRun(of: mark, around: selection, in: ns) {
            let range = NSRange(location: selection.location - width, length: selection.length + 2 * width)
            return Change(range: range, replacement: selected, caret: range.location + selection.length)
        }
        // Spaces at the edges stay outside: `**word **` is not bold.
        // A space is one UTF-16 unit, so counting characters counts units here.
        let lead = selected.prefix { $0 == " " }.count
        let trail = selected.reversed().prefix { $0 == " " }.count
        guard lead + trail < selection.length else { return nil }
        let core = NSRange(location: selection.location + lead, length: selection.length - lead - trail)
        let replacement = mark + ns.substring(with: core) + mark
        return Change(range: core, replacement: replacement, caret: core.location + (replacement as NSString).length)
    }

    /// `*` must not take the stars of `**bold**` for its own.
    private static func isLongerRun(of mark: String, in selected: String) -> Bool {
        guard mark == "*" else { return false }
        return selected.hasPrefix("**") && selected.hasSuffix("**")
    }

    private static func surroundedByLongerRun(of mark: String, around selection: NSRange, in ns: NSString) -> Bool {
        guard mark == "*", selection.location >= 2, NSMaxRange(selection) + 2 <= ns.length else { return false }
        return ns.substring(with: NSRange(location: selection.location - 2, length: 2)) == "**"
            && ns.substring(with: NSRange(location: NSMaxRange(selection), length: 2)) == "**"
    }

    // MARK: Links

    /// A web address and nothing else: `https://…` or `http://…`, without spaces.
    static func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"),
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed), url.host != nil else { return false }
        return true
    }

    /// A web address pasted over selected words: `[words](address)`. Nil when nothing is
    /// selected, the selection runs over lines or is an address itself, or the paste is no address.
    static func link(pasting pasted: String, over selection: NSRange, in text: String) -> Change? {
        let ns = text as NSString
        guard selection.length > 0, NSMaxRange(selection) <= ns.length, isURL(pasted) else { return nil }
        let words = ns.substring(with: selection)
        guard !words.contains(where: \.isNewline), !isURL(words),
              !words.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let replacement = "[\(words)](\(pasted.trimmingCharacters(in: .whitespacesAndNewlines)))"
        return Change(range: selection, replacement: replacement,
                      caret: selection.location + (replacement as NSString).length)
    }

    // MARK: Task boxes

    /// The `[ ]` of a task item on the line at `location`: a click there ticks it, or unticks it.
    static func taskBoxRange(at location: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }
        let current = line(at: location, in: ns)
        guard let marker = marker(of: current.text), marker.task else { return nil }
        let box = NSRange(location: current.range.location + marker.length - 4, length: 3)
        guard box.location <= location, location <= NSMaxRange(box) else { return nil }
        return box
    }

    /// Tick or untick the task box at `location`.
    static func toggleTask(at location: Int, in text: String) -> Change? {
        guard let box = taskBoxRange(at: location, in: text) else { return nil }
        let ticked = (text as NSString).substring(with: box).lowercased() == "[x]"
        return Change(range: box, replacement: ticked ? "[ ]" : "[x]", caret: location)
    }
}

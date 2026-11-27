import AppKit

/// How the notepad's text is drawn — its Markdown (`NotepadMarkdown`), the colours of code
/// (`NotepadCode`) and the line through a prompt that was sent (`NotepadPrompts`) — and how little
/// of it an edit makes stale. Drawing all of it again on every key cost 10–17 ms at 16 KB, which
/// made typing lag; most of a key's work is now one line.
///
/// What an edit can change, and so what is drawn again:
/// - the lines it touched, with one line around them (a `\r` and a `\n` that meet or part change
///   where a line ends);
/// - everything after it when a fence (```` ``` ````) came or went: every line below it changes
///   sides; and up to the closing fence when only the language of the block it is in changed;
/// - the whole of every prompt around it when a prompt there is struck through, or was: `~~` at
///   its start and end strikes all of it, so a key at one end changes the other.
///
/// The functions here are pure, apart from writing the attributes they work out; `NotepadStyler`
/// keeps what they need between two edits. Unit-tested against a full restyle of the text after
/// every one of thousands of random edits (`NotepadStyleTests`).
enum NotepadStyle {
    /// What the look depends on besides the text.
    struct Look: Equatable {
        /// The pad's width, held between the two widths where the look stops changing — wider
        /// than `wideWidth` draws the same as `wideWidth` (`NotepadMarkdown.bodySize`).
        let width: Double
        /// The Returns that end a prompt: which prompts are struck through.
        let returns: Int

        init(width: Double, returns: Int) {
            self.width = min(max(width, NotepadMarkdown.narrowWidth), NotepadMarkdown.wideWidth)
            self.returns = NotepadLook.sanitized(returns: returns)
        }

        var size: Double { NotepadMarkdown.bodySize(forWidth: width) }
    }

    /// The fonts and paragraphs of a look.
    struct Attributes {
        let look: Look
        let body: NSFont
        let mono: NSFont
        let code: NSFont
        let spacing: Double
        let codeParagraph: NSParagraphStyle
        /// Every character starts from these: the body text, before any Markdown.
        let plain: [NSAttributedString.Key: Any]

        init(_ look: Look) {
            self.look = look
            let size = look.size
            body = NSFont.systemFont(ofSize: size)
            mono = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
            code = NSFont.monospacedSystemFont(ofSize: (size * 0.85).rounded(), weight: .regular)
            spacing = NotepadMarkdown.lineSpacing(forBodySize: size)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            let codeParagraph = NSMutableParagraphStyle()
            codeParagraph.lineSpacing = 1
            codeParagraph.tabStops = []
            codeParagraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: code]).width
            self.codeParagraph = codeParagraph
            plain = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        }
    }

    /// A fence line: where a code block opens or closes.
    struct Fence: Equatable {
        /// The line without its break.
        let line: NSRange
        /// What it names: `swift` in ```` ```swift ````, as `NotepadCode.blocks` reads it.
        let language: String?

        func shifted(by delta: Int) -> Fence {
            Fence(line: NSRange(location: line.location + delta, length: line.length), language: language)
        }
    }

    // MARK: Lines

    /// The fence lines among the whole lines of `range`, top to bottom. The same test as
    /// `NotepadMarkdown.spans`, `NotepadCode.blocks` and `NotepadPrompts`: the line, without the
    /// spaces around it, starts with three backticks.
    static func fences(in ns: NSString, lines range: NSRange) -> [Fence] {
        var result: [Fence] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            let line = contentRange(of: full, in: ns)
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else { continue }
            let name = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            result.append(Fence(line: line, language: name.isEmpty ? nil : name))
        }
        return result
    }

    /// How many fences start before `location`: odd means `location` is inside a block.
    static func fenceCount(before location: Int, in fences: [Fence]) -> Int {
        var low = 0, high = fences.count
        while low < high {
            let mid = (low + high) / 2
            if fences[mid].line.location < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func inFence(at location: Int, in fences: [Fence]) -> Bool {
        fenceCount(before: location, in: fences) % 2 == 1
    }

    /// The whole lines an edit touched, and one line before and after them: a `\r` typed in front
    /// of a `\n`, or a `\n` deleted after a `\r`, moves the end of the line before.
    static func lines(around edited: NSRange, in ns: NSString) -> NSRange {
        var start = ns.lineRange(for: NSRange(location: edited.location, length: 0)).location
        if start > 0 { start = ns.lineRange(for: NSRange(location: start - 1, length: 0)).location }
        var end = NSMaxRange(ns.lineRange(for: edited))
        if end < ns.length { end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0))) }
        return NSRange(location: start, length: end - start)
    }

    /// Where a range of the text before an edit is after it. `edited` is what the edit put in, in
    /// the new text; a range that reached into what it replaced grows to cover all of it.
    static func map(_ range: NSRange, through edited: NSRange, delta: Int, length: Int) -> NSRange {
        let replacedEnd = NSMaxRange(edited) - delta
        func start(_ x: Int) -> Int { x <= edited.location ? x : x >= replacedEnd ? x + delta : edited.location }
        func end(_ x: Int) -> Int { x <= edited.location ? x : x >= replacedEnd ? x + delta : NSMaxRange(edited) }
        let from = min(max(start(range.location), 0), length)
        let to = min(max(end(NSMaxRange(range)), from), length)
        return NSRange(location: from, length: to - from)
    }

    /// `range` (whole lines) grown to whole prompts: back to just after the Returns that end the
    /// prompt before it, on to just before the Returns that end the last one — or to the start and
    /// the end of the text. Inside a fenced block a blank line is code, not a gap. With one Return
    /// per prompt every line is a prompt, and `range` is whole prompts already.
    static func promptExtent(of range: NSRange, in ns: NSString, fences: [Fence], returns: Int) -> NSRange {
        let gaps = NotepadLook.sanitized(returns: returns) - 1
        guard gaps > 0 else { return range }
        func isGap(_ full: NSRange) -> Bool {
            isBlank(contentRange(of: full, in: ns), in: ns) && !inFence(at: full.location, in: fences)
        }
        var start = 0
        var position = range.location, run = 0, cut = position
        while position > 0 {
            let line = ns.lineRange(for: NSRange(location: position - 1, length: 0))
            if isGap(line) {
                if run == 0 { cut = position }
                run += 1
                if run >= gaps { start = cut; break }
            } else {
                run = 0
            }
            position = line.location
        }
        var end = ns.length
        position = NSMaxRange(range); run = 0; cut = position
        while position < ns.length {
            let line = ns.lineRange(for: NSRange(location: position, length: 0))
            if isGap(line) {
                if run == 0 { cut = position }
                run += 1
                if run >= gaps { end = cut; break }
            } else {
                run = 0
            }
            position = NSMaxRange(line)
        }
        return NSRange(location: start, length: end - start)
    }

    /// `range` (whole lines) grown by whole lines until it cuts no composed character sequence. A
    /// combining mark or an emoji modifier at the start of a line belongs to the line break before
    /// it, and AppKit picks the font for the two together (`fixAttributes`) — drawing one without
    /// the other would leave the break in another font than a full restyle gives it.
    static func wholeSequences(_ range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start > 0, start < ns.length, ns.rangeOfComposedCharacterSequence(at: start).location < start {
            start = ns.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        while end > 0, end < ns.length, NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end - 1)) > end {
            end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0)))
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Drawing

    /// The look of the whole lines in `range`, written over whatever they had: plain text first,
    /// then the Markdown, the colours of code, and the line through `strikes` — the order a full
    /// restyle has always used. `fences` are the fence lines of the whole text. `grouped`: in an
    /// editing round of its own; false inside a text storage's `willProcessEditing`.
    static func apply(to storage: NSMutableAttributedString, range: NSRange, text ns: NSString,
                      fences: [Fence], attributes a: Attributes, strikes: [NSRange], grouped: Bool = true) {
        guard range.length > 0 else { return }
        let size = a.look.size
        if grouped { storage.beginEditing() }
        defer { if grouped { storage.endEditing() } }
        storage.setAttributes(a.plain, range: range)
        func derive(_ range: NSRange, _ change: (NSFont) -> NSFont) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                storage.addAttribute(.font, value: change(value as? NSFont ?? a.body), range: sub)
            }
        }
        let before = fenceCount(before: range.location, in: fences)
        for span in NotepadMarkdown.spans(in: ns, lines: range, inFence: before % 2 == 1)
        where NSMaxRange(span.range) <= storage.length {
            switch span.style {
            case .heading(let level):
                let big = NSFont.systemFont(
                    ofSize: size * NotepadMarkdown.headingScale(level: level, forWidth: a.look.width), weight: .bold)
                storage.addAttribute(.font, value: big, range: span.range)
            case .codeBlock:
                storage.addAttributes([.font: a.code, .paragraphStyle: a.codeParagraph], range: span.range)
            case .inlineCode:
                storage.addAttributes([
                    .font: a.mono, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                ], range: span.range)
            case .bold:
                derive(span.range) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            case .italic:
                derive(span.range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            case .mark:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            case .listItem(let prefix):
                // A wrapped line of an item lines up under its words, not under its bullet.
                let lead = ns.substring(with: NSRange(location: span.range.location, length: prefix))
                let indent = (lead as NSString).size(withAttributes: [.font: a.body]).width
                let item = NSMutableParagraphStyle()
                item.lineSpacing = a.spacing
                item.headIndent = indent
                storage.addAttribute(.paragraphStyle, value: item, range: span.range)
            case .taskBox(let checked):
                storage.addAttributes([
                    .font: a.mono,
                    .foregroundColor: checked ? NSColor.systemGreen : NSColor.secondaryLabelColor,
                ], range: span.range)
            case .doneTask:
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: span.range)
            case .link:
                storage.addAttributes([
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: span.range)
            }
        }
        // The colours of code: the lines between fences, in the language the opening fence names.
        var open = before % 2 == 1
        var language = open ? fences[before - 1].language : nil
        var next = before
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            if next < fences.count, fences[next].line.location == full.location {
                open.toggle()
                if open { language = fences[next].language }
                next += 1
                continue
            }
            guard open else { continue }
            let line = contentRange(of: full, in: ns)
            guard NSMaxRange(line) <= storage.length else { continue }
            for token in NotepadCode.tokens(in: ns.substring(with: line), language: language) {
                let range = NSRange(location: line.location + token.range.location, length: token.range.length)
                storage.addAttribute(.foregroundColor, value: color(of: token.token), range: range)
            }
        }
        for strike in strikes {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: strike)
        }
    }

    /// The colours of code, close to what an editor shows; system colours, so they hold in light
    /// and dark mode.
    static func color(of token: NotepadCode.Token) -> NSColor {
        switch token {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemBlue
        case .type: .systemPurple
        }
    }

    /// The struck-through prompts among the whole lines of `range`, which must be whole prompts.
    static func strikes(in ns: NSString, range: NSRange, fences: [Fence], returns: Int) -> [NSRange] {
        // No `~~` at all: nothing is struck through. Searching is far cheaper than cutting prompts.
        guard range.length > 0,
              ns.range(of: NotepadPrompts.doneMark, options: .literal, range: range).location != NSNotFound
        else { return [] }
        return NotepadPrompts.prompts(in: ns, range: range, inFence: inFence(at: range.location, in: fences),
                                      returns: returns)
            .filter(\.isDone).map(\.range)
    }

    /// Whether anything in `range` is struck through now — a prompt or a ticked task.
    static func hasStrike(in storage: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.strikethroughStyle, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    // MARK: Blocks

    /// The fenced blocks, as `NotepadCode.blocks(in:)` finds them, read off the fence lines: only
    /// the lines inside blocks are looked at, not the whole text.
    static func blocks(from fences: [Fence], in ns: NSString) -> [NotepadCode.Block] {
        var result: [NotepadCode.Block] = []
        var index = 0
        while index < fences.count {
            let open = fences[index]
            let close = index + 1 < fences.count ? fences[index + 1] : nil
            let limit = close?.line.location ?? ns.length
            var lines: [NSRange] = []
            var location = NSMaxRange(ns.lineRange(for: NSRange(location: open.line.location, length: 0)))
            while location < limit {
                let full = ns.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(full)
                lines.append(contentRange(of: full, in: ns))
            }
            result.append(NotepadCode.Block(open: open.line, close: close?.line, language: open.language, lines: lines))
            index += 2
        }
        return result
    }

    /// Where each block is, from its opening fence to its closing one (or the end of the text).
    static func blockRanges(from fences: [Fence], in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var index = 0
        while index < fences.count {
            let open = fences[index].line
            let end: Int
            if index + 1 < fences.count {
                end = NSMaxRange(fences[index + 1].line)
            } else if NSMaxRange(ns.lineRange(for: NSRange(location: open.location, length: 0))) >= ns.length {
                end = NSMaxRange(open)                              // still open, nothing after it
            } else {
                // Still open: it runs to the end of the last line.
                end = NSMaxRange(contentRange(of: ns.lineRange(for: NSRange(location: ns.length - 1, length: 0)), in: ns))
            }
            result.append(NSRange(location: open.location, length: end - open.location))
            index += 2
        }
        return result
    }

    // MARK: Helpers

    /// The line without its break.
    static func contentRange(of full: NSRange, in ns: NSString) -> NSRange {
        var end = NSMaxRange(full)
        while end > full.location, isBreak(ns.character(at: end - 1)) { end -= 1 }
        return NSRange(location: full.location, length: end - full.location)
    }

    private static func isBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }

    private static let whitespace = CharacterSet.whitespaces

    /// Nothing but spaces and tabs — `trimmingCharacters(in: .whitespaces).isEmpty`, without
    /// making a string of every line.
    static func isBlank(_ range: NSRange, in ns: NSString) -> Bool {
        var index = range.location
        while index < NSMaxRange(range) {
            let unit = ns.character(at: index)
            if unit != 0x20, unit != 0x09 {
                guard let scalar = Unicode.Scalar(unit), whitespace.contains(scalar) else { return false }
            }
            index += 1
        }
        return true
    }
}

/// Keeps the notepad's look in step with its text, drawing again only what an edit made stale
/// (see `NotepadStyle`). It is the text storage's delegate: every change of characters — typing,
/// a paste, undo, text a composition is still marking — is noted as it happens, the fence lines
/// are kept current with it, and the stale lines are drawn right there, inside the same round of
/// editing (`willProcessEditing`). The layout manager then hears of one edit — characters and
/// attributes together — and lays out only those lines again. Drawn in an editing round of its
/// own, after the characters' round, the same few attributes made TextKit 1 lay out everything
/// below them again: 39 ms per key at 64 KB instead of 2 (`NotepadStyleTests`).
///
/// While `lookNow` answers nil (a composition is open), what changed is kept, and drawn by the
/// next `restyle(look:)` or the next edit that may draw.
final class NotepadStyler: NSObject, NSTextStorageDelegate {
    private weak var storage: NSTextStorage?
    /// Every fence line of the text as it is now, top to bottom.
    private(set) var fences: [NotepadStyle.Fence] = []
    /// What changed since the last restyle, in the text as it is now; nil when nothing did.
    private(set) var pending: NSRange?
    /// The fonts of the last restyle; nil before the first one and after `invalidate()`.
    private(set) var attributes: NotepadStyle.Attributes?
    /// The look to draw an edit in as it happens, or nil to leave it for later — the text view's
    /// input method may still be composing (marked text must not be restyled under it).
    var lookNow: (() -> NotepadStyle.Look?)?

    /// Starts keeping `storage`'s look; the first restyle draws all of it.
    func attach(to storage: NSTextStorage) {
        self.storage = storage
        storage.delegate = self
        let ns = storage.string as NSString
        fences = NotepadStyle.fences(in: ns, lines: NSRange(location: 0, length: ns.length))
        pending = nil
        attributes = nil
    }

    /// The next restyle draws everything.
    func invalidate() { attributes = nil }

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        noteEdit(in: textStorage.string as NSString, range: editedRange, delta: delta)
        // Attributes changed here join the edit that is being processed: no editing round of our own.
        if let look = lookNow?() { draw(look: look, grouped: false) }
    }

    /// The characters in `edited` (in the text as it is now) replaced others; the text is `delta`
    /// longer than before. Keeps the fence lines current and notes what has to be drawn again.
    func noteEdit(in ns: NSString, range edited: NSRange, delta: Int) {
        let length = ns.length
        var dirty = edited
        if let earlier = pending {
            dirty = NSUnionRange(NotepadStyle.map(earlier, through: edited, delta: delta, length: length), edited)
        }
        // The fences around the edit, before and after it; those above it stay, those below move.
        let region = NotepadStyle.lines(around: edited, in: ns)
        let low = NotepadStyle.fenceCount(before: region.location, in: fences)
        let high = NotepadStyle.fenceCount(before: NSMaxRange(region) - delta, in: fences)
        let above = fences[..<low]
        let old = fences[low..<high]
        let below = fences[high...].map { $0.shifted(by: delta) }
        let new = NotepadStyle.fences(in: ns, lines: region)
        var end = NSMaxRange(region)
        if old.count % 2 != new.count % 2 {
            // A block opened or closed: every line below changed sides.
            end = length
        } else if (low + new.count) % 2 == 1,
                  (old.last ?? above.last)?.language != (new.last ?? above.last)?.language {
            // The block that runs on below the edit names another language: its colours change.
            end = below.first?.line.location ?? length
        }
        fences = Array(above) + new + below
        pending = NSUnionRange(dirty, NSRange(location: region.location, length: end - region.location))
    }

    /// Draws what changed since the last restyle — everything when the look changed or none was
    /// drawn yet — in an editing round of its own. Answers the range it drew, nil when nothing was
    /// stale (the edits were drawn as they happened).
    @discardableResult
    func restyle(look: NotepadStyle.Look) -> NSRange? { draw(look: look, grouped: true) }

    /// `grouped`: between `beginEditing` and `endEditing` — not inside `willProcessEditing`, where
    /// the edit being processed carries the attributes along.
    @discardableResult
    private func draw(look: NotepadStyle.Look, grouped: Bool) -> NSRange? {
        guard let storage else { return nil }
        let ns = storage.string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let current = attributes, current.look == look else {
            let fresh = NotepadStyle.Attributes(look)
            attributes = fresh
            return restyleAll(storage, ns, fresh, grouped: grouped)
        }
        guard let dirty = pending else { return nil }
        pending = nil
        let clamped = NSIntersectionRange(dirty, whole)
        let lines = NotepadStyle.wholeSequences(
            ns.lineRange(for: NSRange(location: min(clamped.location, ns.length), length: clamped.length)), in: ns)
        var range = lines
        var strikes: [NSRange] = []
        // A prompt is struck through as a whole: where one around the edit is, or was, all of it is
        // drawn again. Where none is, the lines are enough.
        var extent = lines
        while true {
            let grown = NotepadStyle.wholeSequences(
                NotepadStyle.promptExtent(of: extent, in: ns, fences: fences, returns: look.returns), in: ns)
            if grown == extent { break }
            extent = grown
        }
        let done = NotepadStyle.strikes(in: ns, range: extent, fences: fences, returns: look.returns)
        let before = NSRange(location: extent.location, length: lines.location - extent.location)
        let after = NSRange(location: NSMaxRange(lines), length: NSMaxRange(extent) - NSMaxRange(lines))
        if !done.isEmpty || NotepadStyle.hasStrike(in: storage, range: before)
            || NotepadStyle.hasStrike(in: storage, range: after) {
            range = extent
            strikes = done
        }
        if range == whole { return restyleAll(storage, ns, current, grouped: grouped) }
        NotepadStyle.apply(to: storage, range: range, text: ns, fences: fences, attributes: current, strikes: strikes,
                           grouped: grouped)
        return range
    }

    private func restyleAll(_ storage: NSTextStorage, _ ns: NSString, _ attributes: NotepadStyle.Attributes,
                            grouped: Bool) -> NSRange {
        let whole = NSRange(location: 0, length: ns.length)
        fences = NotepadStyle.fences(in: ns, lines: whole)
        pending = nil
        let strikes = NotepadStyle.strikes(in: ns, range: whole, fences: fences, returns: attributes.look.returns)
        NotepadStyle.apply(to: storage, range: whole, text: ns, fences: fences, attributes: attributes, strikes: strikes,
                           grouped: grouped)
        return whole
    }

    /// The fenced blocks, from the fence lines — exact also between an edit and the restyle after
    /// it. While the storage is still in the middle of an edit, read from the text itself.
    func blocks() -> [NotepadCode.Block] {
        guard let storage else { return [] }
        if storage.editedMask.contains(.editedCharacters) { return NotepadCode.blocks(in: storage.string) }
        return NotepadStyle.blocks(from: fences, in: storage.string as NSString)
    }

    func blockRanges() -> [NSRange] {
        guard let storage else { return [] }
        if storage.editedMask.contains(.editedCharacters) { return NotepadCode.blocks(in: storage.string).map(\.range) }
        return NotepadStyle.blockRanges(from: fences, in: storage.string as NSString)
    }
}

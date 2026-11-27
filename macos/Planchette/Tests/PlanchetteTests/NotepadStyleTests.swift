import AppKit
import XCTest
@testable import Planchette

/// The notepad draws again only what an edit made stale (`NotepadStyle`, `NotepadStyler`). The
/// look must be the one a full restyle of the text gives, attribute for attribute, after every
/// edit — and the full restyle must be the one the pad always drew (`OriginalRestyle`, the code
/// of `NotepadEditor.Coordinator.restyle()` before it became incremental, kept here verbatim).
final class NotepadStyleTests: XCTestCase {
    // MARK: The reference

    /// The pad's restyle as it was before it became incremental: everything, on every key.
    enum OriginalRestyle {
        static func apply(to storage: NSTextStorage, width: Double, returns: Int) {
            let size = NotepadMarkdown.bodySize(forWidth: width)
            let body = NSFont.systemFont(ofSize: size)
            let mono = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
            let code = NSFont.monospacedSystemFont(ofSize: (size * 0.85).rounded(), weight: .regular)
            let spacing = NotepadMarkdown.lineSpacing(forBodySize: size)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            let codeParagraph = NSMutableParagraphStyle()
            codeParagraph.lineSpacing = 1
            codeParagraph.tabStops = []
            codeParagraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: code]).width
            let plain: [NSAttributedString.Key: Any] = [
                .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            let string = storage.string
            let text = string as NSString
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(plain, range: whole)
            func derive(_ range: NSRange, _ change: (NSFont) -> NSFont) {
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    storage.addAttribute(.font, value: change(value as? NSFont ?? body), range: sub)
                }
            }
            for span in NotepadMarkdown.spans(in: string) where NSMaxRange(span.range) <= storage.length {
                switch span.style {
                case .heading(let level):
                    let big = NSFont.systemFont(
                        ofSize: size * NotepadMarkdown.headingScale(level: level, forWidth: width), weight: .bold)
                    storage.addAttribute(.font, value: big, range: span.range)
                case .codeBlock:
                    storage.addAttributes([.font: code, .paragraphStyle: codeParagraph], range: span.range)
                case .inlineCode:
                    storage.addAttributes([
                        .font: mono, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
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
                    let lead = text.substring(with: NSRange(location: span.range.location, length: prefix))
                    let indent = (lead as NSString).size(withAttributes: [.font: body]).width
                    let item = NSMutableParagraphStyle()
                    item.lineSpacing = spacing
                    item.headIndent = indent
                    storage.addAttribute(.paragraphStyle, value: item, range: span.range)
                case .taskBox(let checked):
                    storage.addAttributes([
                        .font: mono,
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
            for block in NotepadCode.blocks(in: string) {
                for line in block.lines where NSMaxRange(line) <= storage.length {
                    for token in NotepadCode.tokens(in: text.substring(with: line), language: block.language) {
                        let range = NSRange(location: line.location + token.range.location, length: token.range.length)
                        storage.addAttribute(.foregroundColor, value: color(of: token.token), range: range)
                    }
                }
            }
            for prompt in NotepadPrompts.prompts(in: string, returns: returns) where prompt.isDone {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: prompt.range)
            }
            storage.endEditing()
        }

        private static func color(of token: NotepadCode.Token) -> NSColor {
            switch token {
            case .keyword: .systemPink
            case .string: .systemRed
            case .comment: .secondaryLabelColor
            case .number: .systemBlue
            case .type: .systemPurple
            }
        }

        static func styled(_ text: String, width: Double, returns: Int) -> NSTextStorage {
            let storage = NSTextStorage(string: text)
            apply(to: storage, width: width, returns: returns)
            return storage
        }
    }

    /// How the pad cut its text into prompts before it was made faster, verbatim.
    enum OriginalPrompts {
        private static func isBreak(_ unit: unichar) -> Bool {
            unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
        }

        private struct Line {
            let full: NSRange
            let content: NSRange
            let isBlank: Bool
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

        static func prompts(in text: String, returns: Int) -> [NotepadPrompts.Prompt] {
            let ns = text as NSString
            let all = lines(in: ns)
            let needed = NotepadLook.sanitized(returns: returns)
            let filled = all.indices.filter { !all[$0].isBlank || all[$0].inFence }
            var groups: [[Int]] = []
            for index in filled {
                if let last = groups.last?.last, index - last - 1 + 1 < needed {
                    groups[groups.count - 1].append(index)
                } else {
                    groups.append([index])
                }
            }
            let doneMark = NotepadPrompts.doneMark
            return groups.map { group in
                let first = all[group[0]], last = all[group[group.count - 1]]
                let range = NSRange(location: first.content.location,
                                    length: NSMaxRange(last.content) - first.content.location)
                let text = normalized(ns.substring(with: range))
                if text.count > 2 * doneMark.count, text.hasPrefix(doneMark), text.hasSuffix(doneMark) {
                    let inner = text.dropFirst(doneMark.count).dropLast(doneMark.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty { return NotepadPrompts.Prompt(range: range, text: inner, isDone: true) }
                }
                return NotepadPrompts.Prompt(range: range, text: text)
            }
        }

        private static func normalized(_ text: String) -> String {
            var result = text
            for separator in ["\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"] {
                result = result.replacingOccurrences(of: separator, with: "\n")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Comparing

    /// The first place where two styled texts differ, described; nil when they are the same text
    /// with the same attributes on every character.
    static func difference(_ a: NSAttributedString, _ b: NSAttributedString) -> String? {
        guard a.string == b.string else { return "the texts differ" }
        var index = 0
        while index < a.length {
            var ra = NSRange(), rb = NSRange()
            let left = a.attributes(at: index, effectiveRange: &ra)
            let right = b.attributes(at: index, effectiveRange: &rb)
            if !(left as NSDictionary).isEqual(to: right) {
                let line = (a.string as NSString).lineRange(for: NSRange(location: index, length: 0))
                return "at \(index) (line \(escaped((a.string as NSString).substring(with: line)))):\n"
                    + "  incremental \(left)\n  full        \(right)"
            }
            index = min(NSMaxRange(ra), NSMaxRange(rb))
        }
        return nil
    }

    static func escaped(_ text: String, limit: Int = 400) -> String {
        let shown = text.count > limit ? String(text.prefix(limit)) + "…(\(text.count) characters)" : text
        return shown.unicodeScalars.map { scalar in
            switch scalar {
            case "\n": "\\n"
            case "\r": "\\r"
            case "\t": "\\t"
            default:
                scalar.value < 0x20 || (0x7F..<0xA0).contains(scalar.value) || (0x2000..<0x2100).contains(scalar.value)
                    ? "\\u{\(String(scalar.value, radix: 16))}" : String(scalar)
            }
        }.joined()
    }

    // MARK: Random documents and edits

    /// SplitMix64: the same seed gives the same documents and edits on every machine.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let lineTemplates: [String] = [
        "# Title", "## Part *it*", "### three **b**", "####### seven", "#hashtag", "   ### indented", "#",
        "- item", "* star item", "+ plus", "1. one", "12) twelve", "- [ ] task", "- [x] done task",
        "  - nested item", "1. [ ] not a task", "-no space", "- [x]", "* [ ] star task",
        "> quote **b**", ">no space", "   > deep",
        "```", "```swift", "```py", "  ```js  ", "```SQL", "```bash", "````", "~~~", "``", "x```",
        "let x = 42 // comment", "func f() { return \"s\" }", "SELECT * FROM t WHERE a = 1 -- c",
        "def f(x): # comment", "echo $HOME 'it''s'", "    indented code;", "if (a) {", "}", "0x1F + 3.5",
        "plain words here", "**bold** and *it* and `code` and [link](https://x.y/z)", "under_score_word",
        "__b__ _i_ ***both***", "a `tick` b `` c", "[words](http://a.b) and [no](ftp://x)",
        "~~struck prompt~~", "~~", "~~a", "b~~", "~~ ~~", "~~x~~ y", "~~~~", "~~**bold** struck~~",
        "", "", "", "   ", "\t", "\u{00A0}", "\u{3000}", " \u{2003} ",
        "emoji 😀👍🏽 family 👨‍👩‍👧", "e\u{301}cole", "`\u{301}``", "\u{1FEF}\u{1FEF}\u{1FEF}", "```\u{301}x",
        "tab\tseparated", "café ñ 日本語", "- 😀 item", "# 👍🏽",
    ]

    static let breaks = ["\n", "\n", "\n", "\n", "\n", "\n", "\n", "\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"]

    static let snippets: [String] = [
        "a", "b", " ", " ", "\n", "\n", "\n", "`", "`", "~", "~", "#", "-", "*", "_", "[", "]", "(", ")", "x",
        ">", "1", ".", "\t", "\r", "\r\n", "\u{2028}", "😀", "\u{301}", "\u{00A0}",
        "```", "```swift\n", "\n```\n", "```\n", "\n```", "~~", "- [ ] ", "- [x] ", "# ", "> ", "**", "\n\n",
        "\n\n\n", "    ", "let y = 1", "[t](https://e.com)", "~~done~~",
    ]

    static func document<G: RandomNumberGenerator>(lines: Int, using rng: inout G) -> String {
        var text = ""
        for index in 0..<lines {
            if index > 0 { text += breaks.randomElement(using: &rng)! }
            var line = lineTemplates.randomElement(using: &rng)!
            if Int.random(in: 0..<4, using: &rng) == 0 { line += " " + lineTemplates.randomElement(using: &rng)! }
            text += line
        }
        if Bool.random(using: &rng) { text += "\n" }
        return text
    }

    /// A position that does not split a surrogate pair — the text view never does that.
    static func boundary(_ location: Int, in ns: NSString) -> Int {
        var at = min(max(location, 0), ns.length)
        if at > 0, at < ns.length, CFStringIsSurrogateLowCharacter(ns.character(at: at)),
           CFStringIsSurrogateHighCharacter(ns.character(at: at - 1)) {
            at -= 1
        }
        return at
    }

    static func randomRange<G: RandomNumberGenerator>(in ns: NSString, maxLength: Int, using rng: inout G) -> NSRange {
        let start = boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
        let end = boundary(min(start + Int.random(in: 0...maxLength, using: &rng), ns.length), in: ns)
        return NSRange(location: start, length: max(end - start, 0))
    }

    // MARK: Harness

    /// A text storage that never fixes its attributes (no font substitution for emoji, no paragraph
    /// style made whole per paragraph): what the styler wrote is exactly what is read back.
    final class UnfixedStorage: NSTextStorage {
        private let backing = NSMutableAttributedString()

        override init() { super.init() }
        convenience init(text: String) {
            self.init()
            backing.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        required init?(coder: NSCoder) { fatalError() }
        required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
            fatalError()
        }

        override var string: String { backing.string }
        // Without this, every attribute lookup asks for `string`, a copy of the whole text.
        override var length: Int { backing.length }
        override var fixesAttributesLazily: Bool { true }
        override func attributes(at location: Int, effectiveRange range: NSRangePointer?)
            -> [NSAttributedString.Key: Any] {
            backing.attributes(at: location, effectiveRange: range)
        }
        override func replaceCharacters(in range: NSRange, with text: String) {
            beginEditing()
            backing.replaceCharacters(in: range, with: text)
            edited(.editedCharacters, range: range, changeInLength: (text as NSString).length - range.length)
            endEditing()
        }
        override func setAttributes(_ attributes: [NSAttributedString.Key: Any]?, range: NSRange) {
            beginEditing()
            backing.setAttributes(attributes, range: range)
            edited(.editedAttributes, range: range, changeInLength: 0)
            endEditing()
        }
    }

    enum StorageKind {
        /// Never fixed: compares the styling alone.
        case unfixed
        /// AppKit's own storage, fixed when read, as in the pad.
        case appKit
        /// AppKit's own storage with a layout manager, laid out after every restyle.
        case laidOut
    }

    static func makeStorage(_ text: String, _ kind: StorageKind) -> NSTextStorage {
        kind == .unfixed ? UnfixedStorage(text: text) : NSTextStorage(string: text)
    }

    /// A text storage kept by a styler, as the pad keeps it, next to the full restyle of its text.
    final class Pad {
        let storage: NSTextStorage
        let kind: StorageKind
        let styler = NotepadStyler()
        var look: NotepadStyle.Look
        var width: Double
        let layout: NSLayoutManager?
        let container: NSTextContainer?

        init(_ text: String, width: Double, returns: Int, kind: StorageKind = .unfixed, inline: Bool = true,
             keepsPrompts: Bool = true) {
            drawsInline = inline
            storage = NotepadStyleTests.makeStorage(text, kind)
            self.kind = kind
            let withLayout = kind == .laidOut
            self.width = width
            look = NotepadStyle.Look(width: width, returns: returns)
            if withLayout {
                let layout = NSLayoutManager()
                let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
                storage.addLayoutManager(layout)
                layout.addTextContainer(container)
                self.layout = layout
                self.container = container
            } else {
                layout = nil
                container = nil
            }
            styler.attach(to: storage)
            styler.restyle(look: look)
            if keepsPrompts { _ = styler.prompts(returns: returns) }    // cut once; kept with every edit after
            // As the pad: every edit is drawn as it is processed, unless a composition is open.
            styler.lookNow = { [unowned self] in self.drawsInline && !self.composing ? self.look : nil }
        }

        /// False: edits are drawn only by `restyle()`, in a round of editing of their own.
        var drawsInline = true
        /// An input method's composition is open: nothing may be drawn.
        var composing = false

        /// What the text view puts in: the characters, with the typing attributes (or, for undo and
        /// a paste, with whatever attributes they had).
        func replace(_ range: NSRange, with text: String, attributes: [NSAttributedString.Key: Any]? = nil) {
            storage.replaceCharacters(in: range, with: NSAttributedString(
                string: text, attributes: attributes ?? styler.attributes?.plain ?? [:]))
        }

        @discardableResult
        func restyle() -> NSRange? {
            let drawn = styler.restyle(look: look)
            if let layout, let container { layout.ensureLayout(for: container) }
            return drawn
        }

        /// Nil when the pad looks exactly as a full restyle of its text, and its fences and blocks
        /// are what a scan of the text finds.
        func mismatch() -> String? {
            let reference = NotepadStyleTests.makeStorage(storage.string, kind)
            OriginalRestyle.apply(to: reference, width: width, returns: look.returns)
            if kind != .unfixed {
                // AppKit fixes fonts and paragraphs when the text is read or laid out; fix both.
                storage.ensureAttributesAreFixed(in: NSRange(location: 0, length: storage.length))
                reference.ensureAttributesAreFixed(in: NSRange(location: 0, length: reference.length))
            }
            if let difference = NotepadStyleTests.difference(storage, reference) { return difference }
            let ns = storage.string as NSString
            let scanned = NotepadStyle.fences(in: ns, lines: NSRange(location: 0, length: ns.length))
            if styler.fences != scanned { return "fences \(styler.fences) != scanned \(scanned)" }
            let blocks = NotepadCode.blocks(in: storage.string)
            if styler.blocks() != blocks { return "blocks \(styler.blocks()) != \(blocks)" }
            if styler.blockRanges() != blocks.map(\.range) {
                return "block ranges \(styler.blockRanges()) != \(blocks.map(\.range))"
            }
            return promptMismatch()
        }

        /// Nil when the kept prompts, the code bar's suggestion in each prompt and the fenced lines
        /// are what the whole text gives — also while nothing is drawn (a composition).
        func promptMismatch() -> String? {
            let text = storage.string
            let ns = text as NSString
            let fresh = NotepadPrompts.prompts(in: text, returns: look.returns)
            if fresh != OriginalPrompts.prompts(in: text, returns: look.returns) {
                return "a fresh cut differs from the original cut"
            }
            let kept = styler.prompts(returns: look.returns)
            if kept != fresh {
                let first = zip(kept, fresh).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    ?? min(kept.count, fresh.count)
                return "prompts differ at \(first) of \(kept.count) kept / \(fresh.count) cut: "
                    + "\(kept.dropFirst(first).first.map { "\($0)" } ?? "none") vs "
                    + "\(fresh.dropFirst(first).first.map { "\($0)" } ?? "none")"
            }
            // The prompt under a few insertion points, and the code bar's offer in it.
            for location in [0, ns.length / 3, ns.length / 2, ns.length] {
                let at = NotepadStyleTests.boundary(location, in: ns)
                let prompt = NotepadPrompts.promptValue(at: at, among: kept, length: ns.length)
                if prompt != NotepadPrompts.promptValue(at: at, in: text, returns: look.returns) {
                    return "the prompt at \(at) differs"
                }
                if let prompt, styler.suggestion(within: prompt.range, of: text)
                    != NotepadCode.suggestion(within: prompt.range, of: text) {
                    return "the suggestion in \(prompt.range) differs"
                }
            }
            let fenced = Set(NotepadCode.blocks(in: text).flatMap { block in
                [block.open.location] + block.lines.map(\.location) + (block.close.map { [$0.location] } ?? [])
            })
            var location = 0
            while location < ns.length {
                if NotepadStyle.isFenced(lineAt: location, in: styler.fences) != fenced.contains(location) {
                    return "the line at \(location) is fenced: \(fenced.contains(location))"
                }
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            }
            return nil
        }
    }

    static var baseSeed: UInt64 {
        ProcessInfo.processInfo.environment["NOTEPAD_STYLE_SEED"].flatMap(UInt64.init) ?? 0x5EED_2026_1127
    }

    /// Random edits on random documents; after every restyle the pad must be the full restyle.
    /// Each step is `batch` edits, grouped in one round of editing or not. Now and then an input
    /// method composes over a few steps: nothing is drawn until it ends, and the pad is checked
    /// then. `inline`: edits are drawn as they are processed, as in the pad; false, only by
    /// `restyle()`. `kind` is the storage the edits go to (`StorageKind`).
    private func walk(seed: UInt64, documents: Int, edits: Int, lines: ClosedRange<Int>,
                      batch: ClosedRange<Int> = 1...1, inline: Bool = true, kind: StorageKind = .unfixed,
                      file: StaticString = #filePath, line: UInt = #line) -> Int {
        var rng = SeededGenerator(seed: seed)
        var checked = 0
        for documentIndex in 0..<documents {
            let text = Self.document(lines: Int.random(in: lines, using: &rng), using: &rng)
            let returns = Int.random(in: 1...3, using: &rng)
            let width = [180.0, 260, 300, 500].randomElement(using: &rng)!
            let pad = Pad(text, width: width, returns: returns, kind: kind)
            pad.drawsInline = inline
            var composingSteps = 0
            if let problem = pad.mismatch() {
                XCTFail("seed \(seed), document \(documentIndex), first restyle: \(problem)\n"
                        + "text: \(Self.escaped(text))", file: file, line: line)
                return checked
            }
            var history: [String] = []
            var editIndex = 0
            while editIndex < edits {
                var described: [String] = []
                if composingSteps == 0, Int.random(in: 0..<10, using: &rng) == 0 {
                    composingSteps = Int.random(in: 1...4, using: &rng)
                    described.append("composition starts")
                }
                pad.composing = composingSteps > 0
                let count = Int.random(in: batch, using: &rng)
                let grouped = count > 1 && Bool.random(using: &rng)
                if grouped { pad.storage.beginEditing() }
                for _ in 0..<count { described.append(randomEdit(pad, using: &rng)) }
                if grouped { pad.storage.endEditing() }
                // Now and then someone else changes attributes only (a font, a format).
                if Int.random(in: 0..<12, using: &rng) == 0 {
                    let range = Self.randomRange(in: pad.storage.string as NSString, maxLength: 40, using: &rng)
                    pad.storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: 21), .kern: 3], range: range)
                    described.append("attributes set over \(range)")
                }
                editIndex += 1
                // Now and then the pad gets wider or narrower, or the Returns per prompt change.
                if Int.random(in: 0..<40, using: &rng) == 0 {
                    pad.look = NotepadStyle.Look(width: pad.width, returns: Int.random(in: 1...3, using: &rng))
                    described.append("returns → \(pad.look.returns)")
                }
                if composingSteps > 0 {
                    composingSteps -= 1
                    if composingSteps > 0 {
                        history.append(described.joined(separator: "; "))
                        // The text view draws nothing meanwhile; the margin still reads the prompts.
                        if let problem = pad.promptMismatch() {
                            XCTFail("seed \(seed), document \(documentIndex), edit \(editIndex), composing: "
                                    + "\(problem)\ntext now: \(Self.escaped(pad.storage.string))",
                                    file: file, line: line)
                            return checked
                        }
                        continue
                    }
                    pad.composing = false
                    described.append("composition ends")
                }
                history.append(described.joined(separator: "; "))
                pad.restyle()
                checked += 1
                if let problem = pad.mismatch() {
                    XCTFail("""
                        seed \(seed) (set NOTEPAD_STYLE_SEED to replay), document \(documentIndex), \
                        edit \(editIndex), returns \(pad.look.returns): \(problem)
                        last edits: \(history.suffix(4).joined(separator: " | "))
                        document before: \(Self.escaped(text))
                        text now: \(Self.escaped(pad.storage.string))
                        """, file: file, line: line)
                    return checked
                }
                // Laying the text out and AppKit's fixing of fonts are not edits of anyone's.
                if let left = pad.styler.pending {
                    XCTFail("seed \(seed), document \(documentIndex), edit \(editIndex): \(left) is still "
                            + "pending after the restyle and the layout", file: file, line: line)
                    return checked
                }
            }
        }
        return checked
    }

    /// How many times deeper the walks go: NOTEPAD_DEEP=n runs each of them with n seeds.
    static var depth: Int {
        max(ProcessInfo.processInfo.environment["NOTEPAD_DEEP"].flatMap(Int.init) ?? 1, 1)
    }

    /// `walk`, once per seed of the depth asked for; the number of steps checked in all.
    private func walks(seed: UInt64, documents: Int, edits: Int, lines: ClosedRange<Int>,
                       batch: ClosedRange<Int> = 1...1, inline: Bool = true, kind: StorageKind = .unfixed,
                       file: StaticString = #filePath, line: UInt = #line) -> Int {
        (0..<Self.depth).reduce(0) { total, round in
            total + walk(seed: seed &+ UInt64(round) &* 1_000_003, documents: documents, edits: edits,
                         lines: lines, batch: batch, inline: inline, kind: kind, file: file, line: line)
        }
    }

    /// One edit the way a person (or undo, or a paste) makes it; answers what it did.
    private func randomEdit<G: RandomNumberGenerator>(_ pad: Pad, using rng: inout G) -> String {
        let ns = pad.storage.string as NSString
        let roll = Int.random(in: 0..<100, using: &rng)
        switch roll {
        case 0..<30:                                                       // type a snippet
            let at = Self.boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
            let snippet = Self.snippets.randomElement(using: &rng)!
            pad.replace(NSRange(location: at, length: 0), with: snippet)
            return "insert \(Self.escaped(snippet)) at \(at)"
        case 30..<50:                                                      // delete
            let range = Self.randomRange(in: ns, maxLength: Bool.random(using: &rng) ? 2 : 40, using: &rng)
            pad.replace(range, with: "")
            return "delete \(range)"
        case 50..<62:                                                      // select and type over
            let range = Self.randomRange(in: ns, maxLength: 30, using: &rng)
            let snippet = Self.snippets.randomElement(using: &rng)!
            pad.replace(range, with: snippet)
            return "replace \(range) with \(Self.escaped(snippet))"
        case 62..<72:                                                      // a fence, typed or removed
            let at = Self.boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
            let found = ns.range(of: "```", options: .literal,
                                 range: NSRange(location: at, length: ns.length - at))
            if found.location != NSNotFound, Bool.random(using: &rng) {
                let cut = NSRange(location: found.location, length: Int.random(in: 1...3, using: &rng))
                pad.replace(cut, with: "")
                return "remove fence backticks \(cut)"
            }
            let fence = ["```", "\n```", "```\n", "```py", "\n```swift\n"].randomElement(using: &rng)!
            pad.replace(NSRange(location: at, length: 0), with: fence)
            return "insert fence \(Self.escaped(fence)) at \(at)"
        case 72..<80:                                                      // strike or unstrike a prompt
            let at = Self.boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
            let found = ns.range(of: "~", options: .literal, range: NSRange(location: at, length: ns.length - at))
            if found.location != NSNotFound, Bool.random(using: &rng) {
                pad.replace(found, with: "")
                return "remove tilde at \(found.location)"
            }
            pad.replace(NSRange(location: at, length: 0), with: "~~")
            return "insert ~~ at \(at)"
        case 80..<88:                                                      // undo, a paste: own attributes
            let at = Self.boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
            let snippet = Self.lineTemplates.randomElement(using: &rng)! + "\n"
            pad.replace(NSRange(location: at, length: 0), with: snippet, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.systemRed,
                .font: NSFont.boldSystemFont(ofSize: 20),
            ])
            return "paste \(Self.escaped(snippet)) with attributes at \(at)"
        case 88..<93:                                                      // a line break, typed or deleted
            let at = Self.boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
            let found = ns.rangeOfCharacter(from: .newlines, options: [],
                                            range: NSRange(location: at, length: ns.length - at))
            if found.location != NSNotFound, Bool.random(using: &rng) {
                pad.replace(found, with: "")
                return "delete break at \(found.location)"
            }
            pad.replace(NSRange(location: at, length: 0), with: "\n")
            return "insert break at \(at)"
        case 93..<96:                                                      // a big change
            let range = Self.randomRange(in: ns, maxLength: ns.length, using: &rng)
            let text = Self.document(lines: Int.random(in: 0...12, using: &rng), using: &rng)
            pad.replace(range, with: text)
            return "replace \(range) with a document of \((text as NSString).length)"
        default:                                                           // insert with the string API
            let at = Self.boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
            let snippet = Self.snippets.randomElement(using: &rng)!
            pad.storage.replaceCharacters(in: NSRange(location: at, length: 0), with: snippet)
            return "insert (inheriting attributes) \(Self.escaped(snippet)) at \(at)"
        }
    }

    // MARK: Equivalence

    func testTheFullRestyleIsTheOriginalOne() {
        let documents = [
            "", "\n", "\n\n\n", "a", "# Title", "```", "```\n", "```swift\nlet x = 1\n```", "~~done~~",
            "~~a\nb~~\n\nc", "- [x] done\n- [ ] open", "> **q** `c` [l](https://a.b)", "a\r\nb\r\n\r\nc",
            "x\u{2028}y\u{2029}z\u{85}w", "😀\n```\n😀 // c\n", "e\u{301}\n\u{00A0}\n~~ x ~~",
        ]
        for text in documents {
            for returns in 1...3 {
                for width in [100.0, 220, 333, 420, 900] {
                    let pad = Pad(text, width: width, returns: returns)
                    XCTAssertNil(pad.mismatch(), "\(Self.escaped(text)) returns \(returns) width \(width)")
                }
            }
        }
    }

    // The walks below check about 6,000 steps by default; NOTEPAD_DEEP=n runs each with n seeds.

    func testRandomEditsLookExactlyLikeAFullRestyle() {
        let checked = walks(seed: Self.baseSeed, documents: 30, edits: 60, lines: 0...40)
        XCTAssertGreaterThanOrEqual(checked, 1400 * Self.depth)
    }

    func testTypingInLongerDocumentsLooksExactlyLikeAFullRestyle() {
        let checked = walks(seed: Self.baseSeed &+ 1, documents: 5, edits: 100, lines: 80...200)
        XCTAssertGreaterThanOrEqual(checked, 380 * Self.depth)
    }

    /// Several edits in one step, grouped in one round of editing (NSTextStorage reports them as
    /// one) or each in its own.
    func testEditsDrawnTogetherLookExactlyLikeAFullRestyle() {
        let checked = walks(seed: Self.baseSeed &+ 2, documents: 20, edits: 40, lines: 0...30, batch: 1...6)
        XCTAssertGreaterThanOrEqual(checked, 600 * Self.depth)
    }

    /// Edits drawn only by the restyle after them, in a round of editing of its own — the way the
    /// pad draws while it has no look to draw in yet, and what a composition leaves behind.
    func testEditsDrawnAfterwardsLookExactlyLikeAFullRestyle() {
        let checked = walks(seed: Self.baseSeed &+ 6, documents: 15, edits: 50, lines: 0...40, batch: 1...3,
                            inline: false)
        XCTAssertGreaterThanOrEqual(checked, 550 * Self.depth)
    }

    /// AppKit's own text storage fixes attributes when they are read: an emoji gets the emoji font,
    /// a paragraph one paragraph style. That must come out the same as well.
    func testAppKitsStorageLooksExactlyLikeAFullRestyle() {
        let checked = walks(seed: Self.baseSeed &+ 5, documents: 20, edits: 50, lines: 0...30, batch: 1...3,
                            kind: .appKit)
        XCTAssertGreaterThanOrEqual(checked, 750 * Self.depth)
    }

    /// The text laid out after each restyle, as in the pad.
    func testLaidOutTextLooksExactlyLikeAFullRestyle() {
        let checked = walks(seed: Self.baseSeed &+ 3, documents: 8, edits: 40, lines: 0...30, kind: .laidOut)
        XCTAssertGreaterThanOrEqual(checked, 240 * Self.depth)
    }

    /// The prompts the margin and the code bar read are kept with every edit, never cut again from
    /// the whole text: after every step they must be what a fresh cut gives (`Pad.promptMismatch`
    /// runs in every walk; this one is for the prompts alone, drawn afterwards or not at all).
    func testThePromptsAreKeptExactlyAfterEveryEdit() {
        let checked = walks(seed: Self.baseSeed &+ 7, documents: 20, edits: 60, lines: 0...50, batch: 1...3,
                            inline: false)
        XCTAssertGreaterThanOrEqual(checked, 900 * Self.depth)
    }

    func testPromptsForAnotherNumberOfReturnsAreCutAgain() {
        let pad = Pad("a\nb\n\nc\n\n\nd", width: 300, returns: 2)
        XCTAssertEqual(pad.styler.prompts(returns: 2).map(\.text), ["a\nb", "c", "d"])
        XCTAssertEqual(pad.styler.prompts(returns: 3).map(\.text), ["a\nb\n\nc", "d"])
        XCTAssertEqual(pad.styler.prompts(returns: 1).map(\.text), ["a", "b", "c", "d"])
        pad.replace(NSRange(location: 1, length: 0), with: "\n")       // "a\n\nb": a gap at 2 and 3
        XCTAssertEqual(pad.styler.prompts(returns: 1).map(\.text), ["a", "b", "c", "d"])
        XCTAssertEqual(pad.styler.prompts(returns: 2).map(\.text), ["a", "b", "c", "d"])
        XCTAssertEqual(pad.styler.prompts(returns: 3).map(\.text), ["a\n\nb\n\nc", "d"])
    }

    /// An edit is drawn while it is processed — nothing is left for the restyle after it — and not
    /// at all while a composition is open.
    func testAnEditIsDrawnAsItIsProcessed() {
        let pad = Pad("# Head\nplain", width: 300, returns: 2)
        pad.replace(NSRange(location: 7, length: 0), with: "## ")
        XCTAssertNil(pad.styler.pending)
        XCTAssertNil(pad.restyle())
        XCTAssertNil(pad.mismatch())
        pad.composing = true
        pad.replace(NSRange(location: 0, length: 2), with: "")
        XCTAssertNotNil(pad.styler.pending)
        XCTAssertNotNil(pad.mismatch(), "nothing is drawn under a composition")
        pad.composing = false
        XCTAssertNotNil(pad.restyle())
        XCTAssertNil(pad.mismatch())
    }

    func testAFiftyKilobyteDocument() {
        var rng = SeededGenerator(seed: Self.baseSeed &+ 4)
        var text = ""
        while (text as NSString).length < 50_000 { text += Self.document(lines: 40, using: &rng) + "\n" }
        let pad = Pad(text, width: 300, returns: 2)
        XCTAssertNil(pad.mismatch())
        for index in 0..<(15 * Self.depth) {
            let edit = randomEdit(pad, using: &rng)
            pad.restyle()
            if let problem = pad.mismatch() {
                XCTFail("edit \(index) (\(edit)): \(problem)")
                return
            }
        }
    }

    /// Hand-picked sequences around the constructs that reach beyond their line.
    func testHandPickedEditSequences() {
        let cases: [(String, [(NSRange, String)])] = [
            // Typing a fence one backtick at a time above code, then its language, then deleting it.
            ("intro\nlet x = 1\n# not a head\n```\ninside\n```\nafter **b**",
             [((0, 0), "`"), ((1, 0), "`"), ((2, 0), "`"), ((3, 0), "s"), ((4, 0), "w"), ((5, 0), "\n"),
              ((0, 1), ""), ((0, 1), ""), ((0, 1), "")].map { (NSRange(location: $0.0.0, length: $0.0.1), $0.1) }),
            // An unterminated fence closed at the end, and opened again.
            ("```py\ndef f(): # c\n  return 'x'", [((30, 0), "\n```"), ((30, 4), ""), ((0, 3), "")]
                .map { (NSRange(location: $0.0.0, length: $0.0.1), $0.1) }),
            // A struck prompt over two lines: unstrike it from its end, strike it again, split it.
            ("~~first line\nsecond line~~\n\nnext", [((24, 1), ""), ((24, 0), "~"), ((12, 0), "\n"), ((12, 1), "")]
                .map { (NSRange(location: $0.0.0, length: $0.0.1), $0.1) }),
            // Prompts merged by deleting the blank line between them.
            ("~~one~~\n\ntwo\n\n~~three~~", [((7, 1), ""), ((7, 0), "\n"), ((13, 1), "")]
                .map { (NSRange(location: $0.0.0, length: $0.0.1), $0.1) }),
            // CRLF split and joined at a fence.
            ("a\r\n```\r\nb\r\n```\r\nc", [((2, 1), ""), ((2, 0), "\n"), ((1, 1), ""), ((1, 0), "\r")]
                .map { (NSRange(location: $0.0.0, length: $0.0.1), $0.1) }),
            // A blank line inside a code block keeps a prompt whole; deleting the fence splits it.
            ("~~```\ncode\n\nmore\n```~~\n\nx", [((2, 3), ""), ((2, 0), "```"), ((9, 0), "\n")]
                .map { (NSRange(location: $0.0.0, length: $0.0.1), $0.1) }),
            // Everything removed, and written again.
            ("# a\n- [x] b\n```\nc", [((0, 15), ""), ((0, 0), "# a\n- [x] b\n```\nc")]
                .map { (NSRange(location: $0.0.0, length: $0.0.1), $0.1) }),
        ]
        for (text, edits) in cases {
            for returns in 1...3 {
                let pad = Pad(text, width: 300, returns: returns)
                XCTAssertNil(pad.mismatch())
                for (index, (range, replacement)) in edits.enumerated() {
                    let length = pad.storage.length
                    guard NSMaxRange(range) <= length else { XCTFail("edit \(index) out of \(Self.escaped(text))"); break }
                    pad.replace(range, with: replacement)
                    pad.restyle()
                    if let problem = pad.mismatch() {
                        XCTFail("\(Self.escaped(text)) returns \(returns), edit \(index): \(problem)")
                        break
                    }
                }
            }
        }
    }

    // MARK: What is drawn

    private func text(lines count: Int, _ line: String = "just some words in a line") -> String {
        (0..<count).map { "\(line) \($0)" }.joined(separator: "\n")
    }

    func testAKeyInPlainTextDrawsAFewLines() {
        let pad = Pad(text(lines: 400), width: 300, returns: 2, inline: false)
        let at = (pad.storage.string as NSString).range(of: "line 200").location
        pad.replace(NSRange(location: at, length: 0), with: "x")
        let drawn = pad.restyle()!
        let lines = (pad.storage.string as NSString).substring(with: drawn).components(separatedBy: "\n").count
        XCTAssertLessThanOrEqual(lines, 4, "drew \(drawn)")
        XCTAssertNil(pad.mismatch())
    }

    func testAFenceTypedAtTheTopDrawsEverythingBelow() {
        let pad = Pad(text(lines: 200), width: 300, returns: 2, inline: false)
        pad.replace(NSRange(location: 0, length: 0), with: "```\n")
        XCTAssertEqual(pad.restyle(), NSRange(location: 0, length: pad.storage.length))
        XCTAssertNil(pad.mismatch())
        // Its language changes the colours of the block, which runs to the end — and nothing else.
        pad.replace(NSRange(location: 3, length: 0), with: "py")
        XCTAssertEqual(NSMaxRange(pad.restyle()!), pad.storage.length)
        XCTAssertNil(pad.mismatch())
    }

    func testANewLanguageDrawsTheBlockAndNotWhatFollowsIt() {
        let body = text(lines: 300)
        let pad = Pad("```js\nlet a = 1\nconst b = 'x'\n```\n" + body, width: 300, returns: 2, inline: false)
        pad.replace(NSRange(location: 3, length: 2), with: "python")
        let drawn = pad.restyle()!
        XCTAssertLessThan(NSMaxRange(drawn), 80, "drew \(drawn)")
        XCTAssertNil(pad.mismatch())
    }

    func testAStruckPromptIsDrawnWholeWhenItsEndChanges() {
        let long = (0..<30).map { "line \($0)" }.joined(separator: "\n")
        let pad = Pad("~~" + long + "~~\n\nafter", width: 300, returns: 2, inline: false)
        let end = (pad.storage.string as NSString).range(of: "~~\n").location
        pad.replace(NSRange(location: end, length: 1), with: "")       // no longer struck through
        let drawn = pad.restyle()!
        XCTAssertEqual(drawn.location, 0)
        XCTAssertNil(pad.mismatch())
        XCTAssertFalse(NotepadStyle.hasStrike(in: pad.storage, range: NSRange(location: 0, length: 20)))
    }

    func testAPromptWithoutStrikesIsNotDrawnWhole() {
        let pad = Pad(text(lines: 300), width: 300, returns: 2, inline: false)           // one prompt of 300 lines
        let at = (pad.storage.string as NSString).range(of: "line 150").location
        pad.replace(NSRange(location: at, length: 0), with: "~")
        let drawn = pad.restyle()!
        XCTAssertLessThan(drawn.length, 200, "drew \(drawn)")
        XCTAssertNil(pad.mismatch())
    }

    func testANewLookDrawsEverythingAndNothingIsDrawnTwice() {
        let pad = Pad(text(lines: 50), width: 300, returns: 2, inline: false)
        XCTAssertNil(pad.restyle(), "nothing changed")
        pad.look = NotepadStyle.Look(width: 300, returns: 3)
        XCTAssertEqual(pad.restyle(), NSRange(location: 0, length: pad.storage.length))
        pad.width = 1000; pad.look = NotepadStyle.Look(width: 1000, returns: 3)
        XCTAssertEqual(pad.restyle(), NSRange(location: 0, length: pad.storage.length))
        pad.width = 2000; pad.look = NotepadStyle.Look(width: 2000, returns: 3)
        XCTAssertNil(pad.restyle(), "wider than the widest look changes nothing")
        XCTAssertNil(pad.mismatch())
    }

    /// Attributes someone else set (a font, a format) make that stretch stale; the next restyle
    /// draws it as the text says. The styler's own drawing leaves nothing stale.
    func testAttributesSetBySomeoneElseAreDrawnAgain() {
        let pad = Pad("# Head\n" + text(lines: 20), width: 300, returns: 2)
        XCTAssertNil(pad.styler.pending, "the styler's own drawing is not an edit")
        pad.storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 30), range: NSRange(location: 2, length: 3))
        XCTAssertEqual(pad.styler.pending, NSRange(location: 2, length: 3))
        XCTAssertNotNil(pad.mismatch())
        XCTAssertEqual(pad.restyle(), NSRange(location: 0, length: 7), "the line it touched, drawn again")
        XCTAssertNil(pad.styler.pending)
        XCTAssertNil(pad.mismatch())
    }

    private func drawnLines(_ pad: Pad) -> Int {
        guard let drawn = pad.styler.lastDrawn else { return 0 }
        return (pad.storage.string as NSString).substring(with: drawn).components(separatedBy: "\n").count
    }

    /// A ticked task is struck through on its own line; it never makes a key draw its whole prompt.
    func testATickedTaskDoesNotMakeAKeyDrawItsPrompt() {
        for returns in [2, 3] {
            let body = (0..<300).map { "line \($0)" + ($0 % 5 == 4 ? "\n" : "") }.joined(separator: "\n")
            let pad = Pad("- [x] ticked task\n" + body, width: 300, returns: returns)
            let at = (pad.storage.string as NSString).range(of: "line 150").location
            for (index, key) in "typed".enumerated() {
                pad.replace(NSRange(location: at + index, length: 0), with: String(key))
                XCTAssertLessThanOrEqual(drawnLines(pad), 4, "returns \(returns): drew \(pad.styler.lastDrawn!)")
            }
            XCTAssertNil(pad.mismatch())
        }
    }

    /// A key inside a long struck-through prompt draws its lines, struck; the rest of the prompt
    /// keeps its line through. A `~` at its end strikes or frees all of it.
    func testAKeyInsideAStruckPromptDrawsItsLines() {
        let long = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        let pad = Pad("~~" + long + "~~\n\nafter", width: 300, returns: 2)
        let at = (pad.storage.string as NSString).range(of: "line 150").location
        for (index, key) in "typed".enumerated() {
            pad.replace(NSRange(location: at + index, length: 0), with: String(key))
            XCTAssertLessThanOrEqual(drawnLines(pad), 4, "drew \(pad.styler.lastDrawn!)")
            XCTAssertNil(pad.mismatch())
        }
        let end = (pad.storage.string as NSString).range(of: "~~\n").location
        pad.replace(NSRange(location: end, length: 1), with: "")
        XCTAssertEqual(pad.styler.lastDrawn?.location, 0, "freed: all of it is drawn")
        XCTAssertNil(pad.mismatch())
        pad.replace(NSRange(location: end, length: 0), with: "~")
        XCTAssertEqual(pad.styler.lastDrawn?.location, 0, "struck again: all of it is drawn")
        XCTAssertNil(pad.mismatch())
    }

    /// The letters of a fence's name draw to the end only where the colours change: `p` names a
    /// language (none known), `ph`, `php`, `phpx` are the same to the colours, `py` is Python.
    func testTheLettersOfALanguageDrawOnlyWhereTheColoursChange() {
        let pad = Pad("```\n" + text(lines: 300), width: 300, returns: 2)
        let whole = { NSRange(location: 0, length: pad.storage.length) }
        pad.replace(NSRange(location: 3, length: 0), with: "p")
        XCTAssertEqual(pad.styler.lastDrawn, whole(), "a name where there was none")
        for (index, key) in "hpx".enumerated() {
            pad.replace(NSRange(location: 4 + index, length: 0), with: String(key))
            XCTAssertLessThanOrEqual(drawnLines(pad), 3, "drew \(pad.styler.lastDrawn!)")
        }
        XCTAssertNil(pad.mismatch())
        pad.replace(NSRange(location: 4, length: 3), with: "y")             // ```py
        XCTAssertEqual(NSMaxRange(pad.styler.lastDrawn!), pad.storage.length, "Python's colours")
        XCTAssertNil(pad.mismatch())
        XCTAssertEqual(NotepadCode.tokenClass(of: "ts"), NotepadCode.tokenClass(of: "typescript"))
        XCTAssertNotEqual(NotepadCode.tokenClass(of: nil), NotepadCode.tokenClass(of: "x"))
    }

    /// The margin and the code bar read the kept prompts: typing cuts the whole text into prompts
    /// never, and each key draws its line.
    func testTypingCutsNoPromptsAndDrawsItsLine() {
        let pad = Pad(text(lines: 400) + "\n\n" + text(lines: 400), width: 300, returns: 2)
        XCTAssertEqual(pad.styler.fullPromptCuts, 1)
        var at = (pad.storage.string as NSString).range(of: "line 200").location
        for key in "a key, typed\n\nand more" {
            pad.replace(NSRange(location: at, length: 0), with: String(key))
            at += 1
            _ = pad.styler.prompts(returns: 2)
            // A Return makes one line two: the lines around it, and both halves.
            XCTAssertLessThanOrEqual(drawnLines(pad), key == "\n" ? 5 : 4, "drew \(pad.styler.lastDrawn!)")
        }
        XCTAssertEqual(pad.styler.fullPromptCuts, 1, "no full cut per key")
        XCTAssertNil(pad.mismatch())
        _ = pad.styler.prompts(returns: 3)
        XCTAssertEqual(pad.styler.fullPromptCuts, 2, "another number of Returns cuts once")
    }

    // MARK: Pieces

    func testMappingARangeThroughAnEdit() {
        // Before the edit, after it, and over it.
        XCTAssertEqual(NotepadStyle.map(NSRange(location: 2, length: 3), through: NSRange(location: 10, length: 4),
                                        delta: 4, length: 100), NSRange(location: 2, length: 3))
        XCTAssertEqual(NotepadStyle.map(NSRange(location: 20, length: 3), through: NSRange(location: 10, length: 4),
                                        delta: 4, length: 100), NSRange(location: 24, length: 3))
        XCTAssertEqual(NotepadStyle.map(NSRange(location: 20, length: 3), through: NSRange(location: 10, length: 0),
                                        delta: -5, length: 100), NSRange(location: 15, length: 3))
        // Into what a deletion took: it shrinks to where the deletion was.
        XCTAssertEqual(NotepadStyle.map(NSRange(location: 12, length: 10), through: NSRange(location: 10, length: 0),
                                        delta: -5, length: 100), NSRange(location: 10, length: 7))
    }

    func testThePromptExtentEndsAtGapsOutsideCode() {
        let text = "a\nb\n\nc\nd\n\n```\nx\n\ny\n```\n\ne" as NSString
        let fences = NotepadStyle.fences(in: text, lines: NSRange(location: 0, length: text.length))
        let line = { (word: String) in text.lineRange(for: text.range(of: word)) }
        // Two Returns: a blank line is a gap.
        XCTAssertEqual(text.substring(with: NotepadStyle.promptExtent(of: line("c"), in: text, fences: fences, returns: 2)),
                       "c\nd\n")
        // A blank line inside the block is code: the block is one prompt.
        XCTAssertEqual(text.substring(with: NotepadStyle.promptExtent(of: line("y"), in: text, fences: fences, returns: 2)),
                       "```\nx\n\ny\n```\n")
        // Three Returns: one blank line is not enough, and the text has no two in a row.
        XCTAssertEqual(NotepadStyle.promptExtent(of: line("c"), in: text, fences: fences, returns: 3),
                       NSRange(location: 0, length: text.length))
        // One Return: every line is a prompt.
        XCTAssertEqual(NotepadStyle.promptExtent(of: line("c"), in: text, fences: fences, returns: 1), line("c"))
    }

    func testBlankMeansWhatTrimmingMeans() {
        for line in ["", " ", "\t", "\u{00A0}", "\u{3000}", " \u{2003}\t", " \u{301}", "x", " x ", "\u{200B}",
                     "\u{FEFF}", "😀", "\u{2028}"] {
            let ns = line as NSString
            XCTAssertEqual(NotepadStyle.isBlank(NSRange(location: 0, length: ns.length), in: ns),
                           line.trimmingCharacters(in: .whitespaces).isEmpty, Self.escaped(line))
        }
    }

    // MARK: Cost per key

    enum Styling { case original, incremental, separateRound, none }

    /// What one key costs at 16 KB and 64 KB, typed in the middle of the text and laid out after
    /// it, as the text view does: the full restyle the pad did before, the incremental one (drawn
    /// in the key's own round of editing), the same in a round of its own, and no restyle at all.
    /// Only measured — run with NOTEPAD_PERF=1; the structural tests above (what a key draws, no
    /// full cuts) guard the default suite.
    func testCostOfAKey() throws {
        try XCTSkipUnless(Self.measures, "timing only: set NOTEPAD_PERF=1")
        var report: [String] = []
        for kilobytes in [16, 64] {
            var rng = SeededGenerator(seed: 0xC0FFEE)
            var text = ""
            while (text as NSString).length < kilobytes * 1024 {
                text += Self.document(lines: 30, using: &rng).replacingOccurrences(of: "~~", with: "") + "\n\n"
            }
            let typed = Array("the quick brown fox jumps over the lazy dog, again and again ")
            /// Milliseconds per key: the edit with what is drawn inside it, the restyle after it, the layout.
            func measure(_ styling: Styling) -> (edit: Double, style: Double, layout: Double) {
                let pad = Pad(text, width: 300, returns: 2, kind: .laidOut, inline: styling == .incremental)
                pad.layout?.ensureLayout(for: pad.container!)
                var caret = (pad.storage.string as NSString).length / 2
                caret = (pad.storage.string as NSString).lineRange(for: NSRange(location: caret, length: 0)).location
                var edit: UInt64 = 0, style: UInt64 = 0, layout: UInt64 = 0
                for character in typed {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    pad.replace(NSRange(location: caret, length: 0), with: String(character))
                    caret += (String(character) as NSString).length
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    switch styling {
                    case .original:
                        OriginalRestyle.apply(to: pad.storage, width: pad.width, returns: pad.look.returns)
                        _ = NotepadCode.blocks(in: pad.storage.string).map(\.range)
                    case .incremental, .separateRound:
                        pad.styler.restyle(look: pad.look)
                        _ = pad.styler.blockRanges()
                    case .none:
                        break
                    }
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    pad.layout!.ensureLayout(for: pad.container!)
                    let t3 = DispatchTime.now().uptimeNanoseconds
                    edit += t1 - t0; style += t2 - t1; layout += t3 - t2
                }
                let keys = Double(typed.count) * 1e6
                return (Double(edit) / keys, Double(style) / keys, Double(layout) / keys)
            }
            func total(_ t: (edit: Double, style: Double, layout: Double)) -> Double { t.edit + t.style + t.layout }
            let before = measure(.original)
            let after = measure(.incremental)
            let separate = measure(.separateRound)
            let bare = measure(.none)
            // Not styling, and left as it is: the margin and the code bar cut the whole text into
            // prompts on every key (`updateRows`, `updateSuggestion`).
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<10 { _ = NotepadPrompts.prompts(in: text, returns: 2) }
            let prompts = Double(DispatchTime.now().uptimeNanoseconds - t0) / 10e6
            report.append(String(format: """
                %d KB: before %.2f ms per key (restyle %.2f, layout %.2f); \
                after %.2f ms per key (edit with its restyle %.2f, layout %.2f); \
                incremental in a round of its own %.2f ms; no restyle at all %.2f ms; \
                cutting the text into prompts, once %.2f ms
                """, kilobytes, total(before), before.style, before.layout, total(after), after.edit, after.layout,
                                 total(separate), total(bare), prompts))
        }
        print("NotepadStyle timing (one key, typed mid-text):\n  " + report.joined(separator: "\n  "))
    }

    /// What the margin and the code bar cost per key at 16 KB and 64 KB. Before, each key cut the
    /// whole text into prompts three times (the margin's rows; the code bar after the text changed
    /// and again after the insertion point moved) and looked for the blocks of the whole text twice.
    /// Now the prompts are kept with the edit and read three times. Only measured — run with
    /// NOTEPAD_PERF=1; `testTypingCutsNoPromptsAndDrawsItsLine` guards the default suite.
    func testCostOfTheMarginAndTheCodeBar() throws {
        try XCTSkipUnless(Self.measures, "timing only: set NOTEPAD_PERF=1")
        var report: [String] = []
        for kilobytes in [16, 64] {
            var rng = SeededGenerator(seed: 0xBEEF)
            var text = ""
            while (text as NSString).length < kilobytes * 1024 {
                text += Self.document(lines: 30, using: &rng) + "\n\n"
            }
            let typed = Array("the quick brown fox jumps over the lazy dog, again and again ")
            /// Milliseconds per key: the edit (with its restyle, and keeping the prompts), and what
            /// the margin and the code bar read after it.
            func measure(kept: Bool) -> (edit: Double, read: Double) {
                let pad = Pad(text, width: 300, returns: 2, kind: .appKit, keepsPrompts: kept)
                var caret = (pad.storage.string as NSString).length / 2
                caret = (pad.storage.string as NSString).lineRange(for: NSRange(location: caret, length: 0)).location
                var edit: UInt64 = 0, read: UInt64 = 0
                for character in typed {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    pad.replace(NSRange(location: caret, length: 0), with: String(character))
                    caret += 1
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    let string = pad.storage.string
                    let length = (string as NSString).length
                    var suggested = 0
                    if kept {
                        _ = pad.styler.prompts(returns: 2)                                     // the rows
                        for _ in 0..<2 {                                                        // the code bar
                            let all = pad.styler.prompts(returns: 2)
                            if let prompt = NotepadPrompts.promptValue(at: caret, among: all, length: length),
                               pad.styler.suggestion(within: prompt.range, of: string) != nil { suggested += 1 }
                        }
                    } else {
                        _ = NotepadPrompts.prompts(in: string, returns: 2)
                        for _ in 0..<2 {
                            if let prompt = NotepadPrompts.promptValue(at: caret, in: string, returns: 2),
                               NotepadCode.suggestion(within: prompt.range, of: string) != nil { suggested += 1 }
                        }
                    }
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    edit += t1 - t0; read += t2 - t1
                    XCTAssertLessThan(suggested, 3)
                }
                let keys = Double(typed.count) * 1e6
                return (Double(edit) / keys, Double(read) / keys)
            }
            let before = measure(kept: false)
            let after = measure(kept: true)
            report.append(String(format: """
                %d KB: before %.2f ms per key (edit %.2f, margin and code bar %.2f); \
                after %.2f ms per key (edit with the prompts kept %.2f, margin and code bar %.3f)
                """, kilobytes, before.edit + before.read, before.edit, before.read,
                                 after.edit + after.read, after.edit, after.read))
        }
        print("Notepad margin and code bar timing (one key, typed mid-text):\n  " + report.joined(separator: "\n  "))
    }

    /// The cases where a key used to draw much more than its line, at 64 KB: a ticked task in the
    /// prompt (one Return and three), a key inside a long struck-through prompt, and the letters of
    /// a fence's language at the top. Each key: the edit with what it draws, the margin's read of
    /// the prompts, and the layout. Only measured — run with NOTEPAD_PERF=1.
    func testCostOfKeysThatReachFar() throws {
        try XCTSkipUnless(Self.measures, "timing only: set NOTEPAD_PERF=1")
        let line = "plain words in a line of the pad, nothing more"
        func lines(_ count: Int, blankEvery: Int?) -> String {
            (0..<count).map { index in
                blankEvery.map { index > 0 && index % $0 == 0 ? "\n" : "" } ?? ""
            }.enumerated().map { $0.element + "\(line) \($0.offset)" }.joined(separator: "\n")
        }
        let size = 64 * 1024 / (line.count + 5)
        let cases: [(name: String, text: String, returns: Int, caret: (NSString) -> Int, keys: [String])] = [
            ("ticked task, two Returns, no blank line (one prompt)",
             "- [x] ticked task\n" + lines(size, blankEvery: nil), 2,
             { $0.length / 2 }, Array("typing here").map(String.init)),
            ("ticked task, three Returns, the whole pad one prompt",
             "- [x] ticked task\n" + lines(size, blankEvery: 5), 3,
             { $0.length / 2 }, Array("typing here").map(String.init)),
            ("inside a long struck-through prompt",
             "~~" + lines(size, blankEvery: nil) + "~~", 2,
             { $0.length / 2 }, Array("typing here").map(String.init)),
            ("letters of the language of an open fence at the top (```p → ```phpxy)",
             "```p\n" + lines(size, blankEvery: 3), 2,
             { _ in 4 }, ["h", "p", "x", "y"]),
        ]
        var report: [String] = []
        for scenario in cases {
            let kept = ProcessInfo.processInfo.environment["NOTEPAD_PERF_NO_PROMPTS"] == nil
            let pad = Pad(scenario.text, width: 300, returns: scenario.returns, kind: .laidOut, keepsPrompts: kept)
            pad.layout!.ensureLayout(for: pad.container!)
            var caret = scenario.caret(pad.storage.string as NSString)
            caret = (pad.storage.string as NSString).lineRange(for: NSRange(location: caret, length: 0)).location
            if scenario.keys.count == 4 { caret = 4 }
            let start = DispatchTime.now().uptimeNanoseconds
            for key in scenario.keys {
                pad.replace(NSRange(location: caret, length: 0), with: key)
                caret += (key as NSString).length
                if kept { _ = pad.styler.prompts(returns: scenario.returns) }
                pad.layout!.ensureLayout(for: pad.container!)
            }
            let perKey = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(scenario.keys.count)
            report.append(String(format: "%@: %.2f ms per key", scenario.name, perKey))
            XCTAssertNil(pad.mismatch())
        }
        print("Notepad keys that reach far (64 KB):\n  " + report.joined(separator: "\n  "))
    }

    static var measures: Bool { ProcessInfo.processInfo.environment["NOTEPAD_PERF"] != nil }
}

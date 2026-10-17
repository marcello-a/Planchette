import Foundation

/// How the notepad shows Markdown. The text is never changed: a prompt goes into the terminal as it
/// was typed, so the marks (`#`, `**`, backticks) stay in it and are only dimmed. This file finds
/// what is what and how large to draw it; the text view applies it (`Views/NotepadView.swift`).
/// Pure and unit-tested.
enum NotepadMarkdown {
    enum Style: Equatable {
        /// A headline of this level (1–6): the whole line.
        case heading(Int)
        /// The `#`s of a headline, the `>` of a quote, the fences and the marks around emphasis.
        case mark
        /// A line of a fenced code block, fences included.
        case codeBlock
        case inlineCode
        case bold
        case italic
        case quote
        /// A list item: the whole line; `prefix` is the length of its bullet or number and the
        /// space after it — what a wrapped line is indented by.
        case listItem(prefix: Int)
    }

    struct Span: Equatable {
        let range: NSRange
        let style: Style
    }

    /// Every styled stretch of the text, in the order to apply it: later spans win over earlier ones.
    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var result: [Span] = []
        var inFence = false
        var location = 0
        while location < ns.length {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            let line = contentRange(of: full, in: ns)
            let content = ns.substring(with: line)
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inFence.toggle()
                result.append(Span(range: line, style: .codeBlock))
                result.append(Span(range: line, style: .mark))
                continue
            }
            if inFence {
                if line.length > 0 { result.append(Span(range: line, style: .codeBlock)) }
                continue
            }
            guard line.length > 0 else { continue }

            if let level = headingLevel(of: content) {
                result.append(Span(range: line, style: .heading(level)))
                let marks = content.prefix { $0 == "#" }.count
                result.append(Span(range: NSRange(location: line.location, length: marks), style: .mark))
                inline(content, at: line.location, into: &result, skipping: [.bold, .italic])
            } else if let quoteMarks = quoteMarkLength(of: content) {
                result.append(Span(range: line, style: .quote))
                result.append(Span(range: NSRange(location: line.location, length: quoteMarks), style: .mark))
                inline(content, at: line.location, into: &result)
            } else {
                if let prefix = listPrefix(of: content) {
                    result.append(Span(range: line, style: .listItem(prefix: prefix.total)))
                    result.append(Span(range: NSRange(location: line.location + prefix.indent,
                                                      length: prefix.total - prefix.indent), style: .mark))
                }
                inline(content, at: line.location, into: &result)
            }
        }
        return result
    }

    /// The line without its break.
    private static func contentRange(of full: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(full)
        while end > full.location, isBreak(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: full.location, length: end - full.location)
    }

    private static func isBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }

    /// `# Title` to `###### Title`: up to three spaces, the `#`s, then a space. `#hashtag` is not one.
    static func headingLevel(of line: String) -> Int? {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return nil }
        let level = body.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = body.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return level
    }

    /// The `>` and the space after it, in UTF-16 units.
    private static func quoteMarkLength(of line: String) -> Int? {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3, body.first == ">" else { return nil }
        let extra = body.dropFirst().first == " " ? 1 : 0
        return (line.count - body.count) + 1 + extra
    }

    /// `- `, `* `, `+ `, `1. ` and `1) `, after any indent. `indent` and `total` are in UTF-16 units.
    static func listPrefix(of line: String) -> (indent: Int, total: Int)? {
        let ns = line as NSString
        var index = 0
        while index < ns.length, ns.character(at: index) == 0x20 || ns.character(at: index) == 0x09 { index += 1 }
        let indent = index
        guard index < ns.length else { return nil }
        let first = ns.character(at: index)
        if first == 0x2D || first == 0x2A || first == 0x2B {            // - * +
            index += 1
        } else if first >= 0x30 && first <= 0x39 {                       // 1. 2)
            var digits = 0
            while index < ns.length, ns.character(at: index) >= 0x30, ns.character(at: index) <= 0x39 {
                index += 1; digits += 1
            }
            guard digits <= 9, index < ns.length, ns.character(at: index) == 0x2E || ns.character(at: index) == 0x29
            else { return nil }
            index += 1
        } else {
            return nil
        }
        guard index < ns.length, ns.character(at: index) == 0x20 else { return nil }
        return (indent, index + 1)
    }

    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let bold = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italic = try! NSRegularExpression(
        pattern: "(?<![*\\w])([*_])(?=[^\\s*_])([^*_\\n]+?)(?<=[^\\s*_])\\1(?![*\\w])")

    /// Code, bold and italic inside one line. Code wins: what is in backticks is not emphasis.
    private static func inline(_ line: String, at base: Int, into result: inout [Span],
                               skipping skipped: Set<InlineKind> = []) {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        var taken: [NSRange] = []
        func free(_ range: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, range).length > 0 } }
        func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + base, length: r.length) }

        for match in code.matches(in: line, range: all) {
            taken.append(match.range)
            result.append(Span(range: shifted(match.range), style: .inlineCode))
            result.append(Span(range: shifted(NSRange(location: match.range.location, length: 1)), style: .mark))
            result.append(Span(range: shifted(NSRange(location: NSMaxRange(match.range) - 1, length: 1)), style: .mark))
        }
        for (regex, kind, style, marks) in [(bold, InlineKind.bold, Style.bold, 2), (italic, .italic, .italic, 1)]
        where !skipped.contains(kind) {
            for match in regex.matches(in: line, range: all) where free(match.range) {
                taken.append(match.range)
                result.append(Span(range: shifted(match.range), style: style))
                result.append(Span(range: shifted(NSRange(location: match.range.location, length: marks)), style: .mark))
                result.append(Span(range: shifted(NSRange(location: NSMaxRange(match.range) - marks, length: marks)),
                                   style: .mark))
            }
        }
    }

    private enum InlineKind { case bold, italic }

    // MARK: Size

    /// The body text size for a pad this wide: small where the pad is narrow, so a line still holds
    /// a few words, and a little larger where there is room, because sentences read better then.
    static let narrowWidth: Double = 220
    static let wideWidth: Double = 420

    static func bodySize(forWidth width: Double) -> Double {
        let t = min(max((width - narrowWidth) / (wideWidth - narrowWidth), 0), 1)
        return (12 + 2 * t).rounded(toNearest: 0.5)
    }

    /// How much larger a headline is than the body. Headlines are tamed in a narrow pad — a big
    /// word takes the whole line there — and grow with the room.
    static func headingScale(level: Int, forWidth width: Double) -> Double {
        let full: [Double] = [1.45, 1.3, 1.17, 1.08, 1.0, 1.0]
        let base = full[min(max(level, 1), 6) - 1]
        let t = min(max((width - narrowWidth) / (wideWidth - narrowWidth), 0), 1)
        return 1 + (base - 1) * (0.55 + 0.45 * t)
    }

    /// The space between lines of running text, which is what makes a sentence easy to follow.
    static func lineSpacing(forBodySize size: Double) -> Double { (size * 0.28).rounded() }
}

private extension Double {
    func rounded(toNearest step: Double) -> Double { (self / step).rounded() * step }
}

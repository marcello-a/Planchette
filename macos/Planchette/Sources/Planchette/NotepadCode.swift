import Foundation

/// Code in the notepad: lines that look like code and are not in a block yet (the pad offers to
/// fence them), the fenced blocks themselves (shown small and folded after two lines), and the
/// colours of what is in them. Pure and unit-tested; the text view applies it.
enum NotepadCode {
    // MARK: Lines that look like code

    enum LineKind: Equatable {
        case code
        case prose
        /// A blank line: it neither starts nor ends a stretch of code.
        case neutral
    }

    private static let codeStarts = [
        "func ", "let ", "var ", "const ", "import ", "export ", "def ", "class ", "struct ", "enum ",
        "return ", "if (", "if let ", "guard ", "for (", "while (", "switch ", "case ", "#include", "package ",
        "public ", "private ", "fn ", "impl ", "use ", "async ", "await ", "try ", "catch", "#!/",
        "SELECT ", "INSERT ", "UPDATE ", "DELETE FROM", "CREATE ", "ALTER ", "WHERE ", "FROM ", "JOIN ",
        "$ ", "//", "/*", "* ", "*/", "<!", "</", "@media", "@import",
    ]

    private static let commands: Set<String> = [
        "git", "gh", "npm", "pnpm", "yarn", "npx", "node", "brew", "swift", "xcodebuild", "docker", "kubectl",
        "make", "python", "python3", "pip", "cargo", "go", "curl", "wget", "ssh", "scp", "sudo", "export", "echo",
        "cat", "grep", "find", "sed", "awk", "rm", "mkdir", "cp", "mv", "ls", "chmod", "tar", "zip", "unzip",
        "open", "defaults", "launchctl", "bundle", "rails", "php", "composer", "terraform", "aws", "gcloud",
    ]

    private static let assignment = try! NSRegularExpression(
        pattern: "^\\s*[A-Za-z_$][\\w.$]*(\\[[^\\]]*\\])?\\s*(=|\\+=|-=|:=|\\?\\?=)\\s*\\S")
    private static let call = try! NSRegularExpression(pattern: "^\\s*[A-Za-z_$][\\w.$]*\\(.*\\)\\s*;?$")
    private static let jsonKey = try! NSRegularExpression(pattern: "^\\s*\"[^\"]+\"\\s*:")
    private static let fileLine = try! NSRegularExpression(
        pattern: "(\\.(swift|m|js|jsx|ts|tsx|vue|py|go|rb|java|kt|rs|php|c|h|cpp|cs)|\\)):\\d+(:\\d+)?\\b")
    private static let stackFrame = try! NSRegularExpression(pattern: "^\\s*(at |\\d+\\s+\\S+\\s+0x[0-9a-f]+)")
    private static let tag = try! NSRegularExpression(pattern: "^\\s*<[A-Za-z!/][^>]*>")

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Whether one line reads as code or as words.
    static func kind(of line: String) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .neutral }
        // Markdown structure is prose here: a list, a headline, a quote is written, not code.
        if NotepadMarkdown.headingLevel(of: line) != nil || trimmed.hasPrefix("> ") { return .prose }
        if let prefix = NotepadMarkdown.listPrefix(of: line), prefix.indent == 0, !trimmed.hasPrefix("* ") {
            return .prose
        }
        if ["}", "{", "]", ")", "};", "});", "})", "],", "},", "end", "fi", "done", "esac"].contains(trimmed) {
            return .code
        }
        if codeStarts.contains(where: trimmed.hasPrefix) { return .code }
        if let last = trimmed.last, ";{[(".contains(last) { return .code }
        if trimmed.hasSuffix("=>") || trimmed.hasSuffix("->") || trimmed.hasSuffix("\\") { return .code }
        if matches(assignment, line) || matches(call, line) || matches(jsonKey, line)
            || matches(stackFrame, line) || matches(fileLine, line) || matches(tag, line) {
            return .code
        }
        let words = trimmed.split(separator: " ")
        if let first = words.first, commands.contains(String(first)), words.count >= 2,
           !(trimmed.last.map { ".?!".contains($0) } ?? false) {
            return .code
        }
        // Many symbols and few words: code; a sentence has the opposite.
        let symbols = trimmed.filter { "{}[]();=<>|&*/\\$\"`:#%^~+".contains($0) }.count
        let letters = trimmed.filter(\.isLetter).count
        let density = Double(symbols) / Double(max(trimmed.count, 1))
        if density >= 0.2, letters < trimmed.count * 3 / 4 { return .code }
        if line.hasPrefix("    ") || line.hasPrefix("\t"), density >= 0.08 { return .code }
        return .prose
    }

    /// A stretch of lines that looks like code and is not in a block: the pad offers to fence it.
    struct Suggestion: Equatable {
        /// From the start of its first line to the end of its last line, breaks inside.
        let range: NSRange
        let language: String?
        let lineCount: Int
    }

    /// At least this many lines of code make a stretch worth a block: one line is a command you
    /// send, not code you show.
    static let minimumLines = 2

    /// The first stretch of code in `range` (a prompt): lines of code, with blank lines between
    /// them but no line of words, outside any fence. Nil when there is none.
    static func suggestion(within range: NSRange, of text: String) -> Suggestion? {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        let fenced = fencedLineStarts(in: ns)
        var run: [NSRange] = []
        var codeLines = 0
        func finish() -> Suggestion? {
            while let last = run.last, kind(of: ns.substring(with: last)) == .neutral { run.removeLast() }
            guard codeLines >= minimumLines, let first = run.first, let last = run.last else { return nil }
            let lines = run.map { ns.substring(with: $0) }
            return Suggestion(range: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
                              language: language(of: lines), lineCount: run.count)
        }
        var location = range.location
        while location < NSMaxRange(range) {
            let line = contentRange(of: ns.lineRange(for: NSRange(location: location, length: 0)), in: ns)
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            let lineKind: LineKind = fenced.contains(line.location) ? .prose : kind(of: ns.substring(with: line))
            switch lineKind {
            case .code:
                run.append(line); codeLines += 1
            case .neutral:
                if !run.isEmpty { run.append(line) }
            case .prose:
                if let found = finish() { return found }
                run = []; codeLines = 0
            }
        }
        return finish()
    }

    /// The text with the stretch put between fences.
    static func fence(_ suggestion: Suggestion, in text: String) -> NotepadEditing.Change {
        let ns = text as NSString
        let body = ns.substring(with: suggestion.range)
        let open = "```" + (suggestion.language ?? "") + "\n"
        let replacement = open + body + "\n```"
        return NotepadEditing.Change(range: suggestion.range, replacement: replacement,
                                     caret: suggestion.range.location + (replacement as NSString).length)
    }

    // MARK: Language

    /// The language a stretch of code is most likely in, for the fence and the colours. Nil when
    /// nothing points anywhere.
    static func language(of lines: [String]) -> String? {
        let text = lines.joined(separator: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        func count(_ needles: [String]) -> Int { needles.reduce(0) { $0 + (text.contains($1) ? 1 : 0) } }
        func starts(_ prefixes: [String]) -> Int {
            trimmed.reduce(0) { total, line in total + (prefixes.contains(where: line.hasPrefix) ? 1 : 0) }
        }
        if let first = trimmed.first(where: { !$0.isEmpty }), first.hasPrefix("{") || first.hasPrefix("["),
           lines.contains(where: { matches(jsonKey, $0) }) {
            return "json"
        }
        let shell = trimmed.filter { line in
            line.hasPrefix("$ ") || line.split(separator: " ").first.map { commands.contains(String($0)) } ?? false
        }.count
        let scores: [(String, Int)] = [
            ("swift", count(["func ", "guard ", "import SwiftUI", "import Foundation", "import AppKit", "@State",
                             "@Published", "?? ", "-> ", "struct ", "extension ", "let ", "var "])
                + starts(["@MainActor", "private func", "case ."]) * 2),
            ("typescript", count(["const ", "=> ", "function ", "===", "!==", "export ", "interface ", ": string",
                                  ": number", "console.", "import {", "let "])),
            ("python", count(["def ", "elif ", "self.", "None", "True", "False", "print(", "lambda ", "    return"])
                + starts(["import ", "from "]) - count(["{", ";"])),
            ("go", count(["package ", "func (", ":= ", "fmt.", "err != nil", "go func"]) * 2),
            ("rust", count(["fn ", "let mut ", "impl ", "pub fn", "::new(", "&mut ", "match "]) * 2 - count(["func "])),
            ("sql", count(["SELECT ", "FROM ", "WHERE ", "JOIN ", "GROUP BY", "ORDER BY", "INSERT INTO", "UPDATE "]) * 2),
            ("html", trimmed.filter { matches(tag, $0) }.count * 2),
            ("bash", shell * 2 + count(["#!/bin", "fi\n", "then", "$(", "echo "])),
        ]
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 >= 2 else { return nil }
        return best.0
    }

    /// How a language is written for people: `typescript` → TypeScript.
    static func displayName(of language: String) -> String {
        let names = ["swift": "Swift", "typescript": "TypeScript", "python": "Python", "go": "Go", "rust": "Rust",
                     "sql": "SQL", "html": "HTML", "json": "JSON", "bash": "Bash"]
        return names[aliases[language] ?? language] ?? language.capitalized
    }

    // MARK: Blocks

    /// A fenced block, as it stands in the text.
    struct Block: Equatable {
        /// The opening fence line, without its break.
        let open: NSRange
        /// The closing fence line; nil while the block is still open (it runs to the end).
        let close: NSRange?
        /// What the fence names: `swift` in ```` ```swift ````. Nil without a name.
        let language: String?
        /// The lines between the fences, without their breaks.
        let lines: [NSRange]

        /// From the first character of the opening fence to the end of the closing one.
        var range: NSRange {
            let end = NSMaxRange(close ?? lines.last ?? open)
            return NSRange(location: open.location, length: end - open.location)
        }
    }

    static func blocks(in text: String) -> [Block] {
        let ns = text as NSString
        var result: [Block] = []
        var open: (range: NSRange, language: String?)?
        var lines: [NSRange] = []
        var location = 0
        while location < ns.length {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            let line = contentRange(of: full, in: ns)
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let current = open {
                    result.append(Block(open: current.range, close: line, language: current.language, lines: lines))
                    open = nil
                } else {
                    let name = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                    open = (line, name.isEmpty ? nil : name)
                    lines = []
                }
            } else if open != nil {
                lines.append(line)
            }
        }
        if let current = open {
            // No closing fence: a block that is still being written runs to the end.
            result.append(Block(open: current.range, close: nil, language: current.language, lines: lines))
        }
        return result
    }

    /// The lines of code a folded block still shows.
    static let visibleLines = 2

    /// What a folded block hides: everything from the end of its second line to the end of its
    /// last one, so the closing fence stays as the row that says how much more there is. Nil for
    /// a block with nothing to hide, and for one still open — that one is being written.
    static func foldedRange(of block: Block) -> NSRange? {
        guard block.close != nil, block.lines.count > visibleLines, let last = block.lines.last else { return nil }
        let start = NSMaxRange(block.lines[visibleLines - 1])
        return NSRange(location: start, length: NSMaxRange(last) - start)
    }

    /// The number of lines a folded block hides.
    static func hiddenLineCount(of block: Block) -> Int { max(block.lines.count - visibleLines, 0) }

    // MARK: Colours

    enum Token: Equatable {
        case keyword, string, comment, number, type
    }

    private static let keywords: [String: Set<String>] = [
        "swift": ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch",
                  "for", "in", "while", "import", "extension", "protocol", "private", "fileprivate", "public",
                  "internal", "static", "self", "Self", "nil", "true", "false", "try", "await", "async", "throws",
                  "throw", "do", "catch", "init", "deinit", "where", "some", "any", "mutating", "override", "final",
                  "weak", "lazy", "defer", "break", "continue", "default", "inout", "is", "as", "nonisolated"],
        "typescript": ["const", "let", "var", "function", "return", "if", "else", "for", "while", "import", "from",
                       "export", "default", "class", "extends", "new", "this", "null", "undefined", "true", "false",
                       "async", "await", "try", "catch", "throw", "typeof", "instanceof", "interface", "type",
                       "switch", "case", "break", "continue", "of", "in", "as", "public", "private", "readonly"],
        "python": ["def", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "class",
                   "self", "None", "True", "False", "try", "except", "finally", "raise", "with", "lambda", "yield",
                   "and", "or", "not", "is", "pass", "break", "continue", "async", "await", "global"],
        "go": ["func", "package", "import", "return", "if", "else", "for", "range", "var", "const", "type", "struct",
               "interface", "map", "chan", "go", "defer", "nil", "true", "false", "switch", "case", "default"],
        "rust": ["fn", "let", "mut", "pub", "impl", "struct", "enum", "trait", "use", "mod", "match", "if", "else",
                 "for", "in", "while", "loop", "return", "self", "Self", "true", "false", "as", "ref", "move"],
        "sql": ["select", "from", "where", "join", "left", "right", "inner", "outer", "on", "group", "by", "order",
                "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "and", "or",
                "not", "null", "as", "limit", "having", "distinct", "count", "union", "with", "case", "when", "then",
                "else", "end", "is", "in", "like"],
        "bash": ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                 "return", "export", "local", "echo", "exit", "set", "unset", "source"],
    ]

    private static let aliases: [String: String] = [
        "ts": "typescript", "js": "typescript", "javascript": "typescript", "tsx": "typescript", "jsx": "typescript",
        "vue": "typescript", "py": "python", "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
        "rs": "rust", "golang": "go",
    ]

    /// The keywords of a language; without one, those of the common ones together.
    private static func keywordSet(for language: String?) -> Set<String> {
        let name = language.map { aliases[$0] ?? $0 }
        if let name, let set = keywords[name] { return set }
        return keywords["swift"]!.union(keywords["typescript"]!).union(keywords["python"]!)
    }

    private static func usesHashComments(_ language: String?) -> Bool {
        let name = language.map { aliases[$0] ?? $0 }
        return ["python", "bash", "ruby", "yaml", "yml", "toml"].contains(name ?? "")
    }

    private static let word = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
    private static let numberPattern = try! NSRegularExpression(pattern: "\\b(0x[0-9a-fA-F]+|\\d+(\\.\\d+)?)\\b")

    /// The coloured stretches of one line of code, in UTF-16 units of the line.
    static func tokens(in line: String, language: String?) -> [(range: NSRange, token: Token)] {
        let ns = line as NSString
        var result: [(NSRange, Token)] = []
        var plain: [NSRange] = []
        let hash = usesHashComments(language)
        let sql = (language.map { aliases[$0] ?? $0 }) == "sql"
        var index = 0
        var segmentStart = 0
        func flushPlain(until end: Int) {
            if end > segmentStart { plain.append(NSRange(location: segmentStart, length: end - segmentStart)) }
        }
        while index < ns.length {
            let c = ns.character(at: index)
            let next = index + 1 < ns.length ? ns.character(at: index + 1) : 0
            let lineComment = (c == 0x2F && next == 0x2F)                      // //
                || (hash && c == 0x23)                                         // #
                || (sql && c == 0x2D && next == 0x2D)                          // --
                || (!hash && c == 0x23 && ns.substring(to: index).trimmingCharacters(in: .whitespaces).isEmpty
                    && language == nil)
            if lineComment {
                flushPlain(until: index)
                result.append((NSRange(location: index, length: ns.length - index), .comment))
                segmentStart = ns.length
                index = ns.length
                break
            }
            if c == 0x22 || c == 0x27 || c == 0x60 {                          // " ' `
                // An apostrophe inside a word ("don't") is not a string.
                if c == 0x27, index > 0, let scalar = Unicode.Scalar(ns.character(at: index - 1)),
                   CharacterSet.letters.contains(scalar) {
                    index += 1; continue
                }
                flushPlain(until: index)
                var end = index + 1
                while end < ns.length, ns.character(at: end) != c {
                    if ns.character(at: end) == 0x5C { end += 1 }              // \" inside
                    end += 1
                }
                end = min(end + 1, ns.length)
                result.append((NSRange(location: index, length: end - index), .string))
                index = end
                segmentStart = end
                continue
            }
            index += 1
        }
        flushPlain(until: ns.length)
        let words = keywordSet(for: language)
        for segment in plain {
            for match in word.matches(in: line, range: segment) {
                let text = ns.substring(with: match.range)
                if words.contains(sql ? text.lowercased() : text) {
                    result.append((match.range, .keyword))
                } else if let first = text.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
                          text.count > 1, !sql {
                    result.append((match.range, .type))
                }
            }
            for match in numberPattern.matches(in: line, range: segment) {
                result.append((match.range, .number))
            }
        }
        return result.sorted { $0.0.location < $1.0.location }
    }

    // MARK: Lines

    private static func contentRange(of full: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(full)
        while end > full.location, isBreak(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: full.location, length: end - full.location)
    }

    private static func isBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }

    /// Where the lines inside fences (and the fences) start: they are code already.
    private static func fencedLineStarts(in ns: NSString) -> Set<Int> {
        var result: Set<Int> = []
        for block in blocks(in: ns as String) {
            result.insert(block.open.location)
            block.lines.forEach { result.insert($0.location) }
            if let close = block.close { result.insert(close.location) }
        }
        return result
    }
}

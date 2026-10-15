import Foundation

/// "What's new" for the update dialog, read off a release body that is a slice
/// of CHANGELOG.md (see scripts/release.sh).
///
/// Every entry is a point the dialog lists by its *title*; clicking a point opens
/// its whole text. The two lengths are different on purpose: a changelog entry
/// explains itself over five lines, which is the right length to read once you
/// care and the wrong length to scan inside a modal deciding whether to restart.
/// So the list is complete, every point starts closed, and the list scrolls
/// inside a fixed height — twelve entries must never push the buttons off a
/// small screen.
///
/// Pure and unit-tested, because it parses text we do not control at runtime.
enum ReleaseNotes {
    /// One point of the list.
    struct Entry: Identifiable, Equatable {
        let id: Int
        /// The `###` heading it sits under in the changelog (`Added`, `Fixed`…).
        let section: String?
        /// The headline: the bold lead-in, or the first sentence.
        let title: String
        /// The entry's text without its headline, markdown stripped and the lines
        /// joined. Empty when the entry is nothing but a headline.
        let detail: String
    }

    /// The top-level bullets of `body`, in order, with the heading each sits under.
    static func entries(from body: String) -> [Entry] {
        var entries: [Entry] = []
        var section: String?
        var current: (section: String?, lines: [String])?

        func finish() {
            guard let open = current else { return }
            current = nil
            guard let made = makeEntry(id: entries.count, section: open.section, lines: open.lines) else { return }
            entries.append(made)
        }

        for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("#") {
                finish()
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                // `###` names a kind of change; a `##` is the release itself.
                section = line.hasPrefix("###") && !heading.isEmpty ? heading : nil
            } else if isBullet(line), line.first != " ", line.first != "\t" {
                finish()
                current = (section, [line])
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            } else if line.first == " " || line.first == "\t" {
                // Indented: the rest of the bullet above, or a detail bullet of it.
                current?.lines.append(line)
            } else {
                // Unindented text that is no bullet ends the one above.
                finish()
            }
        }
        finish()
        return entries
    }

    private static func isBullet(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
    }

    private static func makeEntry(id: Int, section: String?, lines: [String]) -> Entry? {
        guard let first = lines.first, let title = title(ofBullet: first) else { return nil }

        // The text after the marker, in reading order. A nested bullet keeps its own
        // line, so a list inside an entry stays a list.
        var paragraph = String(first.trimmingCharacters(in: .whitespaces).dropFirst(2))
        var tail: [String] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isBullet(trimmed) {
                tail.append("• " + trimmed.dropFirst(2))
            } else if tail.isEmpty {
                paragraph += " " + trimmed
            } else {
                tail[tail.count - 1] += " " + trimmed
            }
        }

        // With a bold lead-in the headline is not repeated in the text; without
        // one the headline is only the first sentence cut short, so the text is all of it.
        var body = paragraph
        if paragraph.hasPrefix("**"),
           let close = paragraph.range(of: "**", range: paragraph.index(paragraph.startIndex, offsetBy: 2)..<paragraph.endIndex) {
            body = String(paragraph[close.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " —–-:"))
        }
        let detail = ([body] + tail)
            .map { unbold(plain($0)).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return Entry(id: id, section: section, title: title, detail: detail)
    }

    /// The headline of one bullet: the bold lead-in when there is one, otherwise
    /// the first sentence. `- **Terminals name themselves.** A tab is now …`
    /// becomes `Terminals name themselves`.
    static func title(ofBullet line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = String(text.dropFirst(2))          // "- " / "* "
        text = plain(text)

        if let bold = boldLeadIn(text) {
            text = bold
        } else if let stop = text.firstIndex(where: { $0 == "." || $0 == ":" }) {
            text = String(text[text.startIndex..<stop])
        } else if let dash = text.range(of: " — ") {
            text = String(text[text.startIndex..<dash.lowerBound])
        }

        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:—-"))
        guard !collapsed.isEmpty else { return nil }
        return Titles.clip(collapsed, max: 64)
    }

    /// The text inside a leading `**…**`, ignoring a trailing period inside the
    /// bold run (the changelog writes `**Title.**`).
    private static func boldLeadIn(_ text: String) -> String? {
        guard text.hasPrefix("**") else { return nil }
        let afterOpen = text.index(text.startIndex, offsetBy: 2)
        guard let close = text.range(of: "**", range: afterOpen..<text.endIndex) else { return nil }
        return String(text[afterOpen..<close.lowerBound])
    }

    /// Strip the markdown that would otherwise be read out as punctuation:
    /// inline code and links (keep the text). Bold markers stay: the title is found by
    /// them (`boldLeadIn`), and `unbold` removes the rest where text is shown.
    private static func plain(_ text: String) -> String {
        let out = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return out.replacingOccurrences(of: "`", with: "")
    }

    private static func unbold(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }
}

import Foundation

/// "What's new" for the update dialog, read off a release body that is a slice
/// of CHANGELOG.md (see scripts/release.sh).
///
/// Only the *titles* of the entries: a changelog entry explains itself over five
/// lines, which is the right length to read afterwards and the wrong length to
/// read inside a modal deciding whether to restart. And the list is cut short —
/// an update with twelve entries would push the buttons off a small screen, and
/// nobody reads the twelfth line of a dialog anyway.
///
/// Pure and unit-tested, because it parses text we do not control at runtime.
enum ReleaseNotes {
    /// Titles of the top-level bullets in `body`, at most `limit` of them, plus
    /// how many were left out.
    static func highlights(from body: String, limit: Int = 5) -> (items: [String], more: Int) {
        let bullets = body
            .split(whereSeparator: \.isNewline)
            .filter { line in
                // Top level only: an indented bullet is a detail of the one
                // above it, not an entry of its own.
                guard line.first != " ", line.first != "\t" else { return false }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
            }
            .compactMap { title(ofBullet: String($0)) }
        guard !bullets.isEmpty else { return ([], 0) }
        return (Array(bullets.prefix(limit)), max(0, bullets.count - limit))
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
    /// inline code, links (keep the text), and stray emphasis markers.
    private static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "`", with: "")
        return out
    }
}

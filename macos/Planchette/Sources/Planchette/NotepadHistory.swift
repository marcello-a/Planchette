import Foundation

/// One thing that left a notepad: a prompt that went into the terminal, text that was deleted, or
/// the whole pad as it was before "Format with AI". The pad's menu shows the last ones, newest
/// first, to put back or copy. Saved with the terminal (`TerminalSession.notepadHistory`).
struct NotepadHistoryEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case sent, deleted, formatted
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var text: String

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
    }

    // An entry a newer build wrote in a way this one does not know is dropped (`NotepadHistory.Lenient`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
    }
}

enum NotepadHistory {
    /// How many entries a pad keeps.
    static let limit = 100
    /// A longer text is kept cut to this many characters: the history is for prompts and lines,
    /// and it is written with the workspace.
    static let maximumLength = 8000

    /// The list with `entry` in front. Nothing is added for empty text or for the same text the
    /// newest entry already holds (a prompt sent twice in a row).
    static func adding(_ entry: NotepadHistoryEntry, to list: [NotepadHistoryEntry]) -> [NotepadHistoryEntry] {
        var entry = entry
        entry.text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.text.isEmpty else { return list }
        if entry.text.count > maximumLength { entry.text = String(entry.text.prefix(maximumLength)) }
        if let newest = list.first, newest.text == entry.text, newest.kind == entry.kind { return list }
        return Array(([entry] + list).prefix(limit))
    }

    /// One entry of a saved state, or nothing when it cannot be read: a bad entry costs itself,
    /// not the terminal it belongs to.
    struct Lenient: Decodable {
        let entry: NotepadHistoryEntry?
        init(from decoder: Decoder) throws { entry = try? NotepadHistoryEntry(from: decoder) }
    }

    /// The entries that could be read, at most `limit`; nil when none could.
    static func readable(_ items: [Lenient]?) -> [NotepadHistoryEntry]? {
        let entries = (items ?? []).compactMap(\.entry)
        return entries.isEmpty ? nil : Array(entries.prefix(limit))
    }

    // MARK: What a deletion is worth

    /// Fewer characters than this, and not a whole line: a typo fixed, not something deleted.
    static let minimumLength = 20

    /// What is worth keeping of text that was removed: a whole line, more than one line, or a
    /// longer stretch. Nil for a few characters out of a line, and for blanks.
    ///
    /// - Parameter lineIsLeftBlank: the line the text was on is blank now — it went entirely.
    static func worthKeeping(_ removed: String, lineIsLeftBlank: Bool) -> String? {
        let trimmed = removed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let manyLines = trimmed.contains { $0.isNewline }
        guard manyLines || lineIsLeftBlank || trimmed.count >= minimumLength else { return nil }
        return trimmed
    }

    /// Characters deleted one key at a time, gathered into one stretch: Backspace after Backspace
    /// grows it at the front, Delete after Delete at the back. It is weighed once the run ends.
    struct Run: Equatable {
        /// Where the stretch was, in the text as it is now (it is gone, so its length is zero).
        var location: Int
        var text: String

        /// The run with one more deletion of `removed` at `range`, or nil when that deletion is
        /// somewhere else and starts a run of its own.
        func adding(_ removed: String, at range: NSRange) -> Run? {
            if NSMaxRange(range) == location { return Run(location: range.location, text: removed + text) }
            if range.location == location { return Run(location: location, text: text + removed) }
            return nil
        }
    }
}

import Foundation

/// Everything the search knows about one terminal, as plain values — so how it
/// ranks is a pure function and is tested, not eyeballed.
struct SearchEntry: Equatable {
    let id: UUID
    var title = ""
    var project = ""
    var branch = ""
    /// The working directory in full.
    var path = ""
    var tags: [String] = []
    var note = ""
    /// The first line of the last prompt sent here.
    var task = ""
    var summary = ""
    /// The last question or error.
    var message = ""
    var pullRequest: Int?
    var pullRequestTitle = ""
    /// The titles of what Claude runs in the background of this terminal.
    var background: [String] = []
    /// 0 for a calm terminal, higher for an error or a question, higher still in a
    /// favorite project — what the empty search sorts by, and a nudge when two
    /// matches are close.
    var urgency = 0
    var stateSince = Date.distantPast
}

/// A place in a terminal's description a search can match.
enum SearchField: CaseIterable, Hashable {
    case title, project, branch, tag, pullRequest, pullRequestTitle, path, note, task, summary, message, background

    /// How much a match here is worth, in tenths: a word in the name counts three
    /// times what the same word in a summary does.
    var weight: Int {
        switch self {
        case .title: 30
        case .project: 20
        case .pullRequest: 20
        case .pullRequestTitle: 12
        case .branch: 18
        case .tag: 18
        case .note: 14
        case .path: 12
        case .task: 10
        case .background: 8
        case .summary: 8
        case .message: 8
        }
    }

    /// The SF Symbol that says where a match was found, when it was somewhere the
    /// row does not already show.
    var symbol: String {
        switch self {
        case .title: "textformat"
        case .project: "folder"
        case .branch: "arrow.triangle.branch"
        case .tag: "tag"
        case .pullRequest, .pullRequestTitle: "arrow.triangle.pull"
        case .path: "folder"
        case .note: "note.text"
        case .task: "text.bubble"
        case .background: "terminal"
        case .summary: "sparkles"
        case .message: "questionmark.bubble"
        }
    }
}

/// How a terminal answers a search: its score, and where in each field the
/// words were found (character offsets, for highlighting).
struct SearchHit: Equatable {
    let id: UUID
    let score: Int
    let matches: [SearchField: [Range<Int>]]
    /// The field to show a snippet of — the best match that the row itself does not
    /// show (title and path are always on it). Nil when what matched is visible.
    let hint: SearchField?
}

/// Finding a terminal by what you remember about it.
///
/// A query is words; **every word has to be found**, in any field. A word is
/// found in the best of five ways, and the way sets its worth: as a whole word
/// (`menu` in "gallery wall menu"), as the start of one (`gal`), inside one
/// (`allery`), as the initials of consecutive words (`gwm`), or as letters in order
/// that stay close together (`gllry`). Anything looser is not a match: the old
/// search let `abc` match letters scattered over the title, the path and the
/// summary joined into one line, and found whatever it liked.
enum SearchRanking {
    // MARK: Folding

    /// One character, lowercase and without accents — and always one character, so
    /// an offset in the folded text is an offset in the original (a highlight).
    static func fold(_ character: Character) -> Character {
        let lowered = character.lowercased()
        let stripped = lowered.decomposedStringWithCanonicalMapping.unicodeScalars.first.map { Character($0) }
        return stripped ?? character
    }

    static func fold(_ text: String) -> [Character] { text.map(fold) }

    /// The words of a query, folded; a leading `#` (a pull request number) goes.
    static func words(of query: String) -> [[Character]] {
        query.split(whereSeparator: \.isWhitespace).compactMap { part in
            let folded = fold(String(part))
            let trimmed = folded.first == "#" && folded.count > 1 ? Array(folded.dropFirst()) : folded
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Words of a field

    /// Where each word of a text starts and ends: a run of letters or digits,
    /// split again at a lowercase→uppercase step and between letters and digits
    /// ("room-view-2", "roomView2" are both room · view · 2).
    static func wordRanges(in text: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in text.indices {
            let character = text[index]
            let isWordCharacter = character.isLetter || character.isNumber
            if !isWordCharacter {
                if let s = start { ranges.append(s..<index); start = nil }
                continue
            }
            if let s = start {
                let previous = text[index - 1]
                let camel = previous.isLowercase && character.isUppercase
                let switchesKind = previous.isNumber != character.isNumber
                if camel || switchesKind {
                    ranges.append(s..<index)
                    start = index
                }
            } else {
                start = index
            }
        }
        if let s = start { ranges.append(s..<text.count) }
        return ranges
    }

    // MARK: One word in one field

    enum Way: Int {
        case subsequence = 20
        case acronym = 40
        case inside = 50
        case start = 80
        case whole = 100
    }

    struct Found: Equatable {
        let way: Way
        let ranges: [Range<Int>]
    }

    /// The best way `word` is in `text`, if it is. `original` is only used for
    /// word boundaries (camelCase needs the case that folding removes).
    static func find(_ word: [Character], in original: String) -> Found? {
        let text = Array(original)
        let folded = fold(original)
        guard !word.isEmpty, folded.count >= word.count else { return nil }
        let words = wordRanges(in: text)

        // 1. A whole word, 2. the start of one.
        var prefix: Range<Int>?
        for range in words where range.count >= word.count {
            if Array(folded[range.lowerBound..<(range.lowerBound + word.count)]) == word {
                if range.count == word.count { return Found(way: .whole, ranges: [range]) }
                if prefix == nil { prefix = range.lowerBound..<(range.lowerBound + word.count) }
            }
        }
        if let prefix { return Found(way: .start, ranges: [prefix]) }

        // 3. Inside a word — or across one separator ("wall-menu", "feat/gal").
        if let at = firstIndex(of: word, in: folded) {
            return Found(way: .inside, ranges: [at..<(at + word.count)])
        }

        // 4. The initials of consecutive words.
        if word.count >= 2, words.count >= word.count {
            let initials = words.map { folded[$0.lowerBound] }
            if let at = firstIndex(of: word, in: initials) {
                let ranges = (at..<(at + word.count)).map { words[$0].lowerBound..<(words[$0].lowerBound + 1) }
                return Found(way: .acronym, ranges: ranges)
            }
        }

        // 5. Letters in order that stay close: the whole match may not be longer than
        // twice the word. Looser than that is any text at all.
        if word.count >= 3 {
            var positions: [Int] = []
            var from = 0
            for character in word {
                guard let at = folded[from...].firstIndex(of: character) else { return nil }
                positions.append(at)
                from = at + 1
            }
            if let first = positions.first, let last = positions.last, last - first + 1 <= word.count * 2 {
                return Found(way: .subsequence, ranges: positions.map { $0..<($0 + 1) })
            }
        }
        return nil
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start] == needle[0] && Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    // MARK: A terminal

    /// What the fields of an entry are, as (field, text) pairs.
    private static func fields(of entry: SearchEntry) -> [(SearchField, String)] {
        var result: [(SearchField, String)] = [
            (.title, entry.title), (.project, entry.project), (.branch, entry.branch),
            (.path, entry.path), (.note, entry.note), (.task, entry.task),
            (.summary, entry.summary), (.message, entry.message),
            (.pullRequestTitle, entry.pullRequestTitle),
        ].compactMap { pair in pair.1.isEmpty ? nil : pair }
        // Tags and background tasks are one text each: the ranges of a hit then point into
        // the same string the row can show.
        if !entry.tags.isEmpty { result.append((.tag, entry.tags.joined(separator: " · "))) }
        if !entry.background.isEmpty { result.append((.background, entry.background.joined(separator: " · "))) }
        if let number = entry.pullRequest { result.append((.pullRequest, String(number))) }
        return result
    }

    /// The text of a field as the search matched it — what a snippet shows.
    static func text(of field: SearchField, in entry: SearchEntry) -> String {
        fields(of: entry).first { $0.0 == field }?.1 ?? ""
    }

    /// Ranges moved by `offset` and cut to `0..<length`: the part of a longer text
    /// that is shown (the last two folders of a path), with its highlights.
    static func shifted(_ ranges: [Range<Int>], by offset: Int, within length: Int) -> [Range<Int>] {
        ranges.compactMap { range in
            let lower = max(0, range.lowerBound + offset)
            let upper = min(length, range.upperBound + offset)
            return lower < upper ? lower..<upper : nil
        }
    }

    /// The score of one entry for a query, or nil when a word is not found in it.
    static func hit(for words: [[Character]], in entry: SearchEntry) -> SearchHit? {
        guard !words.isEmpty else { return nil }
        let fields = Self.fields(of: entry)
        var total = 0
        var matches: [SearchField: [Range<Int>]] = [:]
        // For each word that is found only where the row shows nothing of it, the
        // best such field: the snippet that answers "why is this here?".
        var hidden: [(field: SearchField, worth: Int)] = []
        for word in words {
            var best = 0
            var foundOnTheRow = false
            var bestHidden: (field: SearchField, worth: Int)?
            for (field, text) in fields {
                guard let found = find(word, in: text) else { continue }
                // A pull request is found by its number as a whole or from its start,
                // never from the inside of it ("57" is not in #5576 by accident).
                if field == .pullRequest, found.way.rawValue < Way.start.rawValue { continue }
                let worth = found.way.rawValue * field.weight / 10
                    + (found.ranges.first?.lowerBound == 0 ? 8 : 0)
                best = max(best, worth)
                matches[field, default: []] += found.ranges
                if field.isOnTheRow {
                    foundOnTheRow = true
                } else if worth > (bestHidden?.worth ?? 0) {
                    bestHidden = (field, worth)
                }
            }
            guard best > 0 else { return nil }
            total += best
            if !foundOnTheRow, let bestHidden { hidden.append(bestHidden) }
        }
        // Urgency and a favorite break a close call; they never beat a better word.
        total += min(entry.urgency, 6) * 4
        return SearchHit(
            id: entry.id, score: total, matches: matches.mapValues(merged),
            hint: hidden.max(by: { $0.worth < $1.worth })?.field)
    }

    /// Overlapping and touching ranges as one, in order.
    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: The list

    /// Best first. Ties go to the more urgent terminal, then the more recent.
    static func rank(_ query: String, in entries: [SearchEntry]) -> [SearchHit] {
        let words = words(of: query)
        guard !words.isEmpty else { return idle(entries) }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return entries.compactMap { hit(for: words, in: $0) }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let (ea, eb) = (byID[a.id]!, byID[b.id]!)
            if ea.urgency != eb.urgency { return ea.urgency > eb.urgency }
            return ea.stateSince > eb.stateSince
        }
    }

    /// With nothing typed: the terminals that need you first, then the newest.
    static func idle(_ entries: [SearchEntry], limit: Int = 12) -> [SearchHit] {
        entries.sorted { a, b in
            if a.urgency != b.urgency { return a.urgency > b.urgency }
            return a.stateSince > b.stateSince
        }
        .prefix(limit)
        .map { SearchHit(id: $0.id, score: 0, matches: [:], hint: nil) }
    }
}

extension SearchField {
    /// Whether the search row shows this field anyway — the name, the folder, the
    /// project at its edge, the tag chips and the summary line — so a snippet of it
    /// would say nothing new. The rest (branch, pull request, note, prompt, what runs
    /// in the background, the last question) is where a snippet earns its line.
    var isOnTheRow: Bool {
        switch self {
        case .title, .path, .project, .tag, .summary: true
        default: false
        }
    }
}

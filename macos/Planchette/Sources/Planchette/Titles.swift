import Foundation

enum Titles {
    /// Extract a ticket id (e.g. NIE-4213) from the git branch of a directory.
    /// Reads .git/HEAD directly — no subprocess, cheap enough to call from UI.
    static func ticket(forDirectory dir: String) -> String? {
        guard let branch = gitBranch(forDirectory: dir) else { return nil }
        return ticket(inBranch: branch)
    }

    /// The ticket key inside a branch name (`marcello/feat/NIE-123-x` → `NIE-123`).
    static func ticket(inBranch branch: String) -> String? {
        guard let range = branch.range(of: #"[A-Z]{2,10}-\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(branch[range])
    }

    /// A branch from its ticket on: `marcello/feat/NIE-1902-format-switch` →
    /// `NIE-1902-format-switch`. Everything before the ticket is the same lead-in
    /// on every branch one person creates — it costs the width a row does not
    /// have and says nothing. A branch without a ticket is returned unchanged:
    /// there is no meaningful place to cut it.
    static func branchFromTicket(_ branch: String) -> String {
        guard let range = branch.range(of: #"[A-Z]{2,10}-\d+"#, options: .regularExpression) else {
            return branch
        }
        return String(branch[range.lowerBound...])
    }

    static func gitBranch(forDirectory dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        // Walk up to find the repo root (max 10 levels).
        for _ in 0..<10 {
            let head = url.appendingPathComponent(".git/HEAD")
            if let content = try? String(contentsOf: head, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") {
                    return String(trimmed.dropFirst("ref: refs/heads/".count))
                }
                return nil // detached HEAD
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    /// Last two path components: "…/development/sandbox/planchette" → "sandbox/planchette".
    static func shortPath(_ path: String) -> String {
        let parts = (path as NSString).pathComponents.filter { $0 != "/" }
        return parts.suffix(2).joined(separator: "/")
    }

    static func shorten(_ title: String, max: Int = 24) -> String {
        title.count <= max ? title : String(title.prefix(max - 1)) + "…"
    }

    /// Shorten to `max` at a word boundary rather than mid-word — "Add the
    /// format sw…" reads as damage, "Add the format…" reads as a name. Trailing
    /// punctuation goes with the cut.
    static func clip(_ text: String, max: Int) -> String {
        guard text.count > max else { return trimmedTail(text) }
        var cut = String(text.prefix(max))
        // Drop the partial last word, unless that would leave almost nothing —
        // a single very long word is better shown cut than reduced to "…".
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > max / 3 {
            cut = String(cut[cut.startIndex..<space])
        }
        return trimmedTail(cut) + "…"
    }

    /// A prompt condensed to something that fits a sidebar row.
    static func taskLabel(_ task: String, max: Int = 32) -> String? {
        let collapsed = task
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        return clip(collapsed, max: max)
    }

    private static func trimmedTail(_ text: String) -> String {
        var out = text
        while let last = out.last, last.isPunctuation || last.isWhitespace, last != ")" {
            out.removeLast()
        }
        return out.isEmpty ? text : out
    }

    /// The name a terminal gives itself: the ticket it belongs to and what it is
    /// working on. Both halves are optional — a repo without a ticket branch has
    /// only the work, a terminal that was never given a task has only the
    /// ticket, and with neither there is nothing to auto-name it after.
    ///
    /// The ticket stays in the name even though the row shows the path: two
    /// terminals in the same worktree must not read the same, and the work alone
    /// loses which checkout it belongs to when the sidebar is narrow.
    static func autoTitle(ticket: String?, work: String?) -> String? {
        switch (ticket, work) {
        case let (.some(ticket), .some(work)): "\(ticket) · \(work)"
        case let (.some(ticket), .none): ticket
        case let (.none, .some(work)): work
        case (.none, .none): nil
        }
    }

    /// True if a title is just the shell's default prompt (`user@host:~/path`),
    /// which isn't a useful name — an idle terminal showing this is "free".
    static func looksLikeShellPrompt(_ title: String) -> Bool {
        title.range(of: #"^\S+@\S+[:~/]"#, options: .regularExpression) != nil
    }
}

import Foundation

enum Titles {
    /// Extract a ticket id (e.g. NIE-4213) from the git branch of a directory.
    /// Reads .git/HEAD directly — no subprocess, cheap enough to call from UI.
    static func ticket(forDirectory dir: String) -> String? {
        guard let branch = gitBranch(forDirectory: dir) else { return nil }
        guard let range = branch.range(of: #"[A-Z]{2,10}-\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(branch[range])
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

    /// True if a title is just the shell's default prompt (`user@host:~/path`),
    /// which isn't a useful name — an idle terminal showing this is "free".
    static func looksLikeShellPrompt(_ title: String) -> Bool {
        title.range(of: #"^\S+@\S+[:~/]"#, options: .regularExpression) != nil
    }
}

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

    /// Memoized branch lookups. `displayTitle`/`ticket` are evaluated in view
    /// bodies and sort comparators, so without this every AppState publish ran
    /// up to 10 filesystem probes per session, on the main thread — and the
    /// control API's title sort ran them O(n log n) times per request. A short
    /// TTL keeps a `git checkout` done behind the app's back visible within
    /// seconds (the sidebar's own branch poll runs at 10s anyway).
    private static var branchCache: [String: (branch: String?, at: Date)] = [:]
    private static let branchCacheLock = NSLock()
    private static let branchCacheTTL: TimeInterval = 5

    static func gitBranch(forDirectory dir: String) -> String? {
        branchCacheLock.lock()
        if let hit = branchCache[dir], Date().timeIntervalSince(hit.at) < branchCacheTTL {
            branchCacheLock.unlock()
            return hit.branch
        }
        branchCacheLock.unlock()
        let branch = readGitBranch(forDirectory: dir)
        branchCacheLock.lock()
        branchCache[dir] = (branch, Date())
        // The keys are the directories of live terminals — a handful — but a
        // long-lived app must not collect every directory it ever saw.
        if branchCache.count > 512 { branchCache = [:] }
        branchCacheLock.unlock()
        return branch
    }

    /// Drop the remembered branches. Called when the branch poll saw a change:
    /// it publishes, the views redraw, and a name read from a cache entry made
    /// before the checkout would still show the old ticket — and keep it until
    /// something else redraws.
    static func forgetBranches() {
        branchCacheLock.lock()
        branchCache = [:]
        branchCacheLock.unlock()
    }

    private static func readGitBranch(forDirectory dir: String) -> String? {
        if case .branch(let name) = headState(forDirectory: dir) { return name }
        return nil
    }

    /// What the `HEAD` file of the repository around a directory says.
    enum HeadState: Equatable {
        case branch(String)
        /// A repository, but HEAD names a commit (or a ref outside `refs/heads`):
        /// there is no branch, which is also what `git branch --show-current`
        /// prints.
        case detached
        /// No repository above this directory.
        case notARepository
        /// HEAD holds a placeholder, so only git itself can answer. The reftable
        /// ref format keeps `HEAD` as the stub `ref: refs/heads/.invalid`.
        case unknown
    }

    /// Read HEAD straight off disk — no subprocess. The sidebar's branch poll used
    /// to spawn `git branch --show-current` per distinct directory every 10
    /// seconds, around the clock and with the app in the background; a file read
    /// answers the same question in microseconds.
    ///
    /// `maxLevels` bounds the walk up from `dir` to the repository root. The
    /// title code keeps its historical 10; the branch poll asks for more so that
    /// a deep package directory is still recognised as part of its repository
    /// (git itself has no limit).
    static func headState(forDirectory dir: String, maxLevels: Int = 10) -> HeadState {
        // The PHYSICAL path, as git sees it: a terminal reports the logical one, and
        // walking up a symlink's own name goes through its parent's directory, not
        // the real parent's. `~/code -> /Volumes/work/code` with the terminal in
        // `~/code/app` would otherwise climb `~/code` -> `~`, miss the repository
        // and — worse — find an unrelated one on the way (a dotfiles repo in `~`).
        var url = URL(fileURLWithPath: physicalPath(of: dir))
        for _ in 0..<max(1, maxLevels) {
            let dotGit = url.appendingPathComponent(".git")
            if let gitDir = resolveGitDir(dotGit) {
                let head = gitDir.appendingPathComponent("HEAD")
                if let content = try? String(contentsOf: head, encoding: .utf8) {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("ref: refs/heads/") {
                        let name = String(trimmed.dropFirst("ref: refs/heads/".count))
                        return name == ".invalid" ? .unknown : .branch(name)
                    }
                    return .detached
                }
                return .unknown   // a git dir whose HEAD cannot be read: let git say
            }
            // A `.git` that is there but is no usable git dir (a worktree whose
            // gitdir was deleted): git stops here with an error rather than
            // climbing into the repository around it, and so must we.
            if FileManager.default.fileExists(atPath: dotGit.path) { return .unknown }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return .notARepository
    }

    /// `realpath(3)`: every symlink resolved, `/tmp` and `/var` included (which
    /// Foundation's `resolvingSymlinksInPath` leaves alone). A path that does not
    /// exist is returned as it came.
    private static func physicalPath(of path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : path
    }

    /// The directory that actually holds `HEAD` for the repo whose `.git` entry
    /// is `dotGit`. Usually that is `.git` itself, but in a linked git worktree
    /// `.git` is a FILE reading `gitdir: <path>` that points at the per-worktree
    /// git directory. Without this, a worktree terminal reads no HEAD and the
    /// walk climbs into a parent repo — showing a wrong branch or none.
    private static func resolveGitDir(_ dotGit: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else {
            return nil
        }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return dotGit.deletingLastPathComponent()
            .appendingPathComponent(path).standardizedFileURL
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

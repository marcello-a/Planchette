import Foundation

/// Git worktrees as first-class projects. Working on several branches of one
/// repo at once is the normal way to run several agents on it, and without this
/// each checkout looks like an unrelated folder that happens to share a name.
///
/// Everything here is pure or a plain subprocess call, so it can be tested and
/// must be called off the main thread (see AGENTS.md rule 5).
enum Worktrees {
    // MARK: Pure helpers

    /// Directory name for a branch: one path segment, no slashes, no spaces.
    /// `marcello/feat/NIE-123-x` → `marcello-feat-NIE-123-x`.
    static func slug(forBranch branch: String) -> String {
        let collapsed = branch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let allowed = collapsed.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        // Punctuation alone is not a name: "///" would collapse to "---".
        guard allowed.contains(where: { $0.isLetter || $0.isNumber }) else { return "worktree" }
        return String(allowed.prefix(64))
    }

    /// Where a new worktree for `branch` goes: a sibling of the repo, so nothing
    /// ever appears inside the repository itself (no .gitignore surprises, no
    /// tool walking into a nested checkout).
    ///
    /// `~/dev/planchette` + `feat/x` → `~/dev/planchette.worktrees/feat-x`
    ///
    /// This is where the checkout is *asked* to go. What gets stored is the path
    /// git reports back (see `create`): Foundation cannot canonicalize `/tmp` or
    /// `/var` on macOS, and only git's own form is comparable with
    /// `git worktree list`.
    static func defaultPath(repoRoot: String, branch: String) -> String {
        let root = URL(fileURLWithPath: repoRoot).standardizedFileURL
        let siblings = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent).worktrees", isDirectory: true)
        return siblings.appendingPathComponent(slug(forBranch: branch), isDirectory: true).path
    }

    /// A display name for a worktree group: the branch, with the ticket pulled
    /// out when there is one (same convention as terminal titles).
    static func groupName(repoName: String, branch: String) -> String {
        let short = Titles.ticket(inBranch: branch) ?? branch
        return "\(repoName) · \(short)"
    }

    // MARK: Git

    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Run git in `directory`, returning trimmed stdout. Throws with git's own
    /// stderr, which is the only useful message when a worktree op fails.
    @discardableResult
    static func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: message?.isEmpty == false ? message! : "git \(arguments.first ?? "") failed")
        }
        return String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The main checkout for a directory, or nil when it isn't in a git repo.
    /// Deliberately `--show-toplevel` on the *common* dir so calling this from
    /// inside a worktree still yields that worktree's root.
    static func repoRoot(of directory: String) -> String? {
        guard let root = try? git(["rev-parse", "--show-toplevel"], in: directory),
              !root.isEmpty
        else { return nil }
        return root
    }

    /// The checked-out branch of a directory, or nil outside a repo / on a
    /// detached HEAD (`--show-current` prints nothing there — no branch is the
    /// honest answer, and a bare sha in the sidebar would only look like noise).
    static func currentBranch(of directory: String) -> String? {
        guard let branch = try? git(["branch", "--show-current"], in: directory),
              !branch.isEmpty
        else { return nil }
        return branch
    }

    /// Create a worktree for `branch`, creating the branch off `base` when it
    /// doesn't exist yet, and return the checkout path.
    static func create(repoRoot: String, branch: String, base: String?) throws -> String {
        let path = defaultPath(repoRoot: repoRoot, branch: branch)
        if FileManager.default.fileExists(atPath: path) {
            throw GitError(message: "\(path) already exists")
        }
        let branchExists = (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
                                    in: repoRoot)) != nil
        var args = ["worktree", "add"]
        if branchExists {
            args += [path, branch]
        } else {
            args += ["-b", branch, path]
            if let base, !base.isEmpty { args.append(base) }
        }
        try git(args, in: repoRoot)
        // Ask git where the checkout actually landed. On macOS /tmp and /var are
        // symlinks that Foundation refuses to resolve, so a hand-built path can
        // differ from the one git reports — and then nothing we store would ever
        // match `git worktree list`.
        // `Self.` because the `repoRoot` parameter shadows the function.
        return Self.repoRoot(of: path) ?? path
    }

    /// Remove a worktree checkout. Without `force` git refuses while there are
    /// uncommitted changes — that refusal *is* the guard, so it is surfaced to
    /// the user rather than worked around.
    static func remove(path: String, repoRoot: String, force: Bool = false) throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        try git(args, in: repoRoot)
    }

    /// Paths of every worktree of a repo (the main checkout included).
    static func list(repoRoot: String) -> [String] {
        guard let out = try? git(["worktree", "list", "--porcelain"], in: repoRoot) else { return [] }
        return parseWorktreeList(out)
    }

    /// Pure: pull the paths out of `git worktree list --porcelain`.
    static func parseWorktreeList(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }
}

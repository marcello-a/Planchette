import Foundation
import os

// One `gh api graphql` call for the PRs of every checkout of a sweep, instead of one
// `gh pr list` process per checkout and branch. With ~30 terminals the per-checkout
// processes cost about 3.5 % of a core.
//
// The danger is the repository: `gh pr list` picks the base repository from the git
// remotes of the folder it runs in, and the batch has to name that repository itself.
// A wrong pick shows the wrong PR, so `GhRepoResolver` names one only where `gh`'s own
// rule gives a single answer it can see from the files — and every other checkout is
// asked the old way, with `gh pr list` in its folder (`RepoResolution.uncertain`).

/// A repository on github.com, as `gh` names it.
struct GitHubRepo: Hashable {
    let owner: String
    let name: String
}

// MARK: - git's config files

/// A git config file, read the way git reads it: sections (`[remote "origin"]`, the old
/// `[remote.origin]`), keys, quoted values with escapes, comments and continued lines.
/// Only what the resolver needs is kept, and anything git itself would refuse makes the
/// whole file unreadable (`parse` answers nil) — a guess there could name a wrong repo.
struct GitConfigFile: Equatable {
    struct Entry: Equatable {
        /// Lowercased, as git compares it.
        let section: String
        /// As written in quotes (case-sensitive), lowercased in the old dotted form.
        let subsection: String?
        /// Lowercased.
        let key: String
        /// Nil for a key without `=`, which git reads as `true`.
        let value: String?
    }

    var entries: [Entry]

    /// The files this one includes (`include.path`, `includeIf.<condition>.path`).
    var includePaths: [String] {
        entries.compactMap { entry in
            guard entry.section == "include" || entry.section == "includeif",
                  entry.key == "path" else { return nil }
            return entry.value
        }
    }

    /// The values of `section.subsection.key`, in file order.
    func values(section: String, subsection: String?, key: String) -> [String?] {
        entries.filter { $0.section == section && $0.subsection == subsection && $0.key == key }
            .map(\.value)
    }

    /// Pure. Nil when git would refuse the file too (a bad line, an unclosed quote).
    static func parse(_ text: String) -> GitConfigFile? {
        var parser = Parser(Array(text.unicodeScalars))
        return parser.run().map { GitConfigFile(entries: $0) }
    }

    private struct Parser {
        let chars: [Unicode.Scalar]
        var index = 0
        var section: String?
        var subsection: String?
        var entries: [Entry] = []

        init(_ chars: [Unicode.Scalar]) {
            self.chars = chars
            if chars.first == "\u{FEFF}" { index = 1 }
        }

        var current: Unicode.Scalar? { index < chars.count ? chars[index] : nil }

        static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\r" }
        static func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        /// git's `iskeychar`: ASCII letters, digits and `-`.
        static func isKeyChar(_ c: Unicode.Scalar) -> Bool { isLetter(c) || ("0"..."9").contains(c) || c == "-" }

        mutating func skipToLineEnd() {
            while let c = current, c != "\n" { index += 1 }
        }

        mutating func run() -> [Entry]? {
            while let c = current {
                if c == "\n" || Self.isSpace(c) { index += 1; continue }
                if c == "#" || c == ";" { skipToLineEnd(); continue }
                if c == "[" {
                    guard readSectionHeader() else { return nil }
                    continue
                }
                // git also takes a key before any section (it then has none).
                guard Self.isLetter(c), readEntry() else { return nil }
            }
            return entries
        }

        /// `[name]`, `[name "sub"]` or the old `[name.sub]`.
        mutating func readSectionHeader() -> Bool {
            index += 1   // "["
            var name = ""
            while let c = current, Self.isKeyChar(c) || c == "." {
                name.unicodeScalars.append(c)
                index += 1
            }
            guard !name.isEmpty else { return false }
            if current == "]" {
                index += 1
                if let dot = name.firstIndex(of: ".") {
                    // The old form: the whole name is lowercased, the subsection with it.
                    let head = name[..<dot].lowercased(), tail = name[name.index(after: dot)...].lowercased()
                    guard !head.isEmpty, !tail.isEmpty else { return false }
                    section = head
                    subsection = tail
                    return true
                }
                section = name.lowercased()
                subsection = nil
                return true
            }
            guard !name.contains(".") else { return false }
            while let c = current, Self.isSpace(c) { index += 1 }
            guard current == "\"" else { return false }
            index += 1
            var sub = ""
            while true {
                guard let c = current, c != "\n" else { return false }
                index += 1
                if c == "\"" { break }
                if c == "\\" {
                    guard let next = current, next != "\n" else { return false }
                    sub.unicodeScalars.append(next)
                    index += 1
                } else {
                    sub.unicodeScalars.append(c)
                }
            }
            guard current == "]" else { return false }
            index += 1
            section = name.lowercased()
            subsection = sub
            return true
        }

        /// `key`, `key = value`, up to the end of the (possibly continued) line.
        mutating func readEntry() -> Bool {
            var key = ""
            while let c = current, Self.isKeyChar(c) {
                key.unicodeScalars.append(c)
                index += 1
            }
            while let c = current, Self.isSpace(c) { index += 1 }
            var value: String?
            switch current {
            case nil, "\n":
                value = nil   // a bare key is true; a comment right after one is an error to git
            case "=":
                index += 1
                guard let read = readValue() else { return false }
                value = read
            default:
                return false
            }
            entries.append(Entry(section: section ?? "", subsection: subsection,
                                 key: key.lowercased(), value: value))
            return true
        }

        /// A value as git's `parse_value` reads it: leading blanks dropped, trailing blanks
        /// outside quotes dropped, `"` toggles quoting, `\` escapes, `\` + newline continues.
        mutating func readValue() -> String? {
            var out = ""
            var quoted = false
            var pendingSpace = ""
            var started = false
            while let c = current {
                if c == "\n" {
                    guard !quoted else { return nil }
                    break
                }
                index += 1
                if !quoted && (c == "#" || c == ";") {
                    skipToLineEnd()
                    break
                }
                if !quoted && Self.isSpace(c) {
                    if started { pendingSpace += " " }   // git writes every blank as a space
                    continue
                }
                out += pendingSpace
                pendingSpace = ""
                started = true
                if c == "\\" {
                    guard let next = current else { break }   // git reads the end as a newline
                    index += 1
                    switch next {
                    case "\n": continue
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "b": out += "\u{8}"
                    case "\\", "\"": out.unicodeScalars.append(next)
                    default: return nil
                    }
                    continue
                }
                if c == "\"" {
                    quoted.toggle()
                    continue
                }
                out.unicodeScalars.append(c)
            }
            guard !quoted else { return nil }
            return out
        }
    }
}

/// A remote as `git remote -v` and `gh` see it.
struct GitRemote: Equatable {
    let name: String
    var urls: [String] = []
    var pushURLs: [String] = []
    /// `remote.<name>.gh-resolved`, written by `gh repo set-default`: `base`, or the
    /// `owner/repo` that is the base whatever the remote says.
    var ghResolved: String?

    /// The remotes of these files (read in order, the later ones adding to the earlier),
    /// in the order they first appear.
    static func all(in files: [GitConfigFile]) -> [GitRemote] {
        var byName: [String: GitRemote] = [:]
        var order: [String] = []
        for entry in files.flatMap(\.entries) where entry.section == "remote" {
            guard let name = entry.subsection else { continue }
            if byName[name] == nil {
                byName[name] = GitRemote(name: name)
                order.append(name)
            }
            switch entry.key {
            case "url": byName[name]?.urls.append(entry.value ?? "")
            case "pushurl": byName[name]?.pushURLs.append(entry.value ?? "")
            // `gh` reads every value and keeps the last.
            case "gh-resolved": byName[name]?.ghResolved = entry.value ?? ""
            default: break
            }
        }
        return order.compactMap { byName[$0] }
    }
}

// MARK: - Which repository `gh pr list` asks

/// Which repository `gh pr list` would ask in a checkout — or why that is not certain.
enum RepoResolution: Equatable {
    case github(GitHubRepo)
    /// Look this checkout up alone, with `gh pr list` in its folder. The text says why,
    /// for the debug log.
    case uncertain(String)
}

/// `gh`'s choice of the base repository, rebuilt from the files (cli/cli
/// `pkg/cmd/factory/remote_resolver.go`, `context.ResolvedRemotes.BaseRepo`, and
/// `git.ParseURL`; checked against gh 2.106 with `GH_DEBUG=api`):
///
/// 1. The remotes come from `git remote -v`; a URL with no host (a local path) is dropped,
///    and so are remotes on a host `gh` has no login for.
/// 2. They are sorted `upstream`, `github`, `origin`, then the rest (in no fixed order).
/// 3. The first remote with `gh-resolved` wins: `base` names that remote's repository,
///    `owner/repo` names that repository.
/// 4. Otherwise, since the app's `gh` cannot prompt, the first remote.
///
/// Only github.com is batched; another host, an SSH host alias (`gh` asks `ssh -G` what it
/// stands for), a rewritten URL (`url.<base>.insteadOf`), two remotes that tie in step 2
/// or 3 and name different repositories, and anything this cannot read all answer
/// `uncertain`, and that checkout keeps its own `gh pr list`.
enum GhRepoResolver {
    /// What a remote URL says, read as `gh` reads it.
    enum RemoteURL: Equatable {
        case github(GitHubRepo)
        /// No host: `gh` drops the remote.
        case localPath
        /// Another host, or an SSH alias.
        case otherHost(String)
        /// A form this does not read with certainty.
        case unknown
    }

    private static let schemes: Set<String> = ["https", "http", "ssh", "git", "git+ssh", "git+https"]
    /// `gh` reads these prefixes as a protocol even without `//` (`isPossibleProtocol`).
    private static let protocolPrefixes = ["ssh:", "git+ssh:", "git:", "http:", "git+https:", "https:",
                                           "ftp:", "ftps:", "file:"]

    /// Pure.
    static func classify(_ raw: String) -> RemoteURL {
        let url = raw.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return .unknown }
        // A path (`/…`, or no `:` at all) has no host for gh, whatever else it holds.
        if url.hasPrefix("/") || !url.contains(":") { return .localPath }
        guard !url.contains(where: { $0.isWhitespace || $0 == "%" || $0 == "?" || $0 == "#" }) else { return .unknown }
        let host: String
        let path: String
        if let schemeEnd = url.range(of: "://") {
            let scheme = String(url[..<schemeEnd.lowerBound])
            let rest = url[schemeEnd.upperBound...]
            if scheme == "file" { return rest.hasPrefix("/") ? .localPath : .unknown }
            guard schemes.contains(scheme), let slash = rest.firstIndex(of: "/") else { return .unknown }
            var authority = String(rest[..<slash])
            path = String(rest[slash...])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            guard !authority.contains("[") else { return .unknown }
            if let colon = authority.firstIndex(of: ":") {
                let port = authority[authority.index(after: colon)...]
                guard port.allSatisfy(\.isASCII) && port.allSatisfy(\.isNumber) else { return .unknown }
                authority = String(authority[..<colon])
            }
            host = authority
        } else if url.contains(":") {
            // scp-like `git@github.com:owner/repo.git`.
            guard !protocolPrefixes.contains(where: url.hasPrefix), !url.contains("\\"),
                  let colon = url.firstIndex(of: ":") else { return .unknown }
            let hostPart = url[..<colon]
            guard !hostPart.contains("/"), !hostPart.contains("[") else { return .unknown }
            host = hostPart.lastIndex(of: "@").map { String(hostPart[hostPart.index(after: $0)...]) }
                ?? String(hostPart)
            path = String(url[url.index(after: colon)...])
        } else {
            return .localPath
        }
        let lowered = host.lowercased()
        guard !lowered.isEmpty else { return .unknown }
        // `ghinstance.NormalizeHostname`: `www.github.com`, `ssh.github.com` are github.com.
        guard lowered == "github.com" || lowered.hasSuffix(".github.com") else { return .otherHost(lowered) }
        let parts = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return .unknown }
        var name = String(parts[1])
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !name.isEmpty else { return .unknown }
        return .github(GitHubRepo(owner: String(parts[0]), name: name))
    }

    /// `gh`'s sort key: higher first.
    static func priority(ofRemote name: String) -> Int {
        switch name.lowercased() {
        case "upstream": return 3
        case "github": return 2
        case "origin": return 1
        default: return 0
        }
    }

    /// Pure: the repository `gh pr list` asks, from a checkout's remotes and the URL
    /// prefixes some config rewrites (`insteadOf`, `pushInsteadOf`).
    static func resolve(remotes: [GitRemote], rewrites: [String]) -> RepoResolution {
        var candidates: [(remote: GitRemote, repo: GitHubRepo)] = []
        for remote in remotes {
            // `git remote -v` shows a remote only with a URL; one without has nothing for gh.
            if remote.urls.isEmpty && remote.pushURLs.isEmpty { continue }
            guard remote.urls.count == 1, remote.pushURLs.count <= 1 else {
                return .uncertain("remote \(remote.name) has several URLs")
            }
            if (remote.urls + remote.pushURLs).contains(where: { url in rewrites.contains { url.hasPrefix($0) } }) {
                return .uncertain("remote \(remote.name) is rewritten by insteadOf")
            }
            switch classify(remote.urls[0]) {
            case .github(let repo):
                candidates.append((remote, repo))
            case .localPath:
                // `gh` tries the push URL next; only a remote without one is plainly dropped.
                guard remote.pushURLs.isEmpty else { return .uncertain("remote \(remote.name) pushes elsewhere") }
            case .otherHost(let host):
                return .uncertain("remote \(remote.name) is on \(host)")
            case .unknown:
                return .uncertain("remote \(remote.name) has an unreadable URL")
            }
        }
        guard !candidates.isEmpty else { return .uncertain("no github.com remote") }

        let resolved = candidates.filter { !($0.remote.ghResolved ?? "").isEmpty }
        if !resolved.isEmpty {
            let top = resolved.map { priority(ofRemote: $0.remote.name) }.max() ?? 0
            var picks = Set<GitHubRepo>()
            for candidate in resolved where priority(ofRemote: candidate.remote.name) == top {
                let value = candidate.remote.ghResolved ?? ""
                if value == "base" {
                    picks.insert(candidate.repo)
                } else if let repo = fullName(value) {
                    picks.insert(repo)
                } else {
                    return .uncertain("gh-resolved \(value) is not owner/repo")
                }
            }
            guard picks.count == 1, let pick = picks.first else {
                return .uncertain("several remotes carry gh-resolved")
            }
            return .github(pick)
        }

        let top = candidates.map { priority(ofRemote: $0.remote.name) }.max() ?? 0
        let picks = Set(candidates.filter { priority(ofRemote: $0.remote.name) == top }.map(\.repo))
        guard picks.count == 1, let pick = picks.first else {
            return .uncertain("several remotes and no gh repo set-default")
        }
        return .github(pick)
    }

    /// `owner/repo`, nothing else (a `host/owner/repo` is left to `gh`).
    static func fullName(_ value: String) -> GitHubRepo? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) })
        else { return nil }
        return GitHubRepo(owner: String(parts[0]), name: String(parts[1]))
    }

    // MARK: Environment

    /// Variables that change what `gh` or `git` reads: `GH_REPO` and `GH_HOST` override
    /// the repository and host, the `GIT_*` ones move or add config files. With any of
    /// them set in the app, every checkout is looked up alone.
    static let fallbackEnvironment = [
        "GH_REPO", "GH_HOST", "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_CONFIG",
        "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
    ]

    /// Pure: why the environment rules out the batch, or nil.
    static func environmentBlocker(_ environment: [String: String]) -> String? {
        fallbackEnvironment.first { !(environment[$0] ?? "").isEmpty }.map { "\($0) is set" }
    }

    // MARK: Files

    /// What the config outside the repository says that matters here. Read as a superset:
    /// every included file counts, whatever its `includeIf` condition, because a prefix
    /// too many only costs a fallback.
    struct OuterRules: Equatable {
        /// URL prefixes some `url.<base>.insteadOf` or `pushInsteadOf` rewrites.
        var rewrites: [String] = []
        /// A `[remote ...]` section outside the repository: `git remote -v` would list it
        /// in every checkout.
        var definesRemote = false
    }

    /// The config files git reads outside a repository: system (Apple's, Homebrew's,
    /// MacPorts'), XDG and `~/.gitconfig`. A path that does not exist is skipped.
    static func outerConfigPaths(environment: [String: String], home: String) -> [String] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return [
            "/etc/gitconfig",
            "/opt/homebrew/etc/gitconfig",
            "/usr/local/etc/gitconfig",
            "/opt/local/etc/gitconfig",
            "/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig",
            "/Applications/Xcode.app/Contents/Developer/usr/share/git-core/gitconfig",
            xdg + "/git/config",
            home + "/.gitconfig",
        ]
    }

    /// The rules of these files and everything they include. Nil when one of them is
    /// there but cannot be read as git config: git (and `gh`) would fail there too.
    static func outerRules(
        paths: [String], home: String, read: (String) -> String? = StatCachedText.read
    ) -> OuterRules? {
        var rules = OuterRules()
        var seen = Set<String>()
        func visit(_ path: String, depth: Int) -> Bool {
            guard depth < 10, seen.insert(path).inserted, let text = read(path) else { return true }
            guard let file = GitConfigFile.parse(text) else { return false }
            rules.rewrites += rewritePrefixes(in: file)
            if file.entries.contains(where: { $0.section == "remote" }) { rules.definesRemote = true }
            let folder = (path as NSString).deletingLastPathComponent
            for include in file.includePaths {
                guard visit(expand(include, home: home, relativeTo: folder), depth: depth + 1) else { return false }
            }
            return true
        }
        for path in paths {
            guard visit(path, depth: 0) else { return nil }
        }
        return rules
    }

    static func rewritePrefixes(in file: GitConfigFile) -> [String] {
        file.entries.compactMap { entry in
            guard entry.section == "url", entry.key == "insteadof" || entry.key == "pushinsteadof" else { return nil }
            return entry.value ?? ""
        }
    }

    /// An include path as git expands it: `~/` is the home folder, a relative path is
    /// relative to the file that includes it.
    static func expand(_ path: String, home: String, relativeTo folder: String) -> String {
        if path.hasPrefix("~/") { return home + "/" + path.dropFirst(2) }
        if path.hasPrefix("/") { return path }
        return (folder as NSString).appendingPathComponent(path)
    }

    /// Where a checkout's git files are: its own git dir (`.git`, or the one a worktree's
    /// or submodule's `.git` file points at) and the common dir that holds `config` (a
    /// linked worktree names it in its `commondir` file).
    struct GitDirs: Equatable {
        let gitDir: String
        let commonDir: String
    }

    static func gitDirs(
        checkoutRoot root: String,
        read: (String) -> String? = StatCachedText.read,
        isDirectory: (String) -> Bool? = GhRepoResolver.isDirectory
    ) -> GitDirs? {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        let gitDir: String
        switch isDirectory(dotGit) {
        case true?:
            gitDir = dotGit
        case false?:
            guard let text = read(dotGit) else { return nil }
            let line = text.split(separator: "\n").first.map(String.init) ?? ""
            guard line.hasPrefix("gitdir:") else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            gitDir = absolute(target, relativeTo: root)
        case nil:
            return nil
        }
        let commonFile = (gitDir as NSString).appendingPathComponent("commondir")
        if let text = read(commonFile) {
            let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            return GitDirs(gitDir: gitDir, commonDir: absolute(target, relativeTo: gitDir))
        }
        return GitDirs(gitDir: gitDir, commonDir: gitDir)
    }

    private static func absolute(_ path: String, relativeTo folder: String) -> String {
        let joined = path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
        return (joined as NSString).standardizingPath
    }

    static func isDirectory(_ path: String) -> Bool? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue
    }

    /// The repository `gh pr list` asks in the checkout at `root` (nil: no checkout).
    static func resolve(
        checkoutRoot root: String?, outer: OuterRules?,
        read: (String) -> String? = StatCachedText.read,
        isDirectory: (String) -> Bool? = GhRepoResolver.isDirectory
    ) -> RepoResolution {
        guard let outer else { return .uncertain("a global git config is unreadable") }
        guard !outer.definesRemote else { return .uncertain("a global git config defines a remote") }
        guard let root else { return .uncertain("not in a checkout") }
        guard let dirs = gitDirs(checkoutRoot: root, read: read, isDirectory: isDirectory) else {
            return .uncertain("no usable .git")
        }
        guard let text = read((dirs.commonDir as NSString).appendingPathComponent("config")) else {
            return .uncertain("no readable config")
        }
        guard let config = GitConfigFile.parse(text) else { return .uncertain("config is unreadable") }
        var files = [config]
        let worktreeConfig = config.values(section: "extensions", subsection: nil, key: "worktreeconfig").last ?? nil
        if let flag = worktreeConfig?.lowercased(), ["true", "yes", "on", "1"].contains(flag),
           let text = read((dirs.gitDir as NSString).appendingPathComponent("config.worktree")) {
            guard let file = GitConfigFile.parse(text) else { return .uncertain("config.worktree is unreadable") }
            files.append(file)
        }
        // An include may hold a remote or a gh-resolved only under a condition this does
        // not evaluate: such a config is left to gh.
        guard files.allSatisfy({ $0.includePaths.isEmpty }) else { return .uncertain("config includes other files") }
        return resolve(remotes: GitRemote.all(in: files),
                       rewrites: outer.rewrites + files.flatMap(rewritePrefixes(in:)))
    }
}

// MARK: - The query and its answer

enum PullRequestBatch {
    /// One checkout's question: a branch's PRs in a repository.
    struct Request: Hashable {
        let repo: GitHubRepo
        let branch: String
    }

    /// The most checkouts in one call. Each alias is one small connection (5 nodes), far
    /// under GraphQL's limits; the cap keeps one slow answer from holding a big sweep and
    /// one bad alias from costing many lookups.
    static let cap = 20

    /// The node fields, the same as `gh pr list --json` is asked for, so one parse reads both.
    static var nodeFields: String { PullRequests.jsonFields.replacingOccurrences(of: ",", with: " ") }

    static func alias(_ index: Int) -> String { "r\(index)" }

    /// Pure. Every value goes in as a variable: an owner, name or branch is never written
    /// into the query text, so no quote, backslash or brace in a branch name can change it.
    static func query(count: Int) -> String {
        let parameters = (0..<count).map { "$o\($0): String!, $n\($0): String!, $b\($0): String!" }
        let fields = (0..<count).map { index in
            "\(alias(index)): repository(owner: $o\(index), name: $n\(index)) { "
                + "pullRequests(headRefName: $b\(index), first: \(PullRequests.lookupLimit), "
                + "states: [OPEN, MERGED, CLOSED], orderBy: {field: CREATED_AT, direction: DESC}) "
                + "{ nodes { \(nodeFields) } } }"
        }
        return "query PlanchettePullRequests(\(parameters.joined(separator: ", "))) {\n  "
            + fields.joined(separator: "\n  ") + "\n}"
    }

    static func variables(for requests: [Request]) -> [String: String] {
        var variables: [String: String] = [:]
        for (index, request) in requests.enumerated() {
            variables["o\(index)"] = request.repo.owner
            variables["n\(index)"] = request.repo.name
            variables["b\(index)"] = request.branch
        }
        return variables
    }

    /// The request body for `gh api graphql --input -`. Pure.
    static func body(for requests: [Request]) -> Data {
        let object: [String: Any] = ["query": query(count: requests.count), "variables": variables(for: requests)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Pure: the answer to a call of `count` aliases. An alias that GitHub answered gives
    /// `found` or `none`, picked as `PullRequests.parse` picks; an alias named by an error
    /// (a repository that is gone, or not visible to this login), null, or not shaped as
    /// asked is left out — that checkout is looked up alone. Nil when the answer as a whole
    /// is not understood: no `data`, or an error that names no alias.
    static func parse(_ data: Data, count: Int) -> [Int: PullRequests.Lookup]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = root["data"] as? [String: Any] else { return nil }
        var failed = Set<String>()
        if let errors = root["errors"], !(errors is NSNull) {
            guard let list = errors as? [Any] else { return nil }
            for item in list {
                guard let error = item as? [String: Any], let path = error["path"] as? [Any],
                      let first = path.first as? String else { return nil }
                failed.insert(first)
            }
        }
        var lookups: [Int: PullRequests.Lookup] = [:]
        for index in 0..<count {
            let name = alias(index)
            guard !failed.contains(name), let repository = answer[name] as? [String: Any],
                  let pullRequests = repository["pullRequests"] as? [String: Any],
                  let nodes = pullRequests["nodes"] as? [Any] else { continue }
            let items = nodes.compactMap { $0 as? [String: Any] }
            lookups[index] = PullRequests.choose(items).map(PullRequests.Lookup.found) ?? PullRequests.Lookup.none
        }
        return lookups
    }

    /// What became of one call.
    enum Outcome: Equatable {
        /// GitHub answered. An index left out is looked up alone.
        case answered([Int: PullRequests.Lookup])
        /// `gh` did not reach GitHub (no network, no login, the deadline): every checkout
        /// of the call failed, as one `gh pr list` would have.
        case unreachable
        /// An answer this does not read: every checkout of the call is looked up alone.
        case notUnderstood
    }

    /// Pure: an outcome from what `gh api graphql` printed. `gh` exits 1 when any alias
    /// has an error but still prints the whole answer, so the exit status alone says little.
    static func outcome(stdout: Data, succeeded: Bool, timedOut: Bool, count: Int) -> Outcome {
        if timedOut { return .unreachable }
        if let lookups = parse(stdout, count: count) { return .answered(lookups) }
        let printedJSON = (try? JSONSerialization.jsonObject(with: stdout)) != nil
        return succeeded || printedJSON ? .notUnderstood : .unreachable
    }

    /// Which checkouts go into which call, and which are looked up alone.
    struct Plan: Equatable {
        /// The calls, at most `cap` requests each.
        var calls: [[Request]] = []
        /// For each checkout (by index) the request that answers it.
        var requestOf: [Int: Request] = [:]
        /// The checkouts looked up alone, with the reason.
        var alone: [Int: String] = [:]
    }

    /// Pure. Checkouts that ask the same repository about the same branch (two clones)
    /// share one alias. A branch with `:` is left to `gh` (git allows none in a branch).
    static func plan(resolutions: [RepoResolution], branches: [String], cap: Int = PullRequestBatch.cap) -> Plan {
        var plan = Plan()
        var requests: [Request] = []
        var known = Set<Request>()
        for (index, resolution) in resolutions.enumerated() {
            switch resolution {
            case .uncertain(let reason):
                plan.alone[index] = reason
            case .github(let repo):
                let branch = branches[index]
                guard !branch.isEmpty, !branch.contains(":") else {
                    plan.alone[index] = "branch name gh may read as owner:branch"
                    continue
                }
                let request = Request(repo: repo, branch: branch)
                plan.requestOf[index] = request
                if known.insert(request).inserted { requests.append(request) }
            }
        }
        let size = max(1, cap)
        plan.calls = stride(from: 0, to: requests.count, by: size).map {
            Array(requests[$0..<min($0 + size, requests.count)])
        }
        return plan
    }

    /// Pure: each checkout's lookup from a plan and the outcomes of its calls (in order).
    /// A checkout without an answer from its call is looked up alone by `single`.
    static func lookups(
        count: Int, plan: Plan, outcomes: [Outcome], single: (Int) -> PullRequests.Lookup
    ) -> [PullRequests.Lookup] {
        var byRequest: [Request: PullRequests.Lookup] = [:]
        var unreachable = Set<Request>()
        for (call, outcome) in zip(plan.calls, outcomes) {
            switch outcome {
            case .answered(let answers):
                for (index, request) in call.enumerated() {
                    if let answer = answers[index] { byRequest[request] = answer }
                }
            case .unreachable:
                unreachable.formUnion(call)
            case .notUnderstood:
                break
            }
        }
        return (0..<count).map { index in
            guard let request = plan.requestOf[index] else { return single(index) }
            if let answer = byRequest[request] { return answer }
            if unreachable.contains(request) { return .failed }
            return single(index)
        }
    }
}

/// Which fallbacks were already logged: a checkout that cannot be batched is logged once
/// per reason, not on every sweep. Pure.
struct FallbackNotes {
    private var last: [String: String] = [:]

    /// Whether `reason` for `key` is news (first time, or another reason). A nil reason
    /// (batched again) forgets the key, so a later fallback is logged again.
    mutating func isNews(key: String, reason: String?) -> Bool {
        guard let reason else {
            last[key] = nil
            return false
        }
        guard last[key] != reason else { return false }
        if last.count > 512 { last = [:] }
        last[key] = reason
        return true
    }
}

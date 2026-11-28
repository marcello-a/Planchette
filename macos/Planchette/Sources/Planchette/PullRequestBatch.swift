import Foundation
import os

// One `gh api graphql` call for the PRs of every checkout of a sweep, instead of one
// `gh pr list` process per checkout and branch. With ~30 terminals the per-checkout
// processes cost about 3.5 % of a core.
//
// The danger is the repository: `gh pr list` picks it from the remotes of the folder
// it runs in, by rules that change with gh releases (`gh-resolved`, `ssh -G`, `insteadOf`,
// the hosts it is logged in to). So the batch does not rebuild those rules: it asks gh
// itself, once per checkout (`gh repo view`, `RepoAnswer`), and keeps the answer while the
// files that could change it stay as they are (`RepoCache`).

/// A repository on github.com, as `gh` names it.
struct GitHubRepo: Hashable {
    let owner: String
    let name: String
}

// MARK: - Which repository: gh's own answer, cached

/// What `gh repo view` said in a checkout.
enum RepoAnswer: Equatable {
    /// A repository on github.com: the checkout joins the batch.
    case github(GitHubRepo)
    /// A repository on another host (Enterprise): looked up alone.
    case elsewhere(host: String)
    /// No answer — an error, no remote, no login, the deadline: looked up alone.
    case failed(String)

    /// How long the answer is kept while its files do not change. A failure is asked
    /// again sooner: it may be the network.
    var lifetime: TimeInterval {
        if case .failed = self { return RepoCache.failureLifetime }
        return RepoCache.lifetime
    }

    /// The arguments: the same `gh`, run in the same folder as `gh pr list`, so it picks
    /// the repository the same way. Checked with gh 2.106 against `GH_DEBUG=api gh pr list`.
    static let arguments = ["repo", "view", "--json", "nameWithOwner,url"]

    /// Pure: the answer in what `gh repo view` printed.
    static func from(_ output: Subprocess.Output?) -> RepoAnswer {
        guard let output else { return .failed("gh repo view could not start") }
        if output.timedOut { return .failed("gh repo view timed out") }
        guard output.status == 0 else { return .failed("gh repo view failed") }
        guard let object = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let fullName = object["nameWithOwner"] as? String,
              let host = (object["url"] as? String).flatMap(URL.init(string:))?.host?.lowercased()
        else { return .failed("gh repo view gave an unreadable answer") }
        guard host == "github.com" else { return .elsewhere(host: host) }
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return .failed("gh repo view gave an unreadable answer")
        }
        return .github(GitHubRepo(owner: String(parts[0]), name: String(parts[1])))
    }
}

/// A file as `stat` sees it; a missing file has none (nil). Equal stamps: nothing changed.
struct FileStamp: Equatable {
    let device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int

    static func of(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                         seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}

/// `gh repo view`'s answers per checkout root. An answer stands while none of the files
/// that decide it changed (`stampedFiles`) and it is younger than its lifetime. Pure.
struct RepoCache {
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let failureLifetime: TimeInterval = 10 * 60

    private struct Entry {
        let answer: RepoAnswer
        let stamps: [FileStamp?]
        let at: Date
    }

    private var entries: [String: Entry] = [:]

    func answer(root: String, stamps: [FileStamp?], now: Date) -> RepoAnswer? {
        guard let entry = entries[root], entry.stamps == stamps, now >= entry.at,
              now.timeIntervalSince(entry.at) < entry.answer.lifetime else { return nil }
        return entry.answer
    }

    mutating func store(root: String, answer: RepoAnswer, stamps: [FileStamp?], at: Date) {
        // The roots of live terminals — a handful — but never every checkout ever seen.
        if entries.count > 512 { entries = [:] }
        entries[root] = Entry(answer: answer, stamps: stamps, at: at)
    }

    /// The files whose change can change gh's pick in the checkout at `root`: its `.git`
    /// entry, the repository's `config` and `config.worktree`, the user's git configs, the
    /// SSH config (`ssh -G`), and gh's own `hosts.yml` and `config.yml`.
    static func stampedFiles(root: String, environment: [String: String], home: String) -> [String] {
        func nonEmpty(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        let xdg = nonEmpty("XDG_CONFIG_HOME") ?? home + "/.config"
        let ghDir = nonEmpty("GH_CONFIG_DIR") ?? xdg + "/gh"
        var files = [root + "/.git"]
        if let dirs = gitDirs(checkoutRoot: root) {
            files += [dirs.commonDir + "/config", dirs.gitDir + "/config.worktree"]
        }
        return files + [xdg + "/git/config", home + "/.gitconfig", home + "/.ssh/config",
                        ghDir + "/hosts.yml", ghDir + "/config.yml"]
    }

    /// A checkout's own git dir (`.git`, or the one a worktree's or submodule's `.git`
    /// file names) and the common dir that holds `config` (a linked worktree's `commondir`).
    struct GitDirs: Equatable {
        let gitDir: String
        let commonDir: String
    }

    static func gitDirs(checkoutRoot root: String, read: (String) -> String? = StatCachedText.read) -> GitDirs? {
        let dotGit = root + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        var gitDir = dotGit
        if !isDirectory.boolValue {
            guard let line = read(dotGit)?.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            gitDir = absolute(target, relativeTo: root)
        }
        guard let common = read(gitDir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !common.isEmpty else { return GitDirs(gitDir: gitDir, commonDir: gitDir) }
        return GitDirs(gitDir: gitDir, commonDir: absolute(common, relativeTo: gitDir))
    }

    private static func absolute(_ path: String, relativeTo folder: String) -> String {
        ((path.hasPrefix("/") ? path : folder + "/" + path) as NSString).standardizingPath
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
    /// under GraphQL's limits; the cap keeps one slow answer from holding a big sweep.
    static let cap = 20

    /// The node fields, the same as `gh pr list --json` is asked for, so one parse reads both.
    static var nodeFields: String { PullRequests.jsonFields.replacingOccurrences(of: ",", with: " ") }

    static func alias(_ index: Int) -> String { "r\(index)" }

    /// Pure. Every value goes in as a variable: an owner, name or branch is never written
    /// into the query text, so no quote, backslash or brace in a branch name can change it.
    /// The same connection, limit, states and order as `gh pr list --head --state all`.
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

    /// What became of one call.
    enum Outcome: Equatable {
        /// GitHub answered. An index left out (an alias with an error, null, or not shaped
        /// as asked) is looked up alone.
        case answered([Int: PullRequests.Lookup])
        /// No answer for any alias — no network, the deadline, or GitHub refused the call
        /// (bad credentials, a rate limit): every checkout of the call failed. Not asked
        /// again alone: those lookups share the token and the limit.
        case unreachable
        /// A `data` object this does not read: every checkout of the call is asked alone.
        case notUnderstood
    }

    /// Pure: the outcome of a call of `count` aliases from what `gh api graphql` printed.
    /// gh exits 1 when any alias has an error but still prints the whole answer, so the
    /// exit status says nothing here. An alias answered is picked as `PullRequests.parse` picks.
    static func outcome(stdout: Data, timedOut: Bool, count: Int) -> Outcome {
        guard !timedOut,
              let root = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let data = root["data"], !(data is NSNull) else { return .unreachable }
        var failed = Set<String>()
        if let errors = root["errors"], !(errors is NSNull) {
            guard let list = errors as? [Any] else { return .notUnderstood }
            for item in list {
                // An error that names no alias is about the whole call.
                guard let error = item as? [String: Any], let path = error["path"] as? [Any],
                      let first = path.first as? String else { return .unreachable }
                failed.insert(first)
            }
        }
        guard let answer = data as? [String: Any] else { return .notUnderstood }
        var lookups: [Int: PullRequests.Lookup] = [:]
        for index in 0..<count {
            let name = alias(index)
            guard !failed.contains(name), let repository = answer[name] as? [String: Any],
                  let pullRequests = repository["pullRequests"] as? [String: Any],
                  let nodes = pullRequests["nodes"] as? [Any] else { continue }
            let items = nodes.compactMap { $0 as? [String: Any] }
            lookups[index] = PullRequests.choose(items).map(PullRequests.Lookup.found) ?? PullRequests.Lookup.none
        }
        return .answered(lookups)
    }

    /// Which checkouts go into which call.
    struct Plan: Equatable {
        /// The calls, at most `cap` requests each.
        var calls: [[Request]] = []
        /// For each checkout (by index) in the batch, the request that answers it.
        var requestOf: [Int: Request] = [:]
    }

    /// Pure. `repos[i]` nil: checkout `i` is not in the batch. Checkouts that ask the same
    /// repository about the same branch (two clones) share one alias. A branch with `:` is
    /// left to gh (git allows none in a branch).
    static func plan(repos: [GitHubRepo?], branches: [String], cap: Int = PullRequestBatch.cap) -> Plan {
        var plan = Plan()
        var requests: [Request] = []
        var known = Set<Request>()
        for (index, repo) in repos.enumerated() {
            guard let repo, !branches[index].isEmpty, !branches[index].contains(":") else { continue }
            let request = Request(repo: repo, branch: branches[index])
            plan.requestOf[index] = request
            if known.insert(request).inserted { requests.append(request) }
        }
        let size = max(1, cap)
        plan.calls = stride(from: 0, to: requests.count, by: size).map {
            Array(requests[$0..<min($0 + size, requests.count)])
        }
        return plan
    }

    /// Pure: the answers of the planned checkouts, and the ones to ask alone (an alias the
    /// call left out, or a call not understood).
    static func merge(plan: Plan, outcomes: [Outcome]) -> (answers: [Int: PullRequests.Lookup], alone: [Int]) {
        var byRequest: [Request: PullRequests.Lookup] = [:]
        for (call, outcome) in zip(plan.calls, outcomes) {
            switch outcome {
            case .answered(let answers):
                for (index, request) in call.enumerated() {
                    if let answer = answers[index] { byRequest[request] = answer }
                }
            case .unreachable:
                for request in call { byRequest[request] = .failed }
            case .notUnderstood:
                break
            }
        }
        var answers: [Int: PullRequests.Lookup] = [:]
        var alone: [Int] = []
        for (index, request) in plan.requestOf.sorted(by: { $0.key < $1.key }) {
            if let answer = byRequest[request] { answers[index] = answer } else { alone.append(index) }
        }
        return (answers, alone)
    }

    /// `body(i)` for every `i` in `0..<count`, at most `limit` at a time. The results are
    /// in order. Blocking: the caller waits for all of them.
    static func concurrentMap<T>(_ count: Int, limit: Int, _ body: (Int) -> T) -> [T] {
        guard count > 0 else { return [] }
        let results = LockedResults<T>(count: count)
        DispatchQueue.concurrentPerform(iterations: min(max(1, limit), count)) { _ in
            while let index = results.claim() {
                results.set(index, body(index))
            }
        }
        return results.values
    }
}

/// The shared state of `concurrentMap`: the next index to take, and the results.
private final class LockedResults<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var stored: [T?]

    init(count: Int) { stored = Array(repeating: nil, count: count) }

    func claim() -> Int? {
        lock.withLock {
            guard next < stored.count else { return nil }
            defer { next += 1 }
            return next
        }
    }

    func set(_ index: Int, _ value: T) { lock.withLock { stored[index] = value } }

    var values: [T] { lock.withLock { stored.map { $0! } } }
}

/// Which fallbacks were already logged: each checkout and reason once, so a sweep that
/// keeps falling back the same way logs nothing new. Pure.
struct FallbackNotes {
    private var seen = Set<String>()

    mutating func isNews(key: String, reason: String) -> Bool {
        if seen.count > 1024 { seen = [] }
        return seen.insert("\(key)\u{0}\(reason)").inserted
    }
}

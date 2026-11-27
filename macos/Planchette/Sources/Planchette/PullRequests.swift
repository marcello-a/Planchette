import Foundation
import os

/// The pull request of a terminal's branch, read through the GitHub CLI (`gh`).
///
/// Why `gh` and not the REST API: it already carries the user's login for every
/// host they work with (github.com and Enterprise alike), so there is no token
/// to ask for and store. Without `gh` — or without a login — there is simply no
/// PR pill; nothing else depends on it.
///
/// Parsing is pure and unit-tested; `lookup` is a subprocess and must be called
/// off the main thread (AGENTS.md rule 6).
struct PullRequest: Equatable {
    enum Status: String, Equatable {
        case draft, open, merged, closed
    }

    /// GitHub's `reviewDecision`. Only meaningful while the PR is open.
    enum Review: String, Equatable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    let number: Int
    let status: Status
    let review: Review?
    let url: URL
    let title: String
}

enum PullRequests {
    /// Where `gh` normally lives. Searched absolutely: a GUI app's PATH does not
    /// include Homebrew (same reason as `Durable.candidatePaths`).
    static let candidatePaths = [
        "/opt/homebrew/bin/gh",   // Apple silicon Homebrew
        "/usr/local/bin/gh",      // Intel Homebrew, the official pkg installer
        "/opt/local/bin/gh",      // MacPorts
    ]

    static func ghPath(
        searching candidates: [String] = candidatePaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: isExecutable)
    }

    /// Branches that are a repo's trunk, not a piece of work. A PR *from* `main`
    /// is almost always a mistake on someone's fork, and asking for one on every
    /// poll of every terminal parked on `main` would be the bulk of the traffic.
    static let trunkBranches: Set<String> = ["main", "master", "develop", "dev", "trunk"]

    static func isWorkBranch(_ branch: String) -> Bool {
        !branch.isEmpty && !trunkBranches.contains(branch)
    }

    /// The terminals whose branch is not the one it was: their PR belongs to the
    /// old branch. A terminal that is new to the map had no PR to lose.
    static func movedSessions(from old: [UUID: String], to new: [UUID: String]) -> Set<UUID> {
        Set(old.keys.filter { new[$0] != old[$0] })
    }

    /// The least time between two `gh` lookups that a finished command or turn in
    /// one terminal asks for. An agent ends many tool calls a minute; the regular
    /// poll stays `AppState.pullRequestPollInterval`.
    static let eagerGap: TimeInterval = 15

    /// How long the regular poll leaves a merged or closed PR alone. A decided PR
    /// hardly changes again; a branch that gets a new PR is caught by the eager
    /// lookup after the `gh pr create` or the `git push` that made it.
    static let decidedRecheck: TimeInterval = 15 * 60

    /// Which terminals a sweep asks `gh` about: every one (the timer, the app coming
    /// to the front), or the ones where something just happened.
    enum SweepScope: Equatable {
        case all
        case sessions(Set<UUID>)
        /// Every terminal, and these were asked about by name: a sweep of some terminals
        /// that waited for the same run as a sweep of all. A named terminal is asked
        /// even while its decided PR rests (`resting`) — a `gh pr reopen` must show.
        case allNaming(Set<UUID>)

        /// Two requests that wait for the same run, as one.
        func adding(_ other: SweepScope) -> SweepScope {
            if case .sessions(let a) = self, case .sessions(let b) = other { return .sessions(a.union(b)) }
            let named = self.named.union(other.named)
            return named.isEmpty ? .all : .allNaming(named)
        }

        /// The terminals asked about by name.
        var named: Set<UUID> {
            switch self {
            case .all: return []
            case .sessions(let ids), .allNaming(let ids): return ids
            }
        }

        /// Whether the sweep covers every terminal.
        var coversAll: Bool {
            if case .sessions = self { return false }
            return true
        }

        func contains(_ id: UUID) -> Bool {
            coversAll || named.contains(id)
        }
    }

    /// A terminal as a sweep sees it: its checkout's root folder (nil outside a
    /// repository, then its own folder stands in), its folder and its branch.
    struct Terminal: Equatable {
        let id: UUID
        let root: String?
        let directory: String
        let branch: String
    }

    /// One `gh` lookup: a checkout's branch and every terminal that shows its PR.
    struct Checkout: Equatable {
        let directory: String
        let branch: String
        var ids: [UUID]
    }

    /// The lookups of a sweep. Terminals in one checkout on one branch share a
    /// lookup — the root of a monorepo and a package folder in it used to ask `gh`
    /// the same question twice. A checkout is asked about when its scope names one of
    /// its terminals, and skipped when every terminal of it is in `resting` (a decided
    /// PR checked a short while ago). The order is stable, for tests and for `gh`.
    static func checkouts(
        of terminals: [Terminal], scope: SweepScope, resting: Set<UUID>
    ) -> [Checkout] {
        var byKey: [String: Checkout] = [:]
        var order: [String] = []
        for terminal in terminals where isWorkBranch(terminal.branch) && !terminal.directory.isEmpty {
            let key = "\(terminal.root ?? terminal.directory)\u{0}\(terminal.branch)"
            if byKey[key] == nil {
                byKey[key] = Checkout(directory: terminal.directory, branch: terminal.branch, ids: [])
                order.append(key)
            }
            byKey[key]?.ids.append(terminal.id)
        }
        return order.compactMap { byKey[$0] }.filter { checkout in
            checkout.ids.contains(where: scope.contains)
                && !(scope.coversAll && checkout.ids.allSatisfy {
                    resting.contains($0) && !scope.named.contains($0)
                })
        }
    }

    /// The terminals whose PR is decided (merged, closed) and was asked about less
    /// than `decidedRecheck` ago: the regular poll leaves them alone.
    static func resting(
        shown: [UUID: PullRequest], decidedAt: [UUID: Date], now: Date
    ) -> Set<UUID> {
        Set(shown.compactMap { id, pr in
            guard pr.status == .merged || pr.status == .closed,
                  let at = decidedAt[id], now.timeIntervalSince(at) < decidedRecheck else { return nil }
            return id
        })
    }

    /// Whether a finished tool call can have switched a branch or made a PR, so its
    /// terminal's PR is worth asking about now. A shell command that runs `gh`, or a
    /// `git` that is not only a read (`readOnlyGitCommands`), can; Claude Code's file,
    /// search and web tools cannot, and an MCP tool that makes a PR is seen at the end
    /// of the turn or by the next poll. A tool this does not know (another agent's
    /// names) counts as "can": the old behaviour. Agents run `git status` and `git diff`
    /// all the time, and each one started a `gh` process.
    static func toolMayChangeGit(toolName: String?, command: String?) -> Bool {
        guard let toolName else { return true }
        guard toolName == "Bash" else { return !Self.toolsThatLeaveGitAlone.contains(toolName) && !toolName.hasPrefix("mcp__") }
        guard let command else { return true }
        return commandMayChangeGit(command)
    }

    /// Whether a finished tool call means the end of its turn should ask about the PR.
    /// Wider than `toolMayChangeGit`, which starts a lookup at once: any shell command
    /// counts unless all it does with git is read (`make pr`, a script, an alias can
    /// push and open a PR without naming `git`), and so does an MCP tool. Only a turn
    /// of reads, edits, searches and `git status` skips the lookup at its end.
    static func toolMayTouchGitByTurnEnd(toolName: String?, command: String?) -> Bool {
        guard let toolName else { return true }
        if toolName.hasPrefix("mcp__") { return true }
        guard toolName == "Bash" else { return toolMayChangeGit(toolName: toolName, command: command) }
        guard let command else { return true }
        return !onlyReadsGit(command)
    }

    /// Pure: whether a command runs git, and only to read (`git status && git diff`,
    /// `git log | head`). Every simple command of it has to be a read-only `git` or a
    /// command in `commandsThatLeaveGitAlone`: `git status && make pr` can push.
    static func onlyReadsGit(_ command: String) -> Bool {
        var readsGit = false
        let simpleCommands = command.split(whereSeparator: { ";&|()\n`{}".contains($0) })
        for simple in simpleCommands {
            var words = simple.split(whereSeparator: \.isWhitespace)[...]
            while let word = words.first, word.contains("="), !word.hasPrefix("-") {
                words = words.dropFirst()   // `GIT_PAGER=cat git log`
            }
            guard let name = words.first.map(String.init) else { continue }
            if name == "git" {
                let rest = words.dropFirst().joined(separator: " ")
                guard let sub = gitSubcommand(after: rest), readOnlyGitCommands.contains(sub) else { return false }
                readsGit = true
            } else if !commandsThatLeaveGitAlone.contains(name) {
                return false
            }
        }
        return readsGit
    }

    /// Shell commands that never change a branch or a PR, for `onlyReadsGit`.
    static let commandsThatLeaveGitAlone: Set<String> = [
        "cd", "pwd", "ls", "cat", "echo", "printf", "grep", "head", "tail", "wc", "sort",
        "uniq", "cut", "tr", "true", "false", "test", "[", "[[", "]", "]]",
    ]

    private static let gitOrGhPattern = #"(^|[^A-Za-z0-9_.-])(git|gh)($|[^A-Za-z0-9_-])"#

    /// Pure: whether a shell command names `gh`, or a `git` whose subcommand is not
    /// in `readOnlyGitCommands` (or cannot be told). Each `git` of a compound command
    /// counts on its own: `git status && git push` can.
    static func commandMayChangeGit(_ command: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: gitOrGhPattern) else { return true }
        let text = command as NSString
        for match in regex.matches(in: command, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 2))
            if name == "gh" { return true }
            let rest = text.substring(from: match.range(at: 2).upperBound)
            guard let sub = gitSubcommand(after: rest), readOnlyGitCommands.contains(sub) else { return true }
        }
        return false
    }

    /// The subcommand of a `git` call, from the text after the word `git`: its global
    /// options skipped (`-C <dir>`, `-c <key=value>`, `--no-pager`), up to the end of
    /// the simple command. Nil when there is none (`git` alone, `git $CMD`).
    static func gitSubcommand(after text: String) -> String? {
        let simple = text.prefix { !";&|()\n`".contains($0) }
        var words = simple.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        while let word = words.first {
            words = words.dropFirst()
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(word) {
                words = words.dropFirst()
                continue
            }
            if word.hasPrefix("-") { continue }
            return word.allSatisfy({ $0.isLetter || $0 == "-" }) ? word : nil
        }
        return nil
    }

    /// `git` subcommands that read and never change the branch, its commits on the
    /// remote, or which repository a PR is looked up in.
    static let readOnlyGitCommands: Set<String> = [
        "status", "diff", "log", "show", "blame", "rev-parse", "ls-files", "ls-tree", "grep",
        "describe", "shortlog", "reflog", "cat-file", "ls-remote", "fetch", "rev-list", "whatchanged",
    ]

    /// Claude Code's own tools that never touch a branch or a PR.
    static let toolsThatLeaveGitAlone: Set<String> = [
        "Read", "Edit", "MultiEdit", "Write", "NotebookEdit", "Grep", "Glob", "LS",
        "WebFetch", "WebSearch", "TodoWrite", "Task", "Agent", "Skill", "ToolSearch",
        "BashOutput", "KillShell", "ExitPlanMode", "AskUserQuestion", "LSP", "Monitor",
    ]

    static func eagerRefreshDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= eagerGap
    }

    /// The fields `lookup` asks `gh` for — kept next to `parse`, which reads them.
    static let jsonFields = "number,state,isDraft,reviewDecision,url,title"

    /// Pick the PR a branch stands for out of `gh pr list --json` output. An open
    /// PR wins over everything: a branch can carry an old closed PR and a fresh
    /// one, and the fresh one is the work. Otherwise the newest (gh lists newest
    /// first). Nil for no PR, or for output we do not understand.
    static func parse(_ data: Data) -> PullRequest? {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return choose(items)
    }

    /// The pick of `parse`, over PRs as JSON objects newest first: the `gh pr list` items
    /// and the batch's GraphQL nodes (`PullRequestBatch.parse`) go through the same rule.
    static func choose(_ items: [[String: Any]]) -> PullRequest? {
        let parsed = items.compactMap(pullRequest(from:))
        return parsed.first { $0.status == .open || $0.status == .draft } ?? parsed.first
    }

    /// How many PRs of a branch are asked for, newest first — by `--limit` and by `first:`.
    static let lookupLimit = 5

    private static func pullRequest(from item: [String: Any]) -> PullRequest? {
        guard let number = item["number"] as? Int,
              let state = item["state"] as? String,
              let urlString = item["url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        let status: PullRequest.Status
        switch state.uppercased() {
        case "OPEN": status = (item["isDraft"] as? Bool ?? false) ? .draft : .open
        case "MERGED": status = .merged
        case "CLOSED": status = .closed
        default: return nil
        }
        // A decided PR has no review left to wait for — showing "changes
        // requested" on a merged PR would be history, not news.
        let review = status == .open
            ? (item["reviewDecision"] as? String).flatMap(PullRequest.Review.init(rawValue:))
            : nil
        return PullRequest(number: number, status: status, review: review, url: url,
                           title: item["title"] as? String ?? "")
    }

    /// What `gh` said about a branch.
    enum Lookup: Equatable {
        case found(PullRequest)
        /// `gh` answered: the branch has no PR.
        case none
        /// `gh` did not answer — no network, a timeout, not logged in, not a
        /// GitHub remote. Says nothing about the PR, so the pill stays as it was.
        case failed
    }

    /// The PR each terminal shows after a sweep. A terminal whose lookup failed
    /// keeps what it showed — one dropped connection must not take every pill
    /// away for a minute — but only while it is on the branch that was asked for.
    static func merge(
        answers: [UUID: Lookup], asked: [UUID: String], branches: [UUID: String],
        previous: [UUID: PullRequest]
    ) -> [UUID: PullRequest] {
        answers.reduce(into: [:]) { result, entry in
            let id = entry.key
            guard let branch = asked[id], branches[id] == branch else { return }
            switch entry.value {
            case .found(let pr): result[id] = pr
            case .none: break
            case .failed: result[id] = previous[id]
            }
        }
    }

    /// Ask `gh` for the PR of `branch`, run inside `directory` so `gh` resolves
    /// the repo (and its remote host) the way it would in that terminal.
    /// No failure is an alert: no `gh`, no login, no network all mean "no pill".
    static func lookup(branch: String, in directory: String) -> Lookup {
        guard let gh = ghPath() else { return .none }
        // A hung network call must not hold a poll forever.
        guard let result = Subprocess.run(
            gh,
            ["pr", "list", "--head", branch, "--state", "all",
             "--limit", String(lookupLimit), "--json", jsonFields],
            in: directory, timeout: lookupTimeout),
              result.succeeded
        else { return .failed }
        return parse(result.stdout).map(Lookup.found) ?? .none
    }

    /// The deadline of one `gh` call, alone or batched.
    static let lookupTimeout: TimeInterval = 20

    /// The lookups of a sweep, in the order of `checkouts`. Every checkout whose repository
    /// is certain (`GhRepoResolver`) is asked in one `gh api graphql` call per
    /// `PullRequestBatch.cap` checkouts; the others — and those the call did not answer —
    /// get their own `gh pr list`, as before. Blocking: call it off the main thread.
    static func lookup(_ checkouts: [Checkout]) -> [Lookup] {
        guard !checkouts.isEmpty, ghPath() != nil else { return checkouts.map { _ in .none } }
        let environment = ProcessInfo.processInfo.environment
        let resolutions: [RepoResolution]
        if let blocker = GhRepoResolver.environmentBlocker(environment) {
            resolutions = checkouts.map { _ in .uncertain(blocker) }
        } else {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            let outer = GhRepoResolver.outerRules(
                paths: GhRepoResolver.outerConfigPaths(environment: environment, home: home), home: home)
            resolutions = checkouts.map {
                GhRepoResolver.resolve(checkoutRoot: Titles.checkoutRoot(forDirectory: $0.directory), outer: outer)
            }
        }
        return lookup(checkouts, resolutions: resolutions, call: callGraphQL,
                      single: { lookup(branch: $0.branch, in: $0.directory) })
    }

    /// The sweep with its side effects passed in (`call` runs one batch, `single` one
    /// `gh pr list`), so the tests drive it. Logs each fallback once per checkout and reason.
    static func lookup(
        _ checkouts: [Checkout], resolutions: [RepoResolution],
        call: ([PullRequestBatch.Request]) -> PullRequestBatch.Outcome,
        single: (Checkout) -> Lookup
    ) -> [Lookup] {
        let plan = PullRequestBatch.plan(resolutions: resolutions, branches: checkouts.map(\.branch))
        let outcomes = plan.calls.map(call)
        for (index, checkout) in checkouts.enumerated() {
            noteFallback(key: checkout.directory, reason: plan.alone[index].map { "looked up alone: \($0)" })
        }
        var problem: String?
        for (call, outcome) in zip(plan.calls, outcomes) where problem == nil {
            switch outcome {
            case .answered(let answers) where answers.count < call.count:
                problem = "GitHub did not answer \(call.count - answers.count) of \(call.count) checkouts; they are looked up alone"
            case .unreachable:
                problem = "gh api graphql did not reach GitHub; the lookups failed"
            case .notUnderstood:
                problem = "the answer of gh api graphql is not understood; its checkouts are looked up alone"
            case .answered:
                break
            }
        }
        noteFallback(key: "the batch", reason: problem)
        return PullRequestBatch.lookups(count: checkouts.count, plan: plan, outcomes: outcomes) { single(checkouts[$0]) }
    }

    /// One batch through `gh api graphql`, always against github.com: `gh api` would
    /// otherwise take the host from `GH_HOST` or the only host logged in.
    static func callGraphQL(_ requests: [PullRequestBatch.Request]) -> PullRequestBatch.Outcome {
        guard let gh = ghPath(),
              let result = Subprocess.run(
                gh, ["api", "graphql", "--hostname", "github.com", "--input", "-"],
                timeout: lookupTimeout, input: PullRequestBatch.body(for: requests))
        else { return .unreachable }
        return PullRequestBatch.outcome(stdout: result.stdout, succeeded: result.succeeded,
                                        timedOut: result.timedOut, count: requests.count)
    }

    private static let fallbackNotes = OSAllocatedUnfairLock(initialState: FallbackNotes())

    /// A debug line when a checkout (or the batch) falls back, once per reason — not on
    /// every sweep.
    private static func noteFallback(key: String, reason: String?) {
        guard fallbackNotes.withLock({ $0.isNews(key: key, reason: reason) }), let reason else { return }
        Log.debug("pull requests: \(key): \(reason)")
    }
}

/// The eager `gh` lookups (`AppState.gitMayHaveChanged`): when each checkout and
/// branch was last asked, and which terminals wait for the end of its gap. Pure,
/// so the timing is tested without the app.
struct EagerLookups {
    enum Decision: Equatable {
        /// Ask `gh` now.
        case askNow
        /// The first request inside the gap: call `takeDeferred` after this long.
        case deferFor(TimeInterval)
        /// A request inside the gap whose key already waits: it joins that lookup.
        case joined
        /// A request inside the gap with no terminal (the app came to the front).
        case dropped
    }

    private(set) var last: [String: Date] = [:]
    private(set) var waiting: [String: Set<UUID>] = [:]

    /// A request for `key` (folder and branch; `""` for the whole app) from
    /// terminal `id`, nil when the app came to the front.
    mutating func request(key: String, id: UUID?, now: Date) -> Decision {
        if PullRequests.eagerRefreshDue(last: last[key], now: now) {
            mark(key, now: now)
            return .askNow
        }
        guard let id else { return .dropped }
        if waiting[key] != nil {
            waiting[key]?.insert(id)
            return .joined
        }
        waiting[key] = [id]
        let elapsed = last[key].map { now.timeIntervalSince($0) } ?? 0
        return .deferFor(max(0, PullRequests.eagerGap - elapsed))
    }

    /// The gap of `key` ended: the terminals that asked inside it, now asked about.
    mutating func takeDeferred(key: String, now: Date) -> Set<UUID> {
        let ids = waiting.removeValue(forKey: key) ?? []
        if !ids.isEmpty { mark(key, now: now) }
        return ids
    }

    /// A closed terminal waits for nothing.
    mutating func forget(_ id: UUID) {
        for key in waiting.keys {
            waiting[key]?.remove(id)
        }
    }

    private mutating func mark(_ key: String, now: Date) {
        // Only the gaps still running are worth keeping: the table stays small.
        last = last.filter { !PullRequests.eagerRefreshDue(last: $0.value, now: now) }
        last[key] = now
    }
}

/// Per terminal, whether a tool call of the running turn may have touched git (a
/// shell command that is not only a git read, an MCP tool, a tool this does not
/// know). Nothing is recorded while no tool call was reported — an agent without
/// tool hooks, or a turn that called none — and such a turn asks. Pure.
struct TurnGitRecord {
    private var touched: [UUID: Bool] = [:]

    /// A hook event arrived for terminal `id`.
    mutating func record(event: String, id: UUID, mayTouchGit: Bool) {
        if AttentionState.toolDoneEvents.contains(event) {
            touched[id] = (touched[id] ?? false) || mayTouchGit
        } else if event == "UserPromptSubmit" || event == "SessionEnd" {
            touched[id] = nil
        }
    }

    /// A turn (`endsTurn`) or a subagent ended: whether to ask `gh`. A subagent's end
    /// keeps the record for the turn that runs on.
    mutating func turnEnded(_ id: UUID, endsTurn: Bool) -> Bool {
        let asks = touched[id] != false
        if endsTurn { touched[id] = nil }
        return asks
    }

    mutating func forget(_ id: UUID) {
        touched[id] = nil
    }
}

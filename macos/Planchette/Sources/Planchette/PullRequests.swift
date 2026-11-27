import Foundation

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

        /// Two requests that wait for the same run, as one.
        func adding(_ other: SweepScope) -> SweepScope {
            switch (self, other) {
            case (.sessions(let a), .sessions(let b)): return .sessions(a.union(b))
            default: return .all
            }
        }

        func contains(_ id: UUID) -> Bool {
            switch self {
            case .all: return true
            case .sessions(let ids): return ids.contains(id)
            }
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
                && !(scope == .all && checkout.ids.allSatisfy(resting.contains))
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
    /// terminal's PR is worth asking about now. A shell command that names `git` or
    /// `gh` can; Claude Code's file, search and web tools cannot, and an MCP tool that
    /// makes a PR is seen at the end of the turn or by the next poll. A tool this does
    /// not know (another agent's names) counts as "can": the old behaviour.
    static func toolMayChangeGit(toolName: String?, command: String?) -> Bool {
        guard let toolName else { return true }
        guard toolName == "Bash" else { return !Self.toolsThatLeaveGitAlone.contains(toolName) && !toolName.hasPrefix("mcp__") }
        guard let command else { return true }
        return command.range(of: #"(^|[^A-Za-z0-9_.-])(git|gh)($|[^A-Za-z0-9_-])"#, options: .regularExpression) != nil
    }

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
        let parsed = items.compactMap(pullRequest(from:))
        return parsed.first { $0.status == .open || $0.status == .draft } ?? parsed.first
    }

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
             "--limit", "5", "--json", jsonFields],
            in: directory, timeout: 20),
              result.succeeded
        else { return .failed }
        return parse(result.stdout).map(Lookup.found) ?? .none
    }
}

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

    /// The least time between two `gh` sweeps that a finished command or turn
    /// asks for. An agent ends many tool calls a minute; the regular poll stays
    /// `AppState.pullRequestPollInterval`.
    static let eagerGap: TimeInterval = 15

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

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

    /// Ask `gh` for the PR of `branch`, run inside `directory` so `gh` resolves
    /// the repo (and its remote host) the way it would in that terminal.
    /// Returns nil for no PR and for every failure — no `gh`, not logged in, no
    /// network, not a GitHub remote: all of them mean "no pill", never an alert.
    static func lookup(branch: String, in directory: String) -> PullRequest? {
        guard let gh = ghPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["pr", "list", "--head", branch, "--state", "all",
                             "--limit", "5", "--json", jsonFields]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A hung network call must not hold a poll forever.
        let killer = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
    }
}

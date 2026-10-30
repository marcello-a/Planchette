import Foundation

/// Pull requests that wait for the user's review, and the review Planchette runs
/// for each one (the Reviews mode of the notifications panel).
///
/// The review itself is the `review-pr` skill in a terminal: it writes
/// `findings.json` into the PR's review directory, Planchette shows the findings
/// and writes the user's `decisions.json`, the skill posts the review and writes
/// `sent.json`. These three files are the whole contract between the two, so
/// either side can be changed without the other noticing.
///
/// Everything in this file is pure or a plain subprocess call: parse, merge, rank
/// and preselect are unit-tested, and `fetch` must run off the main thread
/// (AGENTS.md rule 6).
enum ReviewRequests {
    /// One GitHub question every five minutes: a review request is news for
    /// hours, and each poll is a network call.
    static let pollInterval: TimeInterval = 300
    /// The panel's own refresh button may ask sooner, but not in a loop.
    static let minimumManualInterval: TimeInterval = 10

    // MARK: Fetch

    /// The GraphQL document: who the user is, every open PR that asks them or one
    /// of their teams for a review, and the state of the PRs Planchette still
    /// tracks (a review in progress, or one that was sent) — those are no longer
    /// "requested" once a review is in, so the search alone would lose them.
    /// The tracked URLs travel as variables, never inside the document.
    static func query(trackedCount: Int) -> String {
        let vars = (0..<trackedCount).map { ", $u\($0): URI!" }.joined()
        let tracked = (0..<trackedCount)
            .map { "t\($0): resource(url: $u\($0)) { ... on PullRequest { url state headRefOid } }" }
            .joined(separator: "\n")
        return """
        query($q: String!\(vars)) {
          viewer { login }
          search(query: $q, type: ISSUE, first: 50) { nodes { ... on PullRequest {
            url number title isDraft updatedAt additions deletions changedFiles
            headRefName headRefOid baseRefName
            author { login } repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            reviewRequests(first: 20) { nodes { requestedReviewer {
              __typename ... on User { login } ... on Team { name }
            } } }
            timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 30) { nodes { ... on ReviewRequestedEvent {
              createdAt requestedReviewer { __typename ... on User { login } ... on Team { name } }
            } } }
          } } }
          \(tracked)
        }
        """
    }

    static let searchQuery = "is:pr is:open archived:false review-requested:@me"

    /// What one poll learned.
    struct Fetch: Equatable {
        var viewer: String
        var requested: [ReviewPR]
        /// The tracked PRs GitHub answered for, by URL. A URL that is missing
        /// here was not answered (deleted, no access) — not "closed".
        var tracked: [String: TrackedState]
    }

    struct TrackedState: Equatable {
        var open: Bool
        var headSha: String
    }

    /// Ask GitHub. Nil when `gh` is missing, not logged in, offline or slow:
    /// the panel then keeps what it had, exactly like the PR pills do.
    static func fetch(tracked urls: [String]) -> Fetch? {
        guard let gh = PullRequests.ghPath() else { return nil }
        var args = ["api", "graphql",
                    "-f", "query=\(query(trackedCount: urls.count))",
                    "-f", "q=\(searchQuery)"]
        for (i, url) in urls.enumerated() { args += ["-f", "u\(i)=\(url)"] }
        guard let out = Subprocess.run(gh, args, timeout: 30), out.succeeded else { return nil }
        return parse(out.stdout, trackedCount: urls.count)
    }

    /// Pure: read the GraphQL answer.
    static func parse(_ data: Data, trackedCount: Int = 0) -> Fetch? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any],
              let viewer = (body["viewer"] as? [String: Any])?["login"] as? String
        else { return nil }
        let nodes = ((body["search"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let requested = nodes.compactMap { pr(from: $0, viewer: viewer) }
        var tracked: [String: TrackedState] = [:]
        for i in 0..<trackedCount {
            guard let node = body["t\(i)"] as? [String: Any],
                  let url = node["url"] as? String,
                  let state = node["state"] as? String
            else { continue }
            tracked[url] = TrackedState(open: state == "OPEN", headSha: node["headRefOid"] as? String ?? "")
        }
        return Fetch(viewer: viewer, requested: requested, tracked: tracked)
    }

    private static let isoDate: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func pr(from node: [String: Any], viewer: String) -> ReviewPR? {
        guard let url = node["url"] as? String,
              let number = node["number"] as? Int,
              let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String
        else { return nil }
        let reviewers = (((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
            .compactMap { $0["requestedReviewer"] as? [String: Any] }
        let mine = reviewers.contains {
            ($0["__typename"] as? String) == "User"
                && (($0["login"] as? String)?.caseInsensitiveCompare(viewer) == .orderedSame)
        }
        let team = reviewers.first { ($0["__typename"] as? String) == "Team" }?["name"] as? String
        // When you were asked: the latest request to you by name — or to the team, when only the
        // team was asked. A request asked again is the newer one: that is how long it has waited.
        let events = (((node["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
        let asked = events.compactMap { event -> Date? in
            guard let reviewer = event["requestedReviewer"] as? [String: Any],
                  let at = (event["createdAt"] as? String).flatMap({ isoDate.date(from: $0) }) else { return nil }
            let isUser = (reviewer["__typename"] as? String) == "User"
            let matches = mine
                ? isUser && (reviewer["login"] as? String)?.caseInsensitiveCompare(viewer) == .orderedSame
                : !isUser && (reviewer["name"] as? String) == team
            return matches ? at : nil
        }.max()
        let rollup = ((((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]
            as? [String: Any])?["statusCheckRollup"] as? [String: Any])?["state"] as? String
        return ReviewPR(
            url: url,
            repo: repo,
            number: number,
            title: node["title"] as? String ?? "",
            author: (node["author"] as? [String: Any])?["login"] as? String ?? "",
            isDraft: node["isDraft"] as? Bool ?? false,
            additions: node["additions"] as? Int ?? 0,
            deletions: node["deletions"] as? Int ?? 0,
            changedFiles: node["changedFiles"] as? Int ?? 0,
            headRef: node["headRefName"] as? String ?? "",
            headSha: node["headRefOid"] as? String ?? "",
            baseRef: node["baseRefName"] as? String ?? "",
            checks: ReviewPR.Checks(rollup: rollup),
            updatedAt: (node["updatedAt"] as? String).flatMap { isoDate.date(from: $0) },
            requestedFromMe: mine,
            team: mine ? nil : team,
            requestedAt: asked)
    }

    // MARK: Merge

    /// What the records become after a poll. Pure, so every rule is a test:
    ///
    /// - a new request is a new row in "Needs you", unread;
    /// - a request that went away (withdrawn, merged, reviewed on github.com)
    ///   takes its row with it — while the row was only *requested*;
    /// - a review Planchette is running or has run stays until GitHub says the PR
    ///   is closed; an unanswered PR is kept, never dropped;
    /// - a sent review comes back to "Needs you", unread and marked updated, when
    ///   the author asks again or pushes new commits.
    static func merge(
        _ records: [String: ReviewRecord], with fetch: Fetch, now: Date
    ) -> [String: ReviewRecord] {
        var result = records
        let requested = Dictionary(fetch.requested.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        for (url, pr) in requested {
            guard var record = result[url] else {
                result[url] = ReviewRecord(pr: pr, stage: .requested, since: now)
                continue
            }
            let askedAgain = record.stage == .sent
            // A removed row comes back when the author asks again while the request still stands.
            if record.dismissed, let old = record.pr.requestedAt, let new = pr.requestedAt, new > old {
                record.dismissed = false
                record.unread = true
            }
            record.pr = pr
            if askedAgain { record.reopen(now: now) }
            result[url] = record
        }
        for (url, record) in records where requested[url] == nil {
            // Only a plain request goes with the request. Anything the user has
            // worked on — a review running, findings, a sent review, or one that
            // new commits reopened — stays until the PR itself is closed.
            guard isTracked(record) else {
                result[url] = nil
                continue
            }
            guard let state = fetch.tracked[url] else { continue }
            if !state.open {
                result[url] = nil
            } else if record.stage == .sent, let reviewed = record.reviewedSha,
                      !state.headSha.isEmpty, state.headSha != reviewed {
                var reopened = record
                reopened.pr.headSha = state.headSha
                reopened.reopen(now: now)
                result[url] = reopened
            }
        }
        return result
    }

    /// The URLs the next poll has to ask about by name.
    static func trackedURLs(_ records: [String: ReviewRecord]) -> [String] {
        records.values.filter(isTracked).map(\.pr.url).sorted()
    }

    /// A record that outlives its request: the user has worked on it.
    static func isTracked(_ record: ReviewRecord) -> Bool {
        record.stage != .requested || record.reviewedSha != nil
    }

    // MARK: Checkouts

    /// Where a review can run. A checkout is busy when somebody works in it; a
    /// busy checkout is never offered, only shown with its reasons.
    struct Checkout: Equatable, Identifiable {
        var path: String
        /// The main checkout of the repo — where `git worktree add` runs.
        var repoRoot: String
        var branch: String?
        /// On the trunk, detached, or on a branch that is already merged: taking
        /// it costs nobody anything.
        var trunkOrMerged: Bool
        var lastActivity: Date?
        var busy: [BusyReason]
        var id: String { path }
        var isFree: Bool { busy.isEmpty }
        var name: String { (path as NSString).lastPathComponent }
    }

    enum BusyReason: Equatable, Hashable {
        case agentRunning
        case waitingForAnswer
        case error
        case backgroundTask
        case uncommitted(Int)
        case devServer(Int)
        case reviewRunning(Int)
        /// A finished result nobody has read yet: the work there is not over.
        case unreadResult
        /// An agent session is open on a work branch: a review would switch the
        /// branch under it, and the next prompt there would land on the PR.
        case agentOnWorkBranch
    }

    /// What one terminal in a checkout says about it.
    struct TerminalFact: Equatable {
        var path: String
        /// The turn's own state: `running` only while a turn is in flight.
        var turnState: AttentionState
        var backgroundWork: Bool
        /// An agent (Claude, Codex) is alive in it, even when idle.
        var agentLive = false
        /// It finished a turn or failed, and nobody has looked yet.
        var unreadResult = false
    }

    /// Pure: why a checkout is busy. Empty = free.
    static func busyReasons(
        checkout: String, terminals: [TerminalFact], uncommitted: Int,
        devServerPorts: [Int], reviewsRunningHere: [Int], onTrunkOrMerged: Bool = true
    ) -> [BusyReason] {
        var reasons: [BusyReason] = []
        let here = terminals.filter { isInside($0.path, checkout) }
        if here.contains(where: { $0.turnState == .running }) { reasons.append(.agentRunning) }
        if here.contains(where: { $0.turnState == .waiting }) { reasons.append(.waitingForAnswer) }
        if here.contains(where: { $0.turnState == .error }) { reasons.append(.error) }
        if here.contains(where: { $0.backgroundWork && $0.turnState != .running }) {
            reasons.append(.backgroundTask)
        }
        if here.contains(where: { $0.unreadResult && $0.turnState != .error }) { reasons.append(.unreadResult) }
        if !onTrunkOrMerged, here.contains(where: { $0.agentLive && $0.turnState != .running }) {
            reasons.append(.agentOnWorkBranch)
        }
        if uncommitted > 0 { reasons.append(.uncommitted(uncommitted)) }
        if let port = devServerPorts.min() { reasons.append(.devServer(port)) }
        if let number = reviewsRunningHere.min() { reasons.append(.reviewRunning(number)) }
        return reasons
    }

    /// Pure: free checkouts first; among them the trunk or a merged branch, then
    /// the one untouched longest — so a review never takes the checkout you used
    /// an hour ago. Busy ones follow, by name.
    static func rank(_ checkouts: [Checkout]) -> [Checkout] {
        checkouts.sorted { a, b in
            if a.isFree != b.isFree { return a.isFree }
            if a.isFree {
                if a.trunkOrMerged != b.trunkOrMerged { return a.trunkOrMerged }
                let la = a.lastActivity ?? .distantPast, lb = b.lastActivity ?? .distantPast
                if la != lb { return la < lb }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        let p = (path as NSString).standardizingPath, r = (root as NSString).standardizingPath
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// `owner/repo` of a remote URL (ssh or https), lower-cased; nil for a
    /// remote that is not on GitHub.
    static func repoSlug(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = s.range(of: "github.com") else { return nil }
        s = String(s[range.upperBound...])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])".lowercased()
    }

    // MARK: Review directory and commands

    /// One directory per PR: `<state dir>/reviews/<owner>-<repo>-<number>`.
    static func reviewDirectory(for pr: ReviewPR, base: URL) -> URL {
        let slug = "\(pr.repo.replacingOccurrences(of: "/", with: "-"))-\(pr.number)"
        let safe = slug.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return base.appendingPathComponent("reviews", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    /// The shell line that starts the review in a new terminal. Every value is
    /// quoted: a PR URL is remote text (AGENTS.md: data, never a command).
    static func startCommand(pr: ReviewPR, directory: String, keepCheckout: Bool, run: ReviewRun) -> String {
        // The directory is quoted inside the prompt too: Application Support has a space.
        var prompt = "/review-pr \(pr.url) --dir \"\(directory)\""
        if keepCheckout { prompt += " --keep-checkout" }
        if run.runChecks { prompt += " --checks" }
        var command = "claude"
        // No flag for a default: Claude Code's own settings then decide, as in any terminal.
        if let model = run.model { command += " --model \(Shell.singleQuoted(model))" }
        if let effort = run.effort { command += " --effort \(effort.rawValue)" }
        return "\(command) \(Shell.singleQuoted(prompt))"
    }

    // MARK: Model and effort

    /// The models the start menu offers, as Claude Code's aliases: each one the latest of its kind.
    static let modelAliases = ["fable", "opus", "sonnet", "haiku"]

    /// A model as a person says it: "opus" → "Opus", "claude-opus-5-5" → "Opus 5.5",
    /// "sonnet[1m]" → "Sonnet 1M". A date at the end of an id is left out.
    static func modelName(_ model: String) -> String {
        var id = model.trimmingCharacters(in: .whitespaces).lowercased()
        var suffix = ""
        if let open = id.firstIndex(of: "["), id.hasSuffix("]") {
            suffix = " " + id[id.index(after: open)..<id.index(before: id.endIndex)].uppercased()
            id = String(id[..<open])
        }
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        let parts = id.split(separator: "-").map(String.init)
        let words = parts.filter { Int($0) == nil }.map(\.capitalized)
        let numbers = parts.filter { Int($0) != nil && $0.count < 8 }
        guard !words.isEmpty else { return model }
        return words.joined(separator: " ") + (numbers.isEmpty ? "" : " " + numbers.joined(separator: ".")) + suffix
    }

    /// What Claude Code runs with when the review passes no flag: `model` and `effortLevel` of
    /// `~/.claude/settings.json`. Nil for what the file does not set.
    struct ClaudeDefaults: Equatable {
        var model: String?
        var effort: ReviewEffort?
    }

    static func claudeDefaults(settings data: Data?) -> ClaudeDefaults {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ClaudeDefaults()
        }
        let model = (object["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let effort = (object["effortLevel"] as? String).flatMap(ReviewEffort.init(rawValue:))
        return ClaudeDefaults(model: model, effort: effort)
    }

    /// What the review terminal gets when the user clicks "Send review".
    static func submitPrompt(directory: String) -> String {
        "/review-pr submit \"\(directory)\""
    }

    /// The folder name of a temporary review worktree (beside the repo, like
    /// every worktree Planchette makes).
    static func worktreeName(for pr: ReviewPR) -> String { "review-pr-\(pr.number)" }
}

// MARK: - Models

/// How a review's Claude runs. Nil is Claude Code's own default: no flag is passed.
struct ReviewRun: Equatable {
    var runChecks = false
    var model: String?
    var effort: ReviewEffort?
}

/// Claude Code's `--effort` levels.
enum ReviewEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    var labelKey: LKey {
        switch self {
        case .low: .reviewEffortLow
        case .medium: .reviewEffortMedium
        case .high: .reviewEffortHigh
        case .xhigh: .reviewEffortXHigh
        case .max: .reviewEffortMax
        }
    }
}

/// A pull request as the Reviews panel shows it.
struct ReviewPR: Codable, Equatable, Identifiable {
    var url: String
    /// `owner/name`.
    var repo: String
    var number: Int
    var title: String
    var author: String
    var isDraft: Bool
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var headRef: String
    var headSha: String
    var baseRef: String
    var checks: Checks
    var updatedAt: Date?
    /// Asked by name — not only through one of the user's teams.
    var requestedFromMe: Bool
    /// The team that was asked, when the user was not asked by name.
    var team: String?
    /// When GitHub asked for the review (the latest request): how long it has waited. Nil when the
    /// timeline did not say.
    var requestedAt: Date?

    var id: String { url }
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    enum Checks: String, Codable {
        case passed, failed, pending, none

        init(rollup: String?) {
            switch rollup {
            case "SUCCESS": self = .passed
            case "FAILURE", "ERROR": self = .failed
            case "PENDING", "EXPECTED": self = .pending
            default: self = .none
            }
        }
    }
}

/// Where a review stands. Each stage wears the colour of a terminal state the
/// app already has, so it means what that colour means everywhere else.
enum ReviewStage: String, Codable {
    /// Asks for a review; nothing started yet. Blue: needs you.
    case requested
    /// A `review-pr` run works on it. Purple: working.
    case reviewing
    /// The findings are in and wait for decisions. Green: a result is ready.
    case findings
    /// The review is on GitHub; the author's turn. Gray.
    case sent

    var state: AttentionState {
        switch self {
        case .requested: .waiting
        case .reviewing: .running
        case .findings: .ready
        case .sent: .free
        }
    }

    var needsYou: Bool { self == .requested || self == .findings }
}

/// Everything the app remembers about one PR's review. Persisted
/// (`PersistedState.reviews`), keyed by the PR's URL.
struct ReviewRecord: Codable, Equatable, Identifiable {
    var pr: ReviewPR
    var stage: ReviewStage
    /// When the stage last changed: the row's age.
    var since: Date
    var unread: Bool = true
    /// The author asked again, or pushed, after a sent review: the row's chip
    /// says so instead of "Requested".
    var updated: Bool = false
    var snoozedUntil: Date?
    /// The checkout the review runs (or ran) in, and whether it is a temporary
    /// worktree that goes when the review has been sent.
    var checkout: String?
    var temporary: Bool = false
    /// The repo the temporary worktree belongs to: `git worktree remove` runs there.
    var repoRoot: String?
    var sessionID: UUID?
    var groupID: UUID?
    /// The user's decision per finding id, where it differs from — or confirms —
    /// the preselection in `findings.json`.
    var decisions: [String: ReviewDecision] = [:]
    var verdict: ReviewVerdict?
    /// "Send review" was clicked and `sent.json` is not there yet.
    var sending = false
    /// The head commit the sent review looked at: a new one reopens the row.
    var reviewedSha: String?
    var lastError: String?
    /// Taken off the list with its ×. It comes back on its own when it asks again: a new request,
    /// or new commits after a sent review (`reopen`).
    var dismissed = false

    var id: String { pr.url }

    init(pr: ReviewPR, stage: ReviewStage, since: Date) {
        self.pr = pr
        self.stage = stage
        self.since = since
    }

    mutating func reopen(now: Date) {
        stage = .requested
        since = now
        unread = true
        updated = true
        decisions = [:]
        verdict = nil
        sending = false
        sessionID = nil
        groupID = nil
        checkout = nil
        temporary = false
        lastError = nil
        dismissed = false
    }

    func isSnoozed(at now: Date) -> Bool { (snoozedUntil ?? .distantPast) > now }
}

enum ReviewDecision: String, Codable, CaseIterable, Identifiable {
    case comment, fix, skip
    var id: String { rawValue }
}

enum ReviewVerdict: String, Codable, CaseIterable, Identifiable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    var id: String { rawValue }
}

/// `findings.json`, as the `review-pr` skill writes it.
struct ReviewFindings: Codable, Equatable {
    struct PR: Codable, Equatable {
        var url: String
        var repo: String
        var number: Int
        var headSha: String?
        var headRef: String?
    }

    enum Severity: String, Codable, Comparable {
        case high, medium, low

        private var rank: Int { self == .high ? 0 : self == .medium ? 1 : 2 }
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    struct Finding: Codable, Equatable, Identifiable {
        var id: String
        var severity: Severity
        var path: String?
        var line: Int?
        var title: String?
        var text: String
        var comment: String?
        var suggestion: String?
        /// The skill's preselection.
        var decision: ReviewDecision?

        var hasSuggestion: Bool { !(suggestion ?? "").isEmpty }
        /// `file.ts:41` — the file name, not the whole path: the panel is narrow.
        var location: String? {
            guard let path, !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return line.map { "\(name):\($0)" } ?? name
        }
    }

    var version: Int?
    var pr: PR
    var checkout: String?
    var summary: String?
    var findings: [Finding]

    /// Most severe first; the skill's order within a severity.
    var sorted: [Finding] {
        findings.enumerated()
            .sorted { $0.element.severity == $1.element.severity ? $0.offset < $1.offset
                : $0.element.severity < $1.element.severity }
            .map(\.element)
    }

    /// The preselection when the skill gave none — the same table the skill uses.
    static func preselected(_ finding: Finding) -> ReviewDecision {
        if let decision = finding.decision { return decision }
        switch finding.severity {
        case .high, .medium: return .comment
        case .low: return finding.hasSuggestion ? .comment : .skip
        }
    }

    /// The decision that counts for a finding: the user's, else the preselection.
    static func decision(for finding: Finding, in decisions: [String: ReviewDecision]) -> ReviewDecision {
        decisions[finding.id] ?? preselected(finding)
    }

    /// The verdict that follows from the decisions: changes requested while a
    /// high finding is acted on, a plain comment while anything else is, and an
    /// approval when every finding is skipped.
    static func verdict(for findings: [Finding], decisions: [String: ReviewDecision]) -> ReviewVerdict {
        let acted = findings.filter { decision(for: $0, in: decisions) != .skip }
        if acted.isEmpty { return .approve }
        return acted.contains { $0.severity == .high } ? .requestChanges : .comment
    }

    static func load(from directory: URL) -> ReviewFindings? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("findings.json")) else { return nil }
        return try? JSONDecoder().decode(ReviewFindings.self, from: data)
    }
}

/// `decisions.json`, written by the app for the skill's `submit` mode.
struct ReviewDecisionsFile: Codable, Equatable {
    var version = 1
    var verdict: ReviewVerdict
    var decisions: [String: ReviewDecision]
}

/// `sent.json`, written by the skill once the review is on GitHub.
struct ReviewSent: Codable, Equatable {
    struct Commit: Codable, Equatable { var sha: String; var subject: String? }
    var verdict: ReviewVerdict?
    var reviewUrl: String?
    var pushedCommits: [Commit]?
    var errors: [String]?

    static func load(from directory: URL) -> ReviewSent? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("sent.json")) else { return nil }
        return try? JSONDecoder().decode(ReviewSent.self, from: data)
    }
}

extension ReviewRecord {
    /// Every field may be missing: a record written by an older build lacks the newer ones, and
    /// one record that fails to decode would cost the whole review list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pr = try c.decode(ReviewPR.self, forKey: .pr)
        stage = try c.decode(ReviewStage.self, forKey: .stage)
        since = try c.decode(Date.self, forKey: .since)
        unread = (try? c.decodeIfPresent(Bool.self, forKey: .unread)) ?? true
        updated = (try? c.decodeIfPresent(Bool.self, forKey: .updated)) ?? false
        snoozedUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        checkout = try? c.decodeIfPresent(String.self, forKey: .checkout)
        temporary = (try? c.decodeIfPresent(Bool.self, forKey: .temporary)) ?? false
        repoRoot = try? c.decodeIfPresent(String.self, forKey: .repoRoot)
        sessionID = try? c.decodeIfPresent(UUID.self, forKey: .sessionID)
        groupID = try? c.decodeIfPresent(UUID.self, forKey: .groupID)
        decisions = (try? c.decodeIfPresent([String: ReviewDecision].self, forKey: .decisions)) ?? [:]
        verdict = try? c.decodeIfPresent(ReviewVerdict.self, forKey: .verdict)
        sending = (try? c.decodeIfPresent(Bool.self, forKey: .sending)) ?? false
        reviewedSha = try? c.decodeIfPresent(String.self, forKey: .reviewedSha)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        dismissed = (try? c.decodeIfPresent(Bool.self, forKey: .dismissed)) ?? false
    }
}

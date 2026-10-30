import XCTest
@testable import Planchette

final class ReviewRequestsParseTests: XCTestCase {
    private func answer(_ nodes: [[String: Any]], tracked: [String: Any] = [:]) -> Data {
        var data: [String: Any] = ["viewer": ["login": "marcello-a"], "search": ["nodes": nodes]]
        for (key, value) in tracked { data[key] = value }
        return try! JSONSerialization.data(withJSONObject: ["data": data])
    }

    private func node(_ number: Int, reviewers: [[String: Any]], rollup: String? = "SUCCESS",
                      asked: [(String, [String: Any])] = []) -> [String: Any] {
        [
            "timelineItems": ["nodes": asked.map { ["createdAt": $0.0, "requestedReviewer": $0.1] }],
            "url": "https://github.com/o/r/pull/\(number)", "number": number, "title": "PR \(number)",
            "isDraft": false, "updatedAt": "2026-10-27T08:47:57Z", "additions": 10, "deletions": 2,
            "changedFiles": 3, "headRefName": "feat/x", "headRefOid": "abc", "baseRefName": "master",
            "author": ["login": "lea"], "repository": ["nameWithOwner": "o/r"],
            "commits": ["nodes": [["commit": ["statusCheckRollup": rollup.map { ["state": $0] } as Any]]]],
            "reviewRequests": ["nodes": reviewers.map { ["requestedReviewer": $0] }],
        ]
    }

    func testAskedByNameIsMine() throws {
        let fetch = try XCTUnwrap(ReviewRequests.parse(answer([
            node(1, reviewers: [["__typename": "User", "login": "Marcello-A"], ["__typename": "Team", "name": "frontend"]]),
        ])))
        let pr = try XCTUnwrap(fetch.requested.first)
        XCTAssertEqual(fetch.viewer, "marcello-a")
        XCTAssertTrue(pr.requestedFromMe, "login compares without case")
        XCTAssertNil(pr.team, "asked by name: the team is not the reason")
        XCTAssertEqual(pr.checks, .passed)
        XCTAssertEqual(pr.repoName, "r")
        XCTAssertEqual(pr.additions, 10)
    }

    func testTeamOnlyRequestNamesTheTeam() throws {
        let fetch = try XCTUnwrap(ReviewRequests.parse(answer([
            node(2, reviewers: [["__typename": "User", "login": "someone"], ["__typename": "Team", "name": "frontend"]],
                 rollup: "FAILURE"),
        ])))
        let pr = try XCTUnwrap(fetch.requested.first)
        XCTAssertFalse(pr.requestedFromMe)
        XCTAssertEqual(pr.team, "frontend")
        XCTAssertEqual(pr.checks, .failed)
    }

    func testTrackedAnswersAreByURL() throws {
        let fetch = try XCTUnwrap(ReviewRequests.parse(answer([], tracked: [
            "t0": ["url": "https://github.com/o/r/pull/7", "state": "MERGED", "headRefOid": "x"],
            "t1": NSNull(),
        ]), trackedCount: 2))
        XCTAssertEqual(fetch.tracked["https://github.com/o/r/pull/7"], .init(open: false, headSha: "x"))
        XCTAssertEqual(fetch.tracked.count, 1, "an unanswered PR is missing, not closed")
    }

    func testRequestedAtIsTheLatestRequestToYou() throws {
        let me: [String: Any] = ["__typename": "User", "login": "marcello-a"]
        let fetch = try XCTUnwrap(ReviewRequests.parse(answer([
            node(3, reviewers: [me], asked: [
                ("2026-10-20T08:00:00Z", me),
                ("2026-10-25T08:00:00Z", ["__typename": "User", "login": "someone"]),
                ("2026-10-22T09:30:00Z", ["__typename": "User", "login": "Marcello-A"]),
            ]),
        ])))
        XCTAssertEqual(fetch.requested.first?.requestedAt, ISO8601DateFormatter().date(from: "2026-10-22T09:30:00Z"),
                       "asked again: the newer request counts, somebody else's does not")
    }

    func testRequestedAtOfATeamRequestIsTheTeams() throws {
        let team: [String: Any] = ["__typename": "Team", "name": "frontend"]
        let fetch = try XCTUnwrap(ReviewRequests.parse(answer([
            node(4, reviewers: [team], asked: [("2026-10-21T10:00:00Z", team)]),
            node(5, reviewers: [team]),
        ])))
        XCTAssertEqual(fetch.requested[0].requestedAt, ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z"))
        XCTAssertNil(fetch.requested[1].requestedAt, "no event: no time, the panel falls back to when it saw it")
    }

    func testTheQueryAsksWhenTheReviewWasRequested() {
        XCTAssertTrue(ReviewRequests.query(trackedCount: 0).contains("REVIEW_REQUESTED_EVENT"))
    }

    func testGarbageIsNil() {
        XCTAssertNil(ReviewRequests.parse(Data("{\"errors\":[]}".utf8)))
    }

    func testTrackedURLsTravelAsVariables() {
        let query = ReviewRequests.query(trackedCount: 2)
        XCTAssertTrue(query.contains("$u0: URI!"))
        XCTAssertTrue(query.contains("t1: resource(url: $u1)"))
        XCTAssertFalse(query.contains("https://"), "no URL inside the document")
    }
}

final class ReviewRequestsMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pr(_ number: Int, sha: String = "a1", mine: Bool = true, asked: TimeInterval? = nil) -> ReviewPR {
        ReviewPR(url: "https://github.com/o/r/pull/\(number)", repo: "o/r", number: number, title: "PR \(number)",
                 author: "lea", isDraft: false, additions: 1, deletions: 1, changedFiles: 1, headRef: "feat/x",
                 headSha: sha, baseRef: "master", checks: .passed, updatedAt: nil, requestedFromMe: mine, team: nil,
                 requestedAt: asked.map { Date(timeIntervalSince1970: $0) })
    }

    private func record(_ pr: ReviewPR, _ stage: ReviewStage, reviewed: String? = nil) -> ReviewRecord {
        var record = ReviewRecord(pr: pr, stage: stage, since: Date(timeIntervalSince1970: 0))
        record.unread = false
        record.reviewedSha = reviewed
        return record
    }

    private func fetch(_ requested: [ReviewPR], tracked: [Int: (Bool, String)] = [:]) -> ReviewRequests.Fetch {
        ReviewRequests.Fetch(
            viewer: "me", requested: requested,
            tracked: Dictionary(uniqueKeysWithValues: tracked.map {
                ("https://github.com/o/r/pull/\($0.key)", ReviewRequests.TrackedState(open: $0.value.0, headSha: $0.value.1))
            }))
    }

    func testARemovedRowStaysRemovedWhileTheSameRequestStands() throws {
        var removed = record(pr(1, asked: 100), .requested)
        removed.dismissed = true
        let merged = ReviewRequests.merge([pr(1).url: removed], with: fetch([pr(1, asked: 100)]), now: now)
        XCTAssertEqual(merged[pr(1).url]?.dismissed, true)
        let unknown = ReviewRequests.merge([pr(1).url: removed], with: fetch([pr(1)]), now: now)
        XCTAssertEqual(unknown[pr(1).url]?.dismissed, true, "a timeline that did not answer is no new request")
    }

    func testARemovedRowComesBackWhenAskedAgain() throws {
        var removed = record(pr(1, asked: 100), .requested)
        removed.dismissed = true
        let merged = ReviewRequests.merge([pr(1).url: removed], with: fetch([pr(1, asked: 200)]), now: now)
        let row = try XCTUnwrap(merged[pr(1).url])
        XCTAssertFalse(row.dismissed)
        XCTAssertTrue(row.unread)

        let withdrawn = ReviewRequests.merge([pr(1).url: removed], with: fetch([]), now: now)
        let fresh = ReviewRequests.merge(withdrawn, with: fetch([pr(1, asked: 300)]), now: now)
        XCTAssertEqual(fresh[pr(1).url]?.dismissed, false, "withdrawn, then asked again: a new row")
    }

    func testNewCommitsBringBackARemovedSentReview() throws {
        var removed = record(pr(1), .sent, reviewed: "a1")
        removed.dismissed = true
        let merged = ReviewRequests.merge([pr(1).url: removed], with: fetch([], tracked: [1: (true, "b2")]), now: now)
        XCTAssertEqual(merged[pr(1).url]?.dismissed, false)
    }

    func testANewRequestIsAnUnreadRow() throws {
        let merged = ReviewRequests.merge([:], with: fetch([pr(1)]), now: now)
        let row = try XCTUnwrap(merged[pr(1).url])
        XCTAssertEqual(row.stage, .requested)
        XCTAssertTrue(row.unread)
        XCTAssertEqual(row.since, now)
    }

    func testAWithdrawnRequestGoes() {
        let merged = ReviewRequests.merge([pr(1).url: record(pr(1), .requested)], with: fetch([]), now: now)
        XCTAssertTrue(merged.isEmpty)
    }

    func testWorkInProgressStaysWhileThePRIsOpenOrUnanswered() {
        let records = [pr(1).url: record(pr(1), .reviewing), pr(2).url: record(pr(2), .findings)]
        let merged = ReviewRequests.merge(records, with: fetch([], tracked: [1: (true, "a1")]), now: now)
        XCTAssertEqual(merged[pr(1).url]?.stage, .reviewing)
        XCTAssertEqual(merged[pr(2).url]?.stage, .findings, "no answer about it: kept, never dropped")
    }

    func testAClosedPRTakesItsReviewWithIt() {
        let records = [pr(1).url: record(pr(1), .sent, reviewed: "a1")]
        let merged = ReviewRequests.merge(records, with: fetch([], tracked: [1: (false, "a1")]), now: now)
        XCTAssertTrue(merged.isEmpty)
    }

    func testAskedAgainReopensASentReview() throws {
        var sent = record(pr(1), .sent, reviewed: "a1")
        sent.decisions = ["f1": .fix]
        sent.verdict = .requestChanges
        let merged = ReviewRequests.merge([pr(1).url: sent], with: fetch([pr(1)]), now: now)
        let row = try XCTUnwrap(merged[pr(1).url])
        XCTAssertEqual(row.stage, .requested)
        XCTAssertTrue(row.unread)
        XCTAssertTrue(row.updated)
        XCTAssertTrue(row.decisions.isEmpty, "a new round starts with fresh decisions")
        XCTAssertNil(row.verdict)
        XCTAssertEqual(row.reviewedSha, "a1", "remembered, so the row stays tracked")
    }

    func testNewCommitsReopenASentReview() throws {
        let records = [pr(1).url: record(pr(1), .sent, reviewed: "a1")]
        let merged = ReviewRequests.merge(records, with: fetch([], tracked: [1: (true, "b2")]), now: now)
        let row = try XCTUnwrap(merged[pr(1).url])
        XCTAssertEqual(row.stage, .requested)
        XCTAssertTrue(row.updated)
        XCTAssertEqual(row.pr.headSha, "b2")
    }

    func testAReopenedRowSurvivesTheNextPoll() {
        var reopened = record(pr(1), .sent, reviewed: "a1")
        reopened.reopen(now: now)
        XCTAssertTrue(ReviewRequests.isTracked(reopened))
        XCTAssertEqual(ReviewRequests.trackedURLs([pr(1).url: reopened]), [pr(1).url])
        let merged = ReviewRequests.merge([pr(1).url: reopened], with: fetch([], tracked: [1: (true, "b2")]), now: now)
        XCTAssertEqual(merged[pr(1).url]?.stage, .requested)
    }

    func testAnUnchangedSentReviewStaysSent() {
        let records = [pr(1).url: record(pr(1), .sent, reviewed: "a1")]
        let merged = ReviewRequests.merge(records, with: fetch([], tracked: [1: (true, "a1")]), now: now)
        XCTAssertEqual(merged[pr(1).url]?.stage, .sent)
    }

    func testARunningReviewKeepsItsStageWhenStillRequested() {
        let records = [pr(1).url: record(pr(1), .reviewing)]
        let merged = ReviewRequests.merge(records, with: fetch([pr(1, sha: "c3")]), now: now)
        XCTAssertEqual(merged[pr(1).url]?.stage, .reviewing)
        XCTAssertEqual(merged[pr(1).url]?.pr.headSha, "c3", "the PR facts follow GitHub")
    }
}

final class ReviewCheckoutTests: XCTestCase {
    private func checkout(_ name: String, trunk: Bool = true, daysAgo: Double? = 1,
                          busy: [ReviewRequests.BusyReason] = []) -> ReviewRequests.Checkout {
        ReviewRequests.Checkout(
            path: "/dev/\(name)", repoRoot: "/dev/\(name)", branch: trunk ? "master" : "feat/x", trunkOrMerged: trunk,
            lastActivity: daysAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 86_400) }, busy: busy)
    }

    func testFreeFirstThenTrunkThenLongestUntouched() {
        let ranked = ReviewRequests.rank([
            checkout("busy", busy: [.agentRunning]),
            checkout("recent", daysAgo: 0.1),
            checkout("feature", trunk: false, daysAgo: 30),
            checkout("old", daysAgo: 6),
        ]).map(\.name)
        XCTAssertEqual(ranked, ["old", "recent", "feature", "busy"])
    }

    func testBusyReasons() {
        let terminals = [
            ReviewRequests.TerminalFact(path: "/dev/dl/packages/a", turnState: .running, backgroundWork: true),
            ReviewRequests.TerminalFact(path: "/dev/dl", turnState: .ready, backgroundWork: true),
            ReviewRequests.TerminalFact(path: "/dev/dl-2", turnState: .waiting, backgroundWork: false),
        ]
        let reasons = ReviewRequests.busyReasons(
            checkout: "/dev/dl", terminals: terminals, uncommitted: 3, devServerPorts: [8082, 8080],
            reviewsRunningHere: [])
        XCTAssertEqual(reasons, [.agentRunning, .backgroundTask, .uncommitted(3), .devServer(8080)])
        XCTAssertFalse(reasons.contains(.waitingForAnswer), "/dev/dl-2 is another checkout, not a subfolder")
    }

    func testABackgroundTaskOfARunningTurnIsNotSaidTwice() {
        let reasons = ReviewRequests.busyReasons(
            checkout: "/dev/dl",
            terminals: [.init(path: "/dev/dl", turnState: .running, backgroundWork: true)],
            uncommitted: 0, devServerPorts: [], reviewsRunningHere: [])
        XCTAssertEqual(reasons, [.agentRunning])
    }

    func testAnUnreadResultKeepsACheckoutBusy() {
        let reasons = ReviewRequests.busyReasons(
            checkout: "/dev/dl",
            terminals: [.init(path: "/dev/dl", turnState: .ready, backgroundWork: false, unreadResult: true)],
            uncommitted: 0, devServerPorts: [], reviewsRunningHere: [])
        XCTAssertEqual(reasons, [.unreadResult])
    }

    func testAnOpenAgentOnAWorkBranchKeepsItBusyButNotOnTheTrunk() {
        let idleAgent = ReviewRequests.TerminalFact(path: "/dev/dl", turnState: .free, backgroundWork: false, agentLive: true)
        XCTAssertEqual(ReviewRequests.busyReasons(
            checkout: "/dev/dl", terminals: [idleAgent], uncommitted: 0, devServerPorts: [],
            reviewsRunningHere: [], onTrunkOrMerged: false), [.agentOnWorkBranch])
        XCTAssertTrue(ReviewRequests.busyReasons(
            checkout: "/dev/dl", terminals: [idleAgent], uncommitted: 0, devServerPorts: [],
            reviewsRunningHere: [], onTrunkOrMerged: true).isEmpty,
            "an idle session on the trunk loses nothing when the review checks out its branch")
    }

    func testACleanIdleCheckoutIsFree() {
        let reasons = ReviewRequests.busyReasons(
            checkout: "/dev/dl", terminals: [.init(path: "/dev/dl", turnState: .free, backgroundWork: false)],
            uncommitted: 0, devServerPorts: [], reviewsRunningHere: [])
        XCTAssertTrue(reasons.isEmpty)
    }

    func testRepoSlugFromRemotes() {
        XCTAssertEqual(ReviewRequests.repoSlug(fromRemote: "git@github.com:myposter-de/designer-library.git\n"),
                       "myposter-de/designer-library")
        XCTAssertEqual(ReviewRequests.repoSlug(fromRemote: "https://github.com/Owner/Repo"), "owner/repo")
        XCTAssertNil(ReviewRequests.repoSlug(fromRemote: "git@gitlab.com:o/r.git"))
    }
}

final class ReviewDecisionTests: XCTestCase {
    private func finding(_ id: String, _ severity: ReviewFindings.Severity, suggestion: String? = nil,
                         decision: ReviewDecision? = nil) -> ReviewFindings.Finding {
        .init(id: id, severity: severity, path: "src/a.ts", line: 4, title: nil, text: "t",
              comment: nil, suggestion: suggestion, decision: decision)
    }

    func testPreselectionTable() {
        XCTAssertEqual(ReviewFindings.preselected(finding("a", .high)), .comment)
        XCTAssertEqual(ReviewFindings.preselected(finding("b", .medium)), .comment)
        XCTAssertEqual(ReviewFindings.preselected(finding("c", .low, suggestion: "x")), .comment)
        XCTAssertEqual(ReviewFindings.preselected(finding("d", .low)), .skip)
        XCTAssertEqual(ReviewFindings.preselected(finding("e", .high, decision: .skip)), .skip,
                       "the skill's own preselection wins")
    }

    func testVerdictFollowsTheDecisions() {
        let all = [finding("h", .high), finding("l", .low)]
        XCTAssertEqual(ReviewFindings.verdict(for: all, decisions: [:]), .requestChanges)
        XCTAssertEqual(ReviewFindings.verdict(for: all, decisions: ["h": .skip, "l": .comment]), .comment)
        XCTAssertEqual(ReviewFindings.verdict(for: all, decisions: ["h": .skip]), .approve)
        XCTAssertEqual(ReviewFindings.verdict(for: [], decisions: [:]), .approve)
    }

    func testMostSevereFirstAndStable() {
        let findings = ReviewFindings(
            version: 1, pr: .init(url: "u", repo: "o/r", number: 1, headSha: nil, headRef: nil),
            checkout: nil, summary: nil,
            findings: [finding("l1", .low), finding("h", .high), finding("l2", .low), finding("m", .medium)])
        XCTAssertEqual(findings.sorted.map(\.id), ["h", "m", "l1", "l2"])
    }

    func testDecodesTheSkillsFile() throws {
        let json = """
        {"version":1,"pr":{"url":"https://github.com/o/r/pull/5","repo":"o/r","number":5,"title":"T",
         "author":"a","headRef":"feat/x","headSha":"abc","baseRef":"master","crossRepository":false},
         "checkout":"/dev/r","temporary":true,"keepCheckout":true,"previousRef":"HEAD",
         "createdAt":"2026-10-29T13:40:00Z","summary":"Fine.",
         "findings":[{"id":"f1","severity":"high","path":"src/useCartTotals.ts","line":41,"startLine":null,
           "inDiff":true,"title":"x","text":"y","comment":"z","suggestion":null,"decision":"comment"}]}
        """
        let findings = try JSONDecoder().decode(ReviewFindings.self, from: Data(json.utf8))
        XCTAssertEqual(findings.pr.headSha, "abc")
        XCTAssertEqual(findings.findings.first?.location, "useCartTotals.ts:41")
        XCTAssertFalse(findings.findings[0].hasSuggestion)
    }

    func testDecisionsFileIsWhatTheSkillReads() throws {
        let file = ReviewDecisionsFile(verdict: .requestChanges, decisions: ["f1": .fix])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any]
        XCTAssertEqual(object?["verdict"] as? String, "REQUEST_CHANGES")
        XCTAssertEqual((object?["decisions"] as? [String: String])?["f1"], "fix")
        XCTAssertEqual(object?["version"] as? Int, 1)
    }
}

final class ReviewCommandTests: XCTestCase {
    private let pr = ReviewPR(
        url: "https://github.com/o/r/pull/9'; rm -rf ~", repo: "o/r", number: 9, title: "", author: "",
        isDraft: false, additions: 0, deletions: 0, changedFiles: 0, headRef: "", headSha: "", baseRef: "",
        checks: .none, updatedAt: nil, requestedFromMe: true, team: nil)

    func testStartCommandIsOneQuotedWord() {
        let command = ReviewRequests.startCommand(
            pr: pr, directory: "/Users/me/Library/Application Support/Planchette/reviews/o-r-9",
            keepCheckout: true, run: ReviewRun())
        XCTAssertTrue(command.hasPrefix("claude '/review-pr "), "no choice, no flag: Claude Code's settings decide")
        XCTAssertTrue(command.contains(#"--dir "/Users/me/Library/Application Support/Planchette/reviews/o-r-9""#))
        XCTAssertTrue(command.contains("--keep-checkout"))
        XCTAssertFalse(command.contains("--checks"))
        XCTAssertTrue(command.contains(#"9'\''; rm -rf ~"#), "a quote in remote text cannot end the word")
    }

    func testModelAndEffortAreFlagsBeforeThePrompt() {
        let command = ReviewRequests.startCommand(
            pr: pr, directory: "/d", keepCheckout: false,
            run: ReviewRun(runChecks: true, model: "claude-opus-5-5", effort: .xhigh))
        XCTAssertTrue(command.hasPrefix("claude --model 'claude-opus-5-5' --effort xhigh '/review-pr "), command)
        XCTAssertTrue(command.hasSuffix(#"--checks'"#))
    }

    func testModelNames() {
        XCTAssertEqual(ReviewRequests.modelName("opus"), "Opus")
        XCTAssertEqual(ReviewRequests.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ReviewRequests.modelName("claude-haiku-5-5-20260601"), "Haiku 5.5", "the date is left out")
        XCTAssertEqual(ReviewRequests.modelName("sonnet[1m]"), "Sonnet 1M")
        XCTAssertEqual(ReviewRequests.modelName("42"), "42", "nothing to name: as written")
    }

    func testClaudeDefaultsComeFromItsSettings() {
        let defaults = ReviewRequests.claudeDefaults(settings: Data(#"{"model":"opus","effortLevel":"high"}"#.utf8))
        XCTAssertEqual(defaults, .init(model: "opus", effort: .high))
        XCTAssertEqual(ReviewRequests.claudeDefaults(settings: Data(#"{"effortLevel":"turbo"}"#.utf8)), .init())
        XCTAssertEqual(ReviewRequests.claudeDefaults(settings: nil), .init(), "no file: nothing known")
    }

    func testSingleQuotedDropsLineBreaks() {
        XCTAssertEqual(Shell.singleQuoted("a\nb'c"), #"'ab'\''c'"#)
    }

    func testReviewDirectoryIsOneSafeSegmentPerPR() {
        let dir = ReviewRequests.reviewDirectory(for: pr, base: URL(fileURLWithPath: "/s"))
        XCTAssertEqual(dir.path, "/s/reviews/o-r-9")
    }
}

final class ReviewPersistenceTests: XCTestCase {
    func testReviewsSurviveASaveAndAStateWithoutThem() throws {
        var record = ReviewRecord(
            pr: ReviewPR(url: "https://github.com/o/r/pull/1", repo: "o/r", number: 1, title: "T", author: "a",
                         isDraft: false, additions: 1, deletions: 1, changedFiles: 1, headRef: "h", headSha: "s",
                         baseRef: "master", checks: .passed, updatedAt: nil, requestedFromMe: true, team: nil),
            stage: .findings, since: Date(timeIntervalSince1970: 100))
        record.decisions = ["f1": .fix]
        let state = PersistedState(
            groups: [], sessions: [], windows: [], aiEnabled: false, language: .en, appearance: .system,
            autoUpdateCheck: true, durableTerminals: false, reviews: [record.id: record])
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.reviews, [record.id: record])

        let old = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertTrue(old.reviews.isEmpty, "a state from before reviews existed decodes")
        XCTAssertFalse(old.reviewsEnabled, "the alpha is off for everybody until they switch it on")
    }

    func testTheAlphaSwitchIsSaved() throws {
        let state = PersistedState(
            groups: [], sessions: [], windows: [], aiEnabled: false, language: .en, appearance: .system,
            autoUpdateCheck: true, durableTerminals: false, reviewsEnabled: true)
        XCTAssertTrue(try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state)).reviewsEnabled)
    }

    func testARecordFromAnOlderBuildDecodes() throws {
        var record = ReviewRecord(
            pr: ReviewPR(url: "https://github.com/o/r/pull/1", repo: "o/r", number: 1, title: "T", author: "a",
                         isDraft: false, additions: 1, deletions: 1, changedFiles: 1, headRef: "h", headSha: "s",
                         baseRef: "master", checks: .passed, updatedAt: nil, requestedFromMe: true, team: nil),
            stage: .requested, since: Date(timeIntervalSince1970: 100))
        record.dismissed = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for key in ["dismissed", "updated", "sending", "decisions"] { object[key] = nil }
        let decoded = try JSONDecoder().decode(ReviewRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.dismissed)
        XCTAssertEqual(decoded.decisions, [:])
        XCTAssertEqual(decoded.pr, record.pr)
        XCTAssertNil(decoded.pr.requestedAt, "a PR saved before the request time existed")
    }
}

final class ReviewSkillTests: XCTestCase {
    private let skill = Data("skill v2".utf8)

    func testPlanTable() {
        let bundled = ["SKILL.md": skill, "scripts/checkouts.py": Data("py".utf8)]
        XCTAssertEqual(ReviewSkill.plan(installed: nil, marker: false, bundled: bundled), .install)
        XCTAssertEqual(ReviewSkill.plan(installed: [:], marker: false, bundled: bundled), .install,
                       "a folder without SKILL.md is not a skill")
        XCTAssertEqual(ReviewSkill.plan(installed: ["SKILL.md": Data("mine".utf8)], marker: false, bundled: bundled),
                       .keepUsersOwn)
        XCTAssertEqual(ReviewSkill.plan(installed: ["SKILL.md": Data("v1".utf8)], marker: true, bundled: bundled), .update)
        XCTAssertEqual(ReviewSkill.plan(installed: bundled, marker: true, bundled: bundled), .upToDate)
        XCTAssertEqual(ReviewSkill.plan(installed: nil, marker: false, bundled: nil), .unavailable)
    }

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-skill-\(UUID().uuidString)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bundle() throws -> URL {
        let source = try folder("bundled")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try skill.write(to: source.appendingPathComponent("SKILL.md"))
        try Data("print(1)".utf8).write(to: source.appendingPathComponent("scripts/checkouts.py"))
        return source
    }

    func testInstallsTheDefaultWithItsMarkerThenKeepsItCurrent() throws {
        let source = try bundle()
        let target = try folder("skills").appendingPathComponent("review-pr")
        XCTAssertEqual(ReviewSkill.ensureInstalled(into: target, from: source, isolated: false), .install)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("SKILL.md")), skill)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(".planchette-default").path))
        let mode = try FileManager.default.attributesOfItem(
            atPath: target.appendingPathComponent("scripts/checkouts.py").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        XCTAssertEqual(ReviewSkill.ensureInstalled(into: target, from: source, isolated: false), .upToDate)

        try Data("skill v3".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(ReviewSkill.ensureInstalled(into: target, from: source, isolated: false), .update)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("SKILL.md")), Data("skill v3".utf8))
    }

    func testNeverTouchesTheUsersOwnSkill() throws {
        let source = try bundle()
        let target = try folder("review-pr")
        let mine = Data("my own review skill".utf8)
        try mine.write(to: target.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(ReviewSkill.ensureInstalled(into: target, from: source, isolated: false), .keepUsersOwn)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("SKILL.md")), mine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".planchette-default").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("scripts").path))
    }

    func testAnIsolatedInstanceWritesNothing() throws {
        let target = try folder("skills").appendingPathComponent("review-pr")
        XCTAssertEqual(ReviewSkill.ensureInstalled(into: target, from: try bundle(), isolated: true), .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testTheRepositoryShipsTheDefault() throws {
        let shipped = try XCTUnwrap(ReviewSkill.bundledFolder, "skills/review-pr is missing")
        let files = try XCTUnwrap(ReviewSkill.files(in: shipped))
        let text = String(decoding: try XCTUnwrap(files["SKILL.md"]), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("---\nname: review-pr\n"))
        for contract in ["findings.json", "decisions.json", "sent.json", "--keep-checkout", "submit"] {
            XCTAssertTrue(text.contains(contract), "the default skill must speak the panel's contract: \(contract)")
        }
        XCTAssertNotNil(files["scripts/checkouts.py"])
    }
}

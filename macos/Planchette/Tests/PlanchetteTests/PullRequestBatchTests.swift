import XCTest
import os
@testable import Planchette

// The batched PR lookup must give every checkout the answer its own `gh pr list` gives.
// The repository is gh's own answer (`gh repo view`), cached per checkout root.

private func repo(_ owner: String, _ name: String) -> GitHubRepo { GitHubRepo(owner: owner, name: name) }

private func output(_ text: String, status: Int32 = 0, timedOut: Bool = false) -> Subprocess.Output {
    Subprocess.Output(status: status, stdout: Data(text.utf8), stderr: Data(), timedOut: timedOut)
}

extension PullRequestBatch {
    /// The answers of a call, nil for any other outcome.
    static func parse(_ data: Data, count: Int) -> [Int: PullRequests.Lookup]? {
        if case .answered(let answers) = outcome(stdout: data, timedOut: false, count: count) { return answers }
        return nil
    }
}

/// git for a fixture, deaf to the user's own config: no global or system file, no signing,
/// no hooks.
@discardableResult
private func isolatedGit(_ arguments: [String], in directory: String) throws -> String {
    let result = try XCTUnwrap(Subprocess.run(
        "/usr/bin/env",
        ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "git",
         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments,
        in: directory, timeout: 300, stderr: .capture))
    XCTAssertTrue(result.succeeded, "git \(arguments): \(result.stderrString)")
    return result.stdoutString
}

// MARK: - The repository gh names

final class RepoAnswerTests: XCTestCase {
    func testWhatGhRepoViewSays() {
        let cases: [(Subprocess.Output?, RepoAnswer)] = [
            (output(#"{"nameWithOwner":"cli/cli","url":"https://github.com/cli/cli"}"#), .github(repo("cli", "cli"))),
            (output(#"{"url":"https://GitHub.com/Octo/Hello","nameWithOwner":"Octo/Hello"}"#), .github(repo("Octo", "Hello"))),
            (output(#"{"nameWithOwner":"a/b","url":"https://ghe.example.com/a/b"}"#), .elsewhere(host: "ghe.example.com")),
            (output(#"{"nameWithOwner":"a/b","url":"https://octo.ghe.com/a/b"}"#), .elsewhere(host: "octo.ghe.com")),
            (output("", status: 1), .failed("gh repo view failed")),
            (output(#"{"nameWithOwner":"a/b","url":"https://github.com/a/b"}"#, status: -1, timedOut: true),
             .failed("gh repo view timed out")),
            (nil, .failed("gh repo view could not start")),
            (output("not json"), .failed("gh repo view gave an unreadable answer")),
            (output(#"{"nameWithOwner":"a/b"}"#), .failed("gh repo view gave an unreadable answer")),
            (output(#"{"nameWithOwner":"a/b/c","url":"https://github.com/a/b"}"#), .failed("gh repo view gave an unreadable answer")),
            (output(#"{"nameWithOwner":"/b","url":"https://github.com/a/b"}"#), .failed("gh repo view gave an unreadable answer")),
        ]
        for (given, expected) in cases {
            XCTAssertEqual(RepoAnswer.from(given), expected, given?.stdoutString ?? "nil")
        }
        XCTAssertEqual(RepoAnswer.arguments, ["repo", "view", "--json", "nameWithOwner,url"])
    }

    func testLifetimes() {
        XCTAssertEqual(RepoAnswer.github(repo("a", "b")).lifetime, 24 * 60 * 60)
        XCTAssertEqual(RepoAnswer.elsewhere(host: "x").lifetime, 24 * 60 * 60)
        XCTAssertEqual(RepoAnswer.failed("x").lifetime, 10 * 60)
    }
}

// MARK: - The cache

final class RepoCacheTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-repocache-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = (root as NSString).resolvingSymlinksInPath
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let full = "\(root)/\(path)"
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    private func stamp(_ n: Int) -> FileStamp { FileStamp(device: 1, inode: UInt64(n), size: 10, seconds: n, nanoseconds: n) }

    func testAnAnswerStandsWhileEveryStampDoes() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let stamps: [FileStamp?] = [stamp(1), nil, stamp(3), stamp(4)]
        var cache = RepoCache()
        XCTAssertNil(cache.answer(root: "/r", stamps: stamps, now: t0))
        cache.store(root: "/r", answer: .github(repo("a", "b")), stamps: stamps, at: t0)
        XCTAssertEqual(cache.answer(root: "/r", stamps: stamps, now: t0 + 60), .github(repo("a", "b")))
        XCTAssertNil(cache.answer(root: "/other", stamps: stamps, now: t0 + 60))
        for position in stamps.indices {
            var changed = stamps
            changed[position] = stamps[position] == nil ? stamp(9) : nil     // created or deleted
            XCTAssertNil(cache.answer(root: "/r", stamps: changed, now: t0 + 60), "file \(position) appeared or went")
            changed[position] = stamp(99)                                      // rewritten
            XCTAssertNil(cache.answer(root: "/r", stamps: changed, now: t0 + 60), "file \(position) changed")
        }
    }

    func testLifetimeOfAnAnswerAndOfAFailure() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var cache = RepoCache()
        cache.store(root: "/ok", answer: .github(repo("a", "b")), stamps: [], at: t0)
        cache.store(root: "/ghe", answer: .elsewhere(host: "ghe"), stamps: [], at: t0)
        cache.store(root: "/bad", answer: .failed("x"), stamps: [], at: t0)
        XCTAssertNotNil(cache.answer(root: "/ok", stamps: [], now: t0 + 24 * 3600 - 1))
        XCTAssertNil(cache.answer(root: "/ok", stamps: [], now: t0 + 24 * 3600))
        XCTAssertNotNil(cache.answer(root: "/ghe", stamps: [], now: t0 + 24 * 3600 - 1))
        XCTAssertNil(cache.answer(root: "/ghe", stamps: [], now: t0 + 24 * 3600))
        XCTAssertNotNil(cache.answer(root: "/bad", stamps: [], now: t0 + 599))
        XCTAssertNil(cache.answer(root: "/bad", stamps: [], now: t0 + 600))
        // A clock that went back is no reason to trust an old answer.
        XCTAssertNil(cache.answer(root: "/ok", stamps: [], now: t0 - 1))
    }

    func testTheStampedFiles() throws {
        try write("main/.git/config", "")
        try write("main/.git/worktrees/wt/commondir", "../..\n")
        try write("wt/.git", "gitdir: \(root)/main/.git/worktrees/wt\n")
        let files = RepoCache.stampedFiles(root: "\(root)/wt", environment: [:], home: "/h")
        XCTAssertEqual(files, [
            "\(root)/wt/.git",
            "\(root)/main/.git/config",
            "\(root)/main/.git/worktrees/wt/config.worktree",
            "/h/.config/git/config", "/h/.gitconfig", "/h/.ssh/config",
            "/h/.config/gh/hosts.yml", "/h/.config/gh/config.yml",
        ])
        XCTAssertEqual(Array(RepoCache.stampedFiles(root: "\(root)/main", environment: ["XDG_CONFIG_HOME": "/x"], home: "/h")),
                       ["\(root)/main/.git", "\(root)/main/.git/config", "\(root)/main/.git/config.worktree",
                        "/x/git/config", "/h/.gitconfig", "/h/.ssh/config", "/x/gh/hosts.yml", "/x/gh/config.yml"])
        XCTAssertEqual(Array(RepoCache.stampedFiles(root: "\(root)/main", environment: ["GH_CONFIG_DIR": "/g"], home: "/h")
                                .suffix(2)), ["/g/hosts.yml", "/g/config.yml"])
        // No git dir to read: the `.git` entry and the user's files still count.
        XCTAssertEqual(RepoCache.stampedFiles(root: "\(root)/none", environment: [:], home: "/h").first, "\(root)/none/.git")
    }

    func testGitDirs() throws {
        try write("plain/.git/config", "")
        XCTAssertEqual(RepoCache.gitDirs(checkoutRoot: "\(root)/plain"),
                       .init(gitDir: "\(root)/plain/.git", commonDir: "\(root)/plain/.git"))
        try write("store/worktrees/wt/commondir", "\(root)/store\n")
        try write("wt/.git", "gitdir: ../store/worktrees/wt")
        XCTAssertEqual(RepoCache.gitDirs(checkoutRoot: "\(root)/wt"),
                       .init(gitDir: "\(root)/store/worktrees/wt", commonDir: "\(root)/store"))
        try write("super/.git/modules/sub/config", "")
        try write("super/sub/.git", "gitdir: ../.git/modules/sub\n")
        XCTAssertEqual(RepoCache.gitDirs(checkoutRoot: "\(root)/super/sub"),
                       .init(gitDir: "\(root)/super/.git/modules/sub", commonDir: "\(root)/super/.git/modules/sub"))
        try write("broken/.git", "not a gitdir line\n")
        XCTAssertNil(RepoCache.gitDirs(checkoutRoot: "\(root)/broken"))
        XCTAssertNil(RepoCache.gitDirs(checkoutRoot: "\(root)/missing"))
    }

    /// The layout git itself writes: a linked worktree's stamps include the main config,
    /// and a remote added there changes the stamp the worktree's answer depends on.
    func testARealWorktreeSeesTheCommonConfigChange() throws {
        let main = "\(root)/real"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try isolatedGit(["init", "-q", "-b", "main"], in: main)
        try isolatedGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"], in: main)
        try isolatedGit(["worktree", "add", "-q", "-b", "feature", "\(root)/linked"], in: main)
        let files = RepoCache.stampedFiles(root: "\(root)/linked", environment: [:], home: "/nonexistent")
        XCTAssertTrue(files.contains("\(main)/.git/config"), "\(files)")
        let before = files.map(FileStamp.of)
        try isolatedGit(["remote", "add", "upstream", "https://github.com/a/b.git"], in: main)
        XCTAssertNotEqual(files.map(FileStamp.of), before)
    }
}

// MARK: - The query

final class PullRequestBatchQueryTests: XCTestCase {
    private let nasty = [
        PullRequestBatch.Request(repo: repo("o", "n"), branch: "plain"),
        PullRequestBatch.Request(repo: repo("we\"ird", "na\\me"), branch: "a\"b\\c\nd"),
        PullRequestBatch.Request(repo: repo("ü", "日本"), branch: "feat/emoji-🚀-ünï"),
        PullRequestBatch.Request(repo: repo("o", "n"), branch: "$b0 ) { evil } #"),
    ]

    func testTheQueryNamesEveryAliasAndNoValue() {
        let query = PullRequestBatch.query(count: 3)
        for index in 0..<3 {
            XCTAssertTrue(query.contains("r\(index): repository(owner: $o\(index), name: $n\(index))"), query)
            XCTAssertTrue(query.contains("pullRequests(headRefName: $b\(index), first: \(PullRequests.lookupLimit), "
                + "states: [OPEN, MERGED, CLOSED], orderBy: {field: CREATED_AT, direction: DESC})"), query)
            XCTAssertTrue(query.contains("$o\(index): String!, $n\(index): String!, $b\(index): String!"), query)
        }
        XCTAssertFalse(query.contains("r3:"))
        XCTAssertTrue(query.contains("nodes { number state isDraft reviewDecision url title }"))
        // The batch asks for exactly what `gh pr list --json` is asked for.
        XCTAssertEqual(PullRequestBatch.nodeFields.split(separator: " ").joined(separator: ","), PullRequests.jsonFields)
        XCTAssertEqual(query.filter { $0 == "{" }.count, query.filter { $0 == "}" }.count)
        XCTAssertEqual(query.filter { $0 == "(" }.count, query.filter { $0 == ")" }.count)
    }

    func testValuesTravelAsVariablesUnchanged() throws {
        let body = PullRequestBatch.body(for: nasty)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try XCTUnwrap(object["query"] as? String)
        XCTAssertEqual(query, PullRequestBatch.query(count: nasty.count))
        let variables = try XCTUnwrap(object["variables"] as? [String: String])
        XCTAssertEqual(variables.count, nasty.count * 3)
        for (index, request) in nasty.enumerated() {
            XCTAssertEqual(variables["o\(index)"], request.repo.owner)
            XCTAssertEqual(variables["n\(index)"], request.repo.name)
            XCTAssertEqual(variables["b\(index)"], request.branch)
            XCTAssertFalse(query.contains(request.branch), "the branch must not be in the query text")
        }
        XCTAssertFalse(query.contains("we\"ird") || query.contains("日本") || query.contains("evil"))
    }

    func testTheBodyIsStable() {
        XCTAssertEqual(PullRequestBatch.body(for: nasty), PullRequestBatch.body(for: nasty))
    }
}

// MARK: - The answer

final class PullRequestBatchParseTests: XCTestCase {
    private func parse(_ json: String, count: Int) -> [Int: PullRequests.Lookup]? {
        PullRequestBatch.parse(Data(json.utf8), count: count)
    }

    private func node(_ number: Int, _ state: String, draft: Bool = false, review: String? = nil) -> String {
        let reviewJSON = review.map { "\"\($0)\"" } ?? "null"
        return #"{"number":\#(number),"state":"\#(state)","isDraft":\#(draft),"reviewDecision":\#(reviewJSON),"url":"https://github.com/o/n/pull/\#(number)","title":"PR \#(number)"}"#
    }

    private func pr(_ number: Int, _ status: PullRequest.Status, review: PullRequest.Review? = nil) -> PullRequests.Lookup {
        .found(PullRequest(number: number, status: status, review: review,
                           url: URL(string: "https://github.com/o/n/pull/\(number)")!, title: "PR \(number)"))
    }

    func testEveryAliasAnswered() {
        let json = """
        {"data":{
          "r0":{"pullRequests":{"nodes":[\(node(3, "CLOSED")),\(node(2, "OPEN", review: "APPROVED"))]}},
          "r1":{"pullRequests":{"nodes":[]}},
          "r2":{"pullRequests":{"nodes":[\(node(9, "OPEN", draft: true, review: "CHANGES_REQUESTED"))]}},
          "r3":{"pullRequests":{"nodes":[\(node(7, "MERGED", review: "APPROVED")),\(node(5, "CLOSED"))]}}
        }}
        """
        XCTAssertEqual(parse(json, count: 4), [
            0: pr(2, .open, review: .approved),   // an open PR wins over a newer closed one
            1: PullRequests.Lookup.none,
            2: pr(9, .draft),                      // no review for a draft, as `parse` does
            3: pr(7, .merged),                     // else the newest; a decided PR has no review
        ])
    }

    func testAnAliasWithAnErrorIsLeftOut() {
        let json = """
        {"data":{"r0":{"pullRequests":{"nodes":[\(node(1, "OPEN"))]}},"r1":null,
                 "r2":{"pullRequests":{"nodes":[null,\(node(4, "OPEN"))]}}},
         "errors":[{"type":"NOT_FOUND","path":["r1"],"message":"Could not resolve to a Repository"},
                   {"type":"FORBIDDEN","path":["r2","pullRequests","nodes",0],"message":"no"}]}
        """
        // r2 has data, but an error inside it: its answer is not trusted.
        XCTAssertEqual(parse(json, count: 3), [0: pr(1, .open)])
    }

    func testANullOrMisshapenAliasIsLeftOut() {
        let json = """
        {"data":{"r0":null,"r1":{"pullRequests":null},"r2":{"pullRequests":{}},"r3":{},
                 "r4":{"pullRequests":{"nodes":"x"}},"r6":{"pullRequests":{"nodes":[]}}}}
        """
        XCTAssertEqual(parse(json, count: 7), [6: PullRequests.Lookup.none])
    }

    func testANodeWithoutItsFieldsIsSkippedAsParseSkipsIt() {
        let json = """
        {"data":{"r0":{"pullRequests":{"nodes":[{"number":8,"state":"OPEN"},{"number":"x","state":"OPEN","url":"u"},
          {"number":7,"state":"WEIRD","url":"https://github.com/o/n/pull/7"},\(node(6, "MERGED"))]}}}}
        """
        XCTAssertEqual(parse(json, count: 1), [0: pr(6, .merged)])
    }

    /// Without a `data` object no alias can be answered, and asking each checkout alone
    /// would hit the same token and the same limit: the call's checkouts fail.
    func testAnAnswerWithoutDataIsUnreachable() {
        for json in [
            "", "not json", "<html>502 Bad Gateway</html>", "[]", "{}", #"{"data":null}"#,
            #"{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}"#,
            #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#,
            #"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits","status":"403"}"#,
            #"{"data":{"r0":null},"errors":[{"message":"an error without a path"}]}"#,
            #"{"data":{"r0":null},"errors":[{"path":[]}]}"#,
        ] {
            XCTAssertEqual(PullRequestBatch.outcome(stdout: Data(json.utf8), timedOut: false, count: 1), .unreachable, json)
        }
    }

    func testADataObjectOfTheWrongShapeIsNotUnderstood() {
        for json in [#"{"data":[]}"#, #"{"data":"x"}"#, #"{"data":{"r0":null},"errors":{"path":["r0"]}}"#] {
            XCTAssertEqual(PullRequestBatch.outcome(stdout: Data(json.utf8), timedOut: false, count: 1), .notUnderstood, json)
        }
        XCTAssertEqual(parse(#"{"data":{"r0":{"pullRequests":{"nodes":[]}}},"errors":null}"#, count: 1),
                       [0: PullRequests.Lookup.none])
    }

    func testTheOutcomeOfACall() {
        let answer = Data(#"{"data":{"r0":{"pullRequests":{"nodes":[]}},"r1":null},"errors":[{"path":["r1"]}]}"#.utf8)
        // gh exits 1 when an alias has an error, and still prints the answer.
        XCTAssertEqual(PullRequestBatch.outcome(stdout: answer, timedOut: false, count: 2),
                       .answered([0: PullRequests.Lookup.none]))
        XCTAssertEqual(PullRequestBatch.outcome(stdout: answer, timedOut: true, count: 2), .unreachable)
    }
}

// MARK: - gh pr list and the batch agree

final class PullRequestBatchEquivalenceTests: XCTestCase {
    /// Recorded on 2026-11-27 with gh 2.106: `gh pr list --head <branch> --state all --limit 5
    /// --json number,state,isDraft,reviewDecision,url,title` per branch, and one batch of the
    /// same five through `gh api graphql` (the query `PullRequestBatch.query` builds).
    private let recordedLists = [
        #"[{"isDraft":false,"number":15005,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"fix: handle nil values in nested array field parsing","url":"https://github.com/cli/cli/pull/15005"},{"isDraft":false,"number":14872,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Remove memory.md and SECURITY.md files","url":"https://github.com/cli/cli/pull/14872"},{"isDraft":false,"number":14481,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Authorship and follow-up","url":"https://github.com/cli/cli/pull/14481"},{"isDraft":false,"number":14471,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Create generator-generic-ossf-slsa3-publish.yml","url":"https://github.com/cli/cli/pull/14471"},{"isDraft":false,"number":14310,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Support forced pinned extension installations","url":"https://github.com/cli/cli/pull/14310"}]"#,
        #"[{"isDraft":true,"number":15128,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Add owner information to config documentation","url":"https://github.com/cli/cli/pull/15128"},{"isDraft":false,"number":15003,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Create READ ME","url":"https://github.com/cli/cli/pull/15003"},{"isDraft":false,"number":14873,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Update install_linux.md","url":"https://github.com/cli/cli/pull/14873"},{"isDraft":false,"number":14664,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Update snap installation instructions","url":"https://github.com/cli/cli/pull/14664"},{"isDraft":true,"number":14575,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Rename SECURITY.md to SECURITY.mdbrew install gh","url":"https://github.com/cli/cli/pull/14575"}]"#,
        #"[{"isDraft":false,"number":66,"reviewDecision":"","state":"OPEN","title":"perf: a performance pass over polls, terminals, AI summaries and PR lookups","url":"https://github.com/marcello-a/Planchette/pull/66"}]"#,
        #"[{"isDraft":false,"number":65,"reviewDecision":"","state":"MERGED","title":"fix: review of the unreleased changes before 0.2.56","url":"https://github.com/marcello-a/Planchette/pull/65"}]"#,
        "[]",
    ]

    private let recordedBatch = #"""
    {"data":{"r0":{"pullRequests":{"nodes":[{"number":15005,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/15005","title":"fix: handle nil values in nested array field parsing"},{"number":14872,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14872","title":"Remove memory.md and SECURITY.md files"},{"number":14481,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14481","title":"Authorship and follow-up"},{"number":14471,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14471","title":"Create generator-generic-ossf-slsa3-publish.yml"},{"number":14310,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14310","title":"Support forced pinned extension installations"}]}},"r1":{"pullRequests":{"nodes":[{"number":15128,"state":"CLOSED","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/15128","title":"Add owner information to config documentation"},{"number":15003,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/15003","title":"Create READ ME"},{"number":14873,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14873","title":"Update install_linux.md"},{"number":14664,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14664","title":"Update snap installation instructions"},{"number":14575,"state":"CLOSED","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14575","title":"Rename SECURITY.md to SECURITY.mdbrew install gh"}]}},"r2":{"pullRequests":{"nodes":[{"number":66,"state":"OPEN","isDraft":false,"reviewDecision":null,"url":"https://github.com/marcello-a/Planchette/pull/66","title":"perf: a performance pass over polls, terminals, AI summaries and PR lookups"}]}},"r3":{"pullRequests":{"nodes":[{"number":65,"state":"MERGED","isDraft":false,"reviewDecision":null,"url":"https://github.com/marcello-a/Planchette/pull/65","title":"fix: review of the unreleased changes before 0.2.56"}]}},"r4":{"pullRequests":{"nodes":[]}}}}
    """#

    private func single(_ json: String) -> PullRequests.Lookup {
        PullRequests.parse(Data(json.utf8)).map(PullRequests.Lookup.found) ?? .none
    }

    func testRecordedAnswersAgree() throws {
        let batch = try XCTUnwrap(PullRequestBatch.parse(Data(recordedBatch.utf8), count: recordedLists.count))
        XCTAssertEqual(batch.count, recordedLists.count)
        for (index, list) in recordedLists.enumerated() {
            XCTAssertEqual(batch[index], single(list), "branch \(index)")
        }
        guard case .found(let open) = batch[2] else { return XCTFail("PR 66") }
        XCTAssertEqual(open.number, 66)
        XCTAssertEqual(open.status, .open)
        XCTAssertNil(open.review)
    }

    /// The same PRs rendered both ways — gh's list (`reviewDecision` "" for none, keys
    /// sorted) and GraphQL nodes (null) — for every mix of states, drafts and reviews a
    /// seeded generator makes: both parsers pick the same PR, every time.
    func testGeneratedAnswersAgree() throws {
        var generator = SeededGenerator(seed: 0x9E3779B97F4A7C15)
        let states = ["OPEN", "MERGED", "CLOSED"]
        let reviews: [String?] = [nil, "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"]
        var lists: [String] = []
        var nodes: [String] = []
        for _ in 0..<300 {
            let count = Int(generator.next() % 6)
            var listItems: [String] = []
            var nodeItems: [String] = []
            for position in 0..<count {
                let number = 1000 - position * 7 - Int(generator.next() % 5)
                let state = states[Int(generator.next() % 3)]
                let draft = generator.next() % 4 == 0
                let review = reviews[Int(generator.next() % 4)]
                let title = "PR \(number) \"quoted\" ü"
                let titleJSON = String(decoding: try JSONSerialization.data(withJSONObject: [title]), as: UTF8.self)
                    .dropFirst().dropLast()
                let url = "https://github.com/o/n/pull/\(number)"
                listItems.append(#"{"isDraft":\#(draft),"number":\#(number),"reviewDecision":"\#(review ?? "")","state":"\#(state)","title":\#(titleJSON),"url":"\#(url)"}"#)
                nodeItems.append(#"{"number":\#(number),"state":"\#(state)","isDraft":\#(draft),"reviewDecision":\#(review.map { "\"\($0)\"" } ?? "null"),"url":"\#(url)","title":\#(titleJSON)}"#)
            }
            lists.append("[" + listItems.joined(separator: ",") + "]")
            nodes.append("[" + nodeItems.joined(separator: ",") + "]")
        }
        let aliases = nodes.enumerated().map { #""r\#($0.offset)":{"pullRequests":{"nodes":\#($0.element)}}"# }
        let batch = try XCTUnwrap(PullRequestBatch.parse(Data(("{\"data\":{" + aliases.joined(separator: ",") + "}}").utf8),
                                                         count: lists.count))
        for (index, list) in lists.enumerated() {
            XCTAssertEqual(batch[index], single(list), list)
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - The sweep

/// A stand-in for `gh`: answers `repo view`, `pr list` and `api graphql` as told, and counts
/// every process the sweep starts (and how many run at once).
private final class FakeGh: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(arguments: [String], directory: String?)] = []
    private var running = 0
    private(set) var mostAtOnce = 0
    var delay: useconds_t = 0

    /// The repository per root; a root not named here fails.
    var repoView: (String) -> Subprocess.Output? = { _ in output("", status: 1) }
    /// `gh pr list` per branch: a PR titled with the branch.
    var prList: (String) -> Subprocess.Output? = { branch in
        output(#"[{"isDraft":false,"number":1,"reviewDecision":"","state":"OPEN","title":"\#(branch)","url":"https://github.com/o/n/pull/1"}]"#)
    }
    /// `gh api graphql`: by default each alias answers with a PR titled with its branch.
    var graphQL: (Data) -> Subprocess.Output? = { body in output(FakeGh.answerEveryAlias(body)) }

    static func answerEveryAlias(_ body: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let variables = object?["variables"] as? [String: String] ?? [:]
        let aliases = (0..<(variables.count / 3)).map { index in
            #""r\#(index)":{"pullRequests":{"nodes":[{"number":1,"state":"OPEN","isDraft":false,"reviewDecision":null,"url":"https://github.com/o/n/pull/1","title":"\#(variables["b\(index)"] ?? "")"}]}}"#
        }
        return #"{"data":{"# + aliases.joined(separator: ",") + "}}"
    }

    func run(_ arguments: [String], _ directory: String?, _ input: Data?) -> Subprocess.Output? {
        lock.withLock {
            calls.append((arguments, directory))
            running += 1
            mostAtOnce = max(mostAtOnce, running)
        }
        if delay > 0 { usleep(delay) }
        defer { lock.withLock { running -= 1 } }
        switch Array(arguments.prefix(2)) {
        case ["repo", "view"]: return repoView(directory ?? "")
        case ["pr", "list"]: return prList(arguments[3])
        case ["api", "graphql"]: return graphQL(input ?? Data())
        default: XCTFail("unexpected gh \(arguments)"); return nil
        }
    }

    func count(_ command: String) -> Int {
        lock.withLock { calls.filter { $0.arguments.prefix(2).joined(separator: " ") == command }.count }
    }

    func reset() { lock.withLock { calls = []; mostAtOnce = 0 } }
}

final class PullRequestBatchSweepTests: XCTestCase {
    private var gh = FakeGh()
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var stamps: [String: FileStamp] = [:]
    private var environment: [String: String] = [:]
    private var cache = OSAllocatedUnfairLock(initialState: RepoCache())

    override func setUp() {
        gh = FakeGh()
        gh.repoView = { root in
            output(#"{"nameWithOwner":"o/\#((root as NSString).lastPathComponent)","url":"https://github.com/o/\#((root as NSString).lastPathComponent)"}"#)
        }
    }

    private func checkout(_ index: Int, root: String? = nil, branch: String? = nil) -> PullRequests.Checkout {
        PullRequests.Checkout(directory: "/work/r\(index)/sub", branch: branch ?? "feature-\(index)", ids: [UUID()],
                              root: root ?? "/work/r\(index)")
    }

    private func sweep(_ checkouts: [PullRequests.Checkout]) -> [PullRequests.Lookup] {
        let context = PullRequests.SweepContext(
            run: { [gh] in gh.run($0, $1, $2) }, now: { [now] in now },
            stamp: { [stamps] in stamps[$0] ?? FileStamp(device: 1, inode: 1, size: 1, seconds: 1, nanoseconds: 1) },
            environment: environment, home: "/home")
        return PullRequests.lookup(checkouts, context: context, cache: cache)
    }

    private func titles(_ lookups: [PullRequests.Lookup]) -> [String?] {
        lookups.map { if case .found(let pr) = $0 { return pr.title }; return nil }
    }

    func testANewRootIsAnsweredAloneOnceThenBatched() {
        let checkouts = (0..<3).map { checkout($0) }
        // The first sweep: gh pr list each, and gh repo view each root beside it.
        XCTAssertEqual(titles(sweep(checkouts)), ["feature-0", "feature-1", "feature-2"])
        XCTAssertEqual(gh.count("pr list"), 3)
        XCTAssertEqual(gh.count("repo view"), 3)
        XCTAssertEqual(gh.count("api graphql"), 0)
        XCTAssertEqual(Set(gh.calls.filter { $0.arguments.first == "repo" }.compactMap(\.directory)),
                       ["/work/r0", "/work/r1", "/work/r2"], "gh repo view runs in the checkout's root")
        // From then on: one call.
        gh.reset()
        XCTAssertEqual(titles(sweep(checkouts)), ["feature-0", "feature-1", "feature-2"])
        XCTAssertEqual(gh.calls.count, 1)
        XCTAssertEqual(gh.count("api graphql"), 1)
    }

    func testEveryStampedFileThatChangesAsksGhAgain() throws {
        // A real git dir, so the repository's `config` and `config.worktree` are among the files.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("planchette-sweep-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let one = [checkout(0, root: root)]
        let files = RepoCache.stampedFiles(root: root, environment: environment, home: "/home")
        XCTAssertEqual(files.count, 8)
        XCTAssertTrue(files.contains(root + "/.git/config") && files.contains(root + "/.git/config.worktree"))
        _ = sweep(one)
        for file in files {
            gh.reset()
            _ = sweep(one)
            XCTAssertEqual(gh.count("repo view"), 0, "nothing changed before \(file)")
            stamps[file] = FileStamp(device: 1, inode: 2, size: 1, seconds: 1, nanoseconds: 1)
            gh.reset()
            _ = sweep(one)
            XCTAssertEqual(gh.count("repo view"), 1, "\(file) changed")
            XCTAssertEqual(gh.count("pr list"), 1, "\(file) changed: answered alone meanwhile")
        }
    }

    func testAnAnswerExpiresAfterADay() {
        let one = [checkout(0)]
        _ = sweep(one)
        now += 24 * 3600 - 1
        gh.reset()
        _ = sweep(one)
        XCTAssertEqual(gh.count("repo view"), 0)
        now += 1
        gh.reset()
        _ = sweep(one)
        XCTAssertEqual(gh.count("repo view"), 1)
    }

    func testAFailureIsKeptForTenMinutes() {
        gh.repoView = { _ in output("", status: 1) }
        let one = [checkout(0)]
        XCTAssertEqual(titles(sweep(one)), ["feature-0"])
        now += 599
        gh.reset()
        XCTAssertEqual(titles(sweep(one)), ["feature-0"])
        XCTAssertEqual(gh.count("repo view"), 0, "a failure is not asked again on every sweep")
        XCTAssertEqual(gh.count("pr list"), 1, "but the checkout is still looked up alone")
        now += 1
        gh.reset()
        _ = sweep(one)
        XCTAssertEqual(gh.count("repo view"), 1)
    }

    func testAnotherHostStaysAlone() {
        gh.repoView = { _ in output(#"{"nameWithOwner":"o/n","url":"https://ghe.example.com/o/n"}"#) }
        let one = [checkout(0)]
        _ = sweep(one)
        now += 3600
        gh.reset()
        XCTAssertEqual(titles(sweep(one)), ["feature-0"])
        XCTAssertEqual(gh.count("api graphql"), 0)
        XCTAssertEqual(gh.count("repo view"), 0, "a GHE answer is kept like any other")
        XCTAssertEqual(gh.count("pr list"), 1)
    }

    func testARepoViewThatFailsOrHangsFallsBackOnlyForItsCheckout() {
        let checkouts = (0..<4).map { checkout($0) }
        _ = sweep(Array(checkouts.prefix(2)))
        gh.repoView = { root in
            root == "/work/r2" ? output("", status: -1, timedOut: true)
                : root == "/work/r3" ? output("", status: 1) : nil
        }
        gh.reset()
        XCTAssertEqual(titles(sweep(checkouts)), ["feature-0", "feature-1", "feature-2", "feature-3"])
        gh.reset()
        XCTAssertEqual(titles(sweep(checkouts)), ["feature-0", "feature-1", "feature-2", "feature-3"])
        XCTAssertEqual(gh.count("api graphql"), 1)
        XCTAssertEqual(gh.calls.filter { $0.arguments.prefix(2) == ["pr", "list"] }.map { $0.arguments[3] }.sorted(),
                       ["feature-2", "feature-3"])
        XCTAssertEqual(gh.count("repo view"), 0)
    }

    func testAtMostFourAtOnce() {
        gh.delay = 30_000
        let checkouts = (0..<12).map { checkout($0) }
        XCTAssertEqual(titles(sweep(checkouts)), (0..<12).map { "feature-\($0)" })
        XCTAssertEqual(gh.calls.count, 24, "a pr list and a repo view per new root")
        XCTAssertLessThanOrEqual(gh.mostAtOnce, 4)
        XCTAssertGreaterThan(gh.mostAtOnce, 1, "the new roots are asked side by side")
    }

    func testACallWithoutDataFailsItsCheckoutsWithNoMoreProcesses() {
        let checkouts = (0..<25).map { checkout($0) }
        _ = sweep(checkouts)
        for answer in [
            output(#"{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}"#, status: 1),
            output(#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#, status: 1),
            output(#"{"message":"You have exceeded a secondary rate limit.","status":"403"}"#, status: 1),
            output(#"{"data":{"r0":null},"errors":[{"message":"Something went wrong"}]}"#, status: 1),
            output("", status: 1),
            output("", status: -1, timedOut: true),
        ] {
            gh.graphQL = { _ in answer }
            gh.reset()
            XCTAssertEqual(sweep(checkouts), Array(repeating: .failed, count: 25), answer.stdoutString)
            XCTAssertEqual(gh.calls.count, 2, "two calls of the batch, nothing alone: \(answer.stdoutString)")
        }
    }

    func testADataObjectNotUnderstoodIsAskedAlone() {
        let checkouts = (0..<25).map { checkout($0) }
        _ = sweep(checkouts)
        // The two calls run side by side: the call of 20 gets the answer this does not read.
        gh.graphQL = { body in
            let variables = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["variables"] as? [String: String]
            return variables?.count == 60 ? output(#"{"data":[]}"#) : output(FakeGh.answerEveryAlias(body))
        }
        gh.reset()
        XCTAssertEqual(titles(sweep(checkouts)), (0..<25).map { "feature-\($0)" })
        XCTAssertEqual(gh.count("api graphql"), 2)
        XCTAssertEqual(gh.count("pr list"), 20, "only the first call's checkouts")
    }

    func testAnAliasWithAnErrorIsAskedAloneAndOnlyIt() {
        let checkouts = (0..<4).map { checkout($0) }
        _ = sweep(checkouts)
        gh.graphQL = { body in
            let all = FakeGh.answerEveryAlias(body)
            // r1's repository is gone: null, with an error that names it (gh then exits 1).
            let others = all.replacingOccurrences(of: #""r1":{"pullRequests"#, with: #""r1x":{"pullRequests"#)
            return output(String(others.dropLast(2)) + #","r1":null},"errors":[{"type":"NOT_FOUND","path":["r1"]}]}"#,
                          status: 1)
        }
        gh.reset()
        XCTAssertEqual(titles(sweep(checkouts)), (0..<4).map { "feature-\($0)" })
        XCTAssertEqual(gh.calls.filter { $0.arguments.prefix(2) == ["pr", "list"] }.map { $0.arguments[3] }, ["feature-1"])
    }

    func testCallsOfTheCapEachAnswerTheirOwnCheckouts() throws {
        let checkouts = (0..<45).map { checkout($0) }
        _ = sweep(checkouts)
        gh.reset()
        XCTAssertEqual(titles(sweep(checkouts)), (0..<45).map { "feature-\($0)" })
        XCTAssertEqual(gh.count("api graphql"), 3)
        XCTAssertEqual(gh.calls.count, 3)
    }

    func testGhRepoIsLeftToGhPrList() {
        environment["GH_REPO"] = "octocat/Hello-World"
        let checkouts = (0..<2).map { checkout($0) }
        XCTAssertEqual(titles(sweep(checkouts)), ["feature-0", "feature-1"])
        XCTAssertEqual(gh.count("repo view"), 0, "gh repo view ignores GH_REPO")
        XCTAssertEqual(gh.count("pr list"), 2)
        XCTAssertEqual(gh.count("api graphql"), 0)
    }

    func testOutsideACheckoutIsAlone() {
        let plain = PullRequests.Checkout(directory: "/tmp/plain", branch: "x", ids: [], root: nil)
        XCTAssertEqual(titles(sweep([plain])), ["x"])
        XCTAssertEqual(gh.count("repo view"), 0)
    }

    func testTwoClonesOfOneRepositoryShareAnAlias() {
        gh.repoView = { _ in output(#"{"nameWithOwner":"o/n","url":"https://github.com/o/n"}"#) }
        let checkouts = [checkout(0, branch: "b"), checkout(1, branch: "b"), checkout(2, branch: "c")]
        _ = sweep(checkouts)
        var aliases = 0
        gh.graphQL = { body in
            aliases = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
                .flatMap { $0["variables"] as? [String: String] }.map { $0.count / 3 } ?? -1
            return output(FakeGh.answerEveryAlias(body))
        }
        XCTAssertEqual(titles(sweep(checkouts)), ["b", "b", "c"])
        XCTAssertEqual(aliases, 2)
    }

    func testThePlanSplitsAndShares() {
        var repos: [GitHubRepo?] = (0..<45).map { _ in repo("o", "n") }
        repos[7] = nil
        var branches = (0..<45).map { "b\($0)" }
        branches[3] = "b2"          // a second clone on b2 shares its alias
        branches[9] = "fork:b9"     // left to gh
        let plan = PullRequestBatch.plan(repos: repos, branches: branches)
        XCTAssertEqual(plan.calls.map(\.count), [20, 20, 2])
        XCTAssertEqual(Set(plan.calls.flatMap { $0 }).count, 42)
        XCTAssertEqual(plan.requestOf[3], plan.requestOf[2])
        XCTAssertNil(plan.requestOf[7])
        XCTAssertNil(plan.requestOf[9])
        XCTAssertEqual(PullRequestBatch.plan(repos: repos, branches: branches, cap: 50).calls.map(\.count), [42])
        XCTAssertEqual(PullRequestBatch.plan(repos: [], branches: []), PullRequestBatch.Plan())
    }

    func testConcurrentMapKeepsTheOrder() {
        XCTAssertEqual(PullRequestBatch.concurrentMap(100, limit: 4) { $0 * 2 }, (0..<100).map { $0 * 2 })
        XCTAssertEqual(PullRequestBatch.concurrentMap(0, limit: 4) { $0 }, [])
        XCTAssertEqual(PullRequestBatch.concurrentMap(3, limit: 0) { $0 }, [0, 1, 2])
    }

    func testAFallbackIsNewsOncePerCheckoutAndReason() {
        var notes = FallbackNotes()
        XCTAssertTrue(notes.isNews(key: "/a", reason: "GHE"))
        XCTAssertFalse(notes.isNews(key: "/a", reason: "GHE"))
        XCTAssertTrue(notes.isNews(key: "/b", reason: "GHE"))
        XCTAssertTrue(notes.isNews(key: "/a", reason: "timed out"))
        XCTAssertFalse(notes.isNews(key: "/a", reason: "GHE"), "another reason in between is no reason to repeat")
    }
}

// MARK: - Live

/// Asks GitHub for real: `PLANCHETTE_LIVE_GH=1 swift test --filter PullRequestBatchLiveTests`.
/// Compares, for recent branches of this repository (or `PLANCHETTE_LIVE_GH_DIR`), what
/// `gh pr list` in the checkout says with what the batch says.
final class PullRequestBatchLiveTests: XCTestCase {
    func testTheBatchAgreesWithGhPrList() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLANCHETTE_LIVE_GH"] == "1", "set PLANCHETTE_LIVE_GH=1 to ask GitHub")
        let gh = try XCTUnwrap(PullRequests.ghPath(), "gh is not installed")
        let directory = environment["PLANCHETTE_LIVE_GH_DIR"] ?? (#filePath as NSString).deletingLastPathComponent
        let root = try XCTUnwrap(Titles.checkoutRoot(forDirectory: directory))

        let listed = try XCTUnwrap(Subprocess.run(
            gh, ["pr", "list", "--state", "all", "--limit", "12", "--json", "headRefName"], in: root, timeout: 60))
        XCTAssertTrue(listed.succeeded, listed.stderrString)
        let heads = (try JSONSerialization.jsonObject(with: listed.stdout) as? [[String: Any]] ?? [])
            .compactMap { $0["headRefName"] as? String }
        var branches = [String]()
        for branch in heads + [Titles.gitBranch(forDirectory: root) ?? "", "main",
                               "planchette-live-no-such-branch-\(UUID().uuidString.prefix(8))"]
        where !branch.isEmpty && !branches.contains(branch) {
            branches.append(branch)
        }
        let checkouts = branches.map { PullRequests.Checkout(directory: root, branch: $0, ids: [], root: root) }
        func seconds(_ work: () -> Void) -> String {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return String(format: "%.1f s", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        var alone: [PullRequests.Lookup] = []
        let oneByOne = seconds { alone = checkouts.map { PullRequests.lookup(branch: $0.branch, in: $0.directory) } }

        let counted = OSAllocatedUnfairLock(initialState: [String: Int]())
        let real = PullRequests.runner(gh)
        let context = PullRequests.SweepContext(
            run: { arguments, directory, input in
                counted.withLock { $0[arguments.prefix(2).joined(separator: " "), default: 0] += 1 }
                return real(arguments, directory, input)
            },
            environment: environment, home: environment["HOME"] ?? NSHomeDirectory())
        let cache = OSAllocatedUnfairLock(initialState: RepoCache())
        var first: [PullRequests.Lookup] = []
        let firstSweep = seconds { first = PullRequests.lookup(checkouts, context: context, cache: cache) }
        XCTAssertEqual(first, alone, "the first sweep")
        counted.withLock { $0 = [:] }
        var batched: [PullRequests.Lookup] = []
        let laterSweep = seconds { batched = PullRequests.lookup(checkouts, context: context, cache: cache) }
        print("live timing: one by one \(oneByOne), first sweep \(firstSweep), later sweep \(laterSweep)")
        XCTAssertEqual(counted.withLock { $0 }, ["api graphql": 1], "the second sweep is one call")
        var found = 0
        for (index, branch) in branches.enumerated() {
            XCTAssertNotEqual(alone[index], .failed, "gh pr list failed for \(branch)")
            XCTAssertEqual(batched[index], alone[index], branch)
            if case .found = batched[index] { found += 1 }
        }
        print("live: \(root), \(branches.count) branches, \(found) with a PR, batch equal to gh pr list")
    }
}

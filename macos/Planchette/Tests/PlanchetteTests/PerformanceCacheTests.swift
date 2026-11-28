import XCTest
@testable import Planchette

/// The caches of the second performance pass give the answers the work they skip would give.
final class PerformanceCacheTests: XCTestCase {
    private let claudeRules = ScreenDetector.builtIn.rules(for: .claude)

    func testTheByteSearchFindsWhatContainsFinds() {
        let haystack = "❯ do you want to proceed? 1. yes 2. no, and tell claude what to do differently"
        for needle in ["do you want", "❯", "1. yes", "differently", "", haystack] {
            XCTAssertEqual(ScreenDetector.bytesContain(haystack, needle), haystack.contains(needle), needle)
        }
        for needle in ["do you wanted", "❯❯", "x", haystack + " "] {
            XCTAssertFalse(ScreenDetector.bytesContain(haystack, needle), needle)
        }
        XCTAssertFalse(ScreenDetector.bytesContain("", "a"))
    }

    func testAReadingIsReusedOnlyForTheSameScreenAndRules() {
        var readings = ScreenReadings()
        let id = UUID()
        var runs = 0
        func read(_ text: String, _ rules: [ScreenRule]) -> ScreenDetection? {
            readings.detection(for: id, text: text, rules: rules) {
                runs += 1
                return ScreenDetector.detect(lines: text.components(separatedBy: "\n"), rules: rules)
            }
        }
        let screen = "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
        let first = read(screen, claudeRules)
        XCTAssertEqual(read(screen, claudeRules), first)
        XCTAssertEqual(runs, 1, "an unchanged screen is not read again")
        _ = read(screen + " ", claudeRules)
        XCTAssertEqual(runs, 2, "a changed screen is")
        _ = read(screen + " ", Array(claudeRules.dropLast()))
        XCTAssertEqual(runs, 3, "so are changed rules")
        readings.forget(id)
        _ = read(screen + " ", Array(claudeRules.dropLast()))
        XCTAssertEqual(runs, 4, "and a forgotten terminal")
        XCTAssertEqual(readings.count, 1)
    }

    func testSameBytesIsByteEquality() {
        XCTAssertTrue(ScreenReadings.sameBytes("", ""))
        XCTAssertTrue(ScreenReadings.sameBytes("❯ ok", "❯ ok"))
        XCTAssertFalse(ScreenReadings.sameBytes("❯ ok", "❯ ok "))
        // Canonically equal, but not the same bytes: read again, which is only safe.
        XCTAssertFalse(ScreenReadings.sameBytes("\u{E9}", "e\u{301}"))
    }

    func testAGitFileIsReadAgainWhenItChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stat-cached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let head = dir.appendingPathComponent("HEAD")
        try "ref: refs/heads/main\n".write(to: head, atomically: true, encoding: .utf8)
        XCTAssertEqual(StatCachedText.read(head.path), "ref: refs/heads/main\n")
        XCTAssertEqual(StatCachedText.read(head.path), "ref: refs/heads/main\n")
        // git replaces HEAD by a rename: a new inode, here with the same size.
        try "ref: refs/heads/next\n".write(to: head, atomically: true, encoding: .utf8)
        XCTAssertEqual(StatCachedText.read(head.path), "ref: refs/heads/next\n")
        try FileManager.default.removeItem(at: head)
        XCTAssertNil(StatCachedText.read(head.path))
    }

    /// An unchanged stamp is answered from the cache, and an in-place rewrite of the same
    /// inode and size is still seen through its modification time.
    func testAGitFileIsReadFromTheCacheUntilItsStampChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stat-cached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let head = dir.appendingPathComponent("HEAD")
        try "ref: refs/heads/main\n".write(to: head, atomically: false, encoding: .utf8)
        XCTAssertEqual(StatCachedText.read(head.path), "ref: refs/heads/main\n")

        func modified() -> timespec {
            var info = stat()
            stat(head.path, &info)
            return info.st_mtimespec
        }
        func setModified(_ time: timespec) {
            var times = [time, time]
            XCTAssertEqual(utimensat(AT_FDCWD, head.path, &times, 0), 0)
        }
        func inode() -> UInt64 {
            var info = stat()
            stat(head.path, &info)
            return info.st_ino
        }
        let before = modified(), inodeBefore = inode()

        // Same inode, same size, same time: the cache answers, the file is not read.
        try "ref: refs/heads/xxxx\n".write(to: head, atomically: false, encoding: .utf8)
        setModified(before)
        XCTAssertEqual(inode(), inodeBefore)
        XCTAssertEqual(StatCachedText.read(head.path), "ref: refs/heads/main\n")

        // Same inode and size, a later time: read again.
        setModified(timespec(tv_sec: before.tv_sec + 10, tv_nsec: before.tv_nsec))
        XCTAssertEqual(StatCachedText.read(head.path), "ref: refs/heads/xxxx\n")
    }

    func testTheBannerSearchStillIgnoresCase() {
        for screen in [" ✻ Opus 5.5 (1M context)", "opus (1m context)", "OPUS (1M CONTEXT)", "1M Context"] {
            XCTAssertTrue(ContextWindow.screenShowsExtended(screen), screen)
        }
        for screen in ["Opus 5.5 · Claude Max", "context left: 12%", ""] {
            XCTAssertFalse(ContextWindow.screenShowsExtended(screen), screen)
        }
    }

    /// The process arguments are read into a buffer that is not zero-filled first: only
    /// what the kernel wrote may come out.
    func testAProcessReadsItsOwnCommandLine() throws {
        let read = try XCTUnwrap(ClaudeProcess.arguments(of: getpid()))
        XCTAssertEqual(read.argv, CommandLine.arguments)
        XCTAssertFalse(read.env.isEmpty)
    }

    /// The end of a turn asks about the PR after any shell command that is not only a
    /// git read: `make pr` can push and open a PR without naming git.
    func testTheEndOfATurnAsksAfterAnyCommandThatIsNotOnlyAGitRead() {
        func asks(_ tool: String?, _ command: String? = nil) -> Bool {
            PullRequests.toolMayTouchGitByTurnEnd(toolName: tool, command: command)
        }
        for command in [
            "make pr", "./scripts/ship.sh", "npm test", "git status && git push", "gh pr view",
            "git status && make pr", "git diff --quiet || ./scripts/ship.sh", "git log -1 && npm run release",
            "git log | xargs git push", "cd app; git status; ./push.sh", "git status $(./ship.sh)",
            "echo hi", "git --no-pager log && hub pull-request", "git status && git-town ship",
            "git log -1; npm version patch", "git diff --stat && ./scripts/release.sh",
        ] {
            XCTAssertTrue(asks("Bash", command), command)
        }
        for command in [
            "git status", "git diff --stat && git log -3", "git -C ../app show HEAD",
            "cd ../app && git status", "git log --oneline | head -5", "GIT_PAGER=cat git log -1",
            "git diff | wc -l", "[ -d .git ] && git status",
        ] {
            XCTAssertFalse(asks("Bash", command), command)
        }
        XCTAssertTrue(asks("Bash", nil))
        XCTAssertTrue(asks("mcp__github__create_pull_request"))
        XCTAssertTrue(asks(nil))
        XCTAssertTrue(asks("shell"), "another agent's tool")
        for tool in ["Read", "Edit", "Grep", "Glob", "WebFetch"] {
            XCTAssertFalse(asks(tool), tool)
        }
    }

    /// An override file's patterns are matched as bytes, so a decomposed one is
    /// precomposed when the file is read.
    func testAnOverridePatternInDecomposedFormStillMatches() throws {
        let json = """
        {"version": 99, "engine": \(ScreenRuleSet.engineVersion), "agents": {"claude": [
          {"id": "cafe", "state": "blocked", "priority": 1, "contains": ["caf\\u0065\\u0301"]}
        ]}}
        """
        let set = try XCTUnwrap(ScreenDetector.validated(Data(json.utf8)))
        let rules = set.rules(for: .claude)
        XCTAssertEqual(ScreenDetector.detect(lines: ["Open the caf\u{E9}?"], rules: rules)?.ruleID, "cafe")
    }

    /// A screen a program printed decomposed matches a precomposed rule, and a
    /// combining mark does not let a shorter rule match half a character.
    func testADecomposedScreenMatchesAsItsCharacters() throws {
        let json = """
        {"version": 99, "engine": \(ScreenRuleSet.engineVersion), "agents": {"claude": [
          {"id": "loeschen", "state": "blocked", "priority": 2, "contains": ["l\\u00f6schen?"]},
          {"id": "cafe", "state": "blocked", "priority": 1, "contains": ["cafe?"]}
        ]}}
        """
        let rules = try XCTUnwrap(ScreenDetector.validated(Data(json.utf8))).rules(for: .claude)
        XCTAssertEqual(ScreenDetector.detect(lines: ["Datei lo\u{308}schen?"], rules: rules)?.ruleID, "loeschen")
        XCTAssertNil(ScreenDetector.detect(lines: ["Open the cafe\u{301}?"], rules: rules))
        XCTAssertEqual(ScreenDetector.detect(lines: ["Open the cafe?"], rules: rules)?.ruleID, "cafe")
    }

    // MARK: Eager PR lookups

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testTheFirstLookupRunsAndOneInsideTheGapWaitsForItsEnd() {
        var lookups = EagerLookups()
        let a = UUID()
        XCTAssertEqual(lookups.request(key: "repo\u{0}b", id: a, now: t0), .askNow)
        XCTAssertEqual(lookups.request(key: "repo\u{0}b", id: a, now: t0 + 5), .deferFor(PullRequests.eagerGap - 5))
        XCTAssertEqual(lookups.request(key: "repo\u{0}b", id: a, now: t0 + 6), .joined, "one wait per checkout")
        XCTAssertEqual(lookups.takeDeferred(key: "repo\u{0}b", now: t0 + 15), [a])
        // The deferred lookup counts as a lookup: the next request waits again.
        XCTAssertEqual(lookups.request(key: "repo\u{0}b", id: a, now: t0 + 16), .deferFor(PullRequests.eagerGap - 1))
        XCTAssertEqual(lookups.request(key: "repo\u{0}b", id: a, now: t0 + 20), .joined)
        XCTAssertEqual(lookups.takeDeferred(key: "repo\u{0}b", now: t0 + 30), [a])
        XCTAssertEqual(lookups.request(key: "repo\u{0}b", id: a, now: t0 + 44), .deferFor(1))
        _ = lookups.takeDeferred(key: "repo\u{0}b", now: t0 + 45)
        XCTAssertEqual(lookups.request(key: "repo\u{0}b", id: a, now: t0 + 60), .askNow)
    }

    func testEveryTerminalThatAsksInsideTheGapIsAskedAboutAtItsEnd() {
        var lookups = EagerLookups()
        let a = UUID(), b = UUID()
        XCTAssertEqual(lookups.request(key: "k", id: a, now: t0), .askNow)
        XCTAssertEqual(lookups.request(key: "k", id: a, now: t0 + 2), .deferFor(PullRequests.eagerGap - 2))
        XCTAssertEqual(lookups.request(key: "k", id: b, now: t0 + 5), .joined)
        // A closes before the gap ends: B is still asked about.
        lookups.forget(a)
        XCTAssertEqual(lookups.takeDeferred(key: "k", now: t0 + 15), [b])
        XCTAssertEqual(lookups.takeDeferred(key: "k", now: t0 + 16), [], "taken once")
    }

    func testCheckoutsHaveTheirOwnGapsAndTheAppsFrontLookupIsNotDeferred() {
        var lookups = EagerLookups()
        let a = UUID(), b = UUID()
        XCTAssertEqual(lookups.request(key: "one", id: a, now: t0), .askNow)
        XCTAssertEqual(lookups.request(key: "two", id: b, now: t0 + 1), .askNow)
        XCTAssertEqual(lookups.request(key: "", id: nil, now: t0 + 2), .askNow)
        XCTAssertEqual(lookups.request(key: "", id: nil, now: t0 + 3), .dropped)
        XCTAssertEqual(lookups.request(key: "", id: nil, now: t0 + 17), .askNow)
        // Old gaps are not kept.
        _ = lookups.request(key: "three", id: a, now: t0 + 100)
        XCTAssertEqual(Set(lookups.last.keys), ["three"])
    }

    // MARK: The turn record

    func testATurnAsksGitHubOnlyWhenAToolCallMayHaveTouchedGit() {
        var record = TurnGitRecord()
        let a = UUID()
        // No tool call reported: ask (an agent without tool hooks).
        XCTAssertTrue(record.turnEnded(a, endsTurn: true))

        record.record(event: "UserPromptSubmit", id: a, mayTouchGit: true)
        record.record(event: "PostToolUse", id: a, mayTouchGit: false)
        record.record(event: "PostToolUse", id: a, mayTouchGit: false)
        XCTAssertFalse(record.turnEnded(a, endsTurn: true), "reads and edits only")

        record.record(event: "PostToolUse", id: a, mayTouchGit: false)
        record.record(event: "PostToolUseFailure", id: a, mayTouchGit: true)
        record.record(event: "PostToolUse", id: a, mayTouchGit: false)
        XCTAssertTrue(record.turnEnded(a, endsTurn: true), "a failed push counts, and later reads do not clear it")

        // The record of one turn does not reach the next.
        record.record(event: "PostToolUse", id: a, mayTouchGit: false)
        XCTAssertFalse(record.turnEnded(a, endsTurn: true))
    }

    func testASubagentsEndKeepsTheTurnsRecord() {
        var record = TurnGitRecord()
        let a = UUID()
        record.record(event: "PostToolUse", id: a, mayTouchGit: true)
        XCTAssertTrue(record.turnEnded(a, endsTurn: false), "SubagentStop")
        XCTAssertTrue(record.turnEnded(a, endsTurn: true), "the main Stop still sees the push")
        XCTAssertTrue(record.turnEnded(a, endsTurn: true), "nothing recorded: ask")
    }

    func testANewPromptOrTheSessionsEndStartsTheRecordAgain() {
        var record = TurnGitRecord()
        let a = UUID(), b = UUID()
        for reset in ["UserPromptSubmit", "SessionEnd"] {
            record.record(event: "PostToolUse", id: a, mayTouchGit: false)
            record.record(event: reset, id: a, mayTouchGit: false)
            XCTAssertTrue(record.turnEnded(a, endsTurn: true), reset)
        }
        // Other events do not touch the record, and terminals are apart.
        record.record(event: "PostToolUse", id: a, mayTouchGit: false)
        record.record(event: "Notification", id: a, mayTouchGit: true)
        record.record(event: "PreToolUse", id: a, mayTouchGit: true)
        record.record(event: "PostToolUse", id: b, mayTouchGit: true)
        XCTAssertFalse(record.turnEnded(a, endsTurn: true))
        record.forget(b)
        XCTAssertTrue(record.turnEnded(b, endsTurn: true), "forgotten: nothing recorded")
    }
}

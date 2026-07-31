import XCTest
import SwiftUI
@testable import Planchette

final class SemverTests: XCTestCase {
    func testNewerMajorMinorPatch() {
        XCTAssertTrue(Semver.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(Semver.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(Semver.isNewer("1.0.1", than: "1.0.0"))
    }

    func testNotNewerWhenEqualOrOlder() {
        XCTAssertFalse(Semver.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Semver.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertFalse(Semver.isNewer("1.2.0", than: "1.10.0"))
    }

    func testIgnoresLeadingVAndPrerelease() {
        XCTAssertTrue(Semver.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertFalse(Semver.isNewer("1.0.0-dev", than: "1.0.0"))
    }

    func testDifferentComponentCounts() {
        XCTAssertTrue(Semver.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(Semver.isNewer("1.0", than: "1.0.0"))
    }
}

final class TitlesTests: XCTestCase {
    func testShortPathTakesLastTwoComponents() {
        XCTAssertEqual(Titles.shortPath("/Users/x/development/sandbox/planchette"), "sandbox/planchette")
        XCTAssertEqual(Titles.shortPath("/one"), "one")
    }

    func testTicketExtractedFromGitBranch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planchette-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/marcello/feat/NIE-4213-cool-thing\n"
            .write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(Titles.ticket(forDirectory: dir.path), "NIE-4213")
    }

    func testNoTicketForPlainBranch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planchette-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n"
            .write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(Titles.ticket(forDirectory: dir.path))
    }
}

final class UpdateSecurityTests: XCTestCase {
    func testTrustedGitHubDownloads() {
        XCTAssertTrue(UpdateService.isTrustedDownload(URL(string: "https://github.com/marcello-a/Planchette/releases/download/v1/Planchette.dmg")!))
        XCTAssertTrue(UpdateService.isTrustedDownload(URL(string: "https://objects.githubusercontent.com/x/y.dmg")!))
    }

    func testRejectsUntrustedOrInsecureDownloads() {
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "http://github.com/x.dmg")!))       // not https
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "https://evil.example.com/x.dmg")!))
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "https://github.com.evil.com/x")!)) // suffix spoof
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "file:///etc/passwd")!))
    }
}

final class AttentionStateTests: XCTestCase {
    func testNeedsAttention() {
        XCTAssertTrue(AttentionState.waiting.needsAttention)
        XCTAssertTrue(AttentionState.error.needsAttention)
        XCTAssertFalse(AttentionState.running.needsAttention)
        XCTAssertFalse(AttentionState.ready.needsAttention)
    }

    func testDecodesLegacyRawValues() throws {
        func decode(_ raw: String) throws -> AttentionState {
            try JSONDecoder().decode(AttentionState.self, from: Data("\"\(raw)\"".utf8))
        }
        // v0.1.x values migrate to the new color-system states.
        XCTAssertEqual(try decode("working"), .running)
        XCTAssertEqual(try decode("asking"), .waiting)
        XCTAssertEqual(try decode("done"), .ready)
        XCTAssertEqual(try decode("free"), .free)
        // New values round-trip; unknown falls back to free (idle).
        XCTAssertEqual(try decode("error"), .error)
        XCTAssertEqual(try decode("bogus"), .free)
    }
}

final class SplitLayoutTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testSplitLeafRightMakesRow() {
        let layout = SplitLayout.leaf(a).splitting(a, with: b, edge: .right).normalized()
        XCTAssertEqual(layout, .row([.leaf(a), .leaf(b)]))
    }

    func testSplitLeafTopMakesColumnNewFirst() {
        let layout = SplitLayout.leaf(a).splitting(a, with: b, edge: .top).normalized()
        XCTAssertEqual(layout, .column([.leaf(b), .leaf(a)]))
    }

    func testNormalizeFlattensNestedSameAxis() {
        let nested = SplitLayout.row([.leaf(a), .row([.leaf(b), .leaf(c)])])
        XCTAssertEqual(nested.normalized(), .row([.leaf(a), .leaf(b), .leaf(c)]))
    }

    func testRemovingLeafCollapsesSingleton() {
        let layout = SplitLayout.row([.leaf(a), .leaf(b)])
        XCTAssertEqual(layout.removingLeaf(a), .leaf(b))
    }

    func testSyncedAddsAndRemoves() {
        let layout = SplitLayout.row([.leaf(a), .leaf(b)])
        let synced = layout.synced(to: [a, c])   // drop b, add c
        XCTAssertEqual(Set(synced.leaves), [a, c])
    }

    func testDropWhereAlreadyPresentIsNoOp() {
        // row([a,b]) → drop b on a's RIGHT edge → still row([a,b]) (no change).
        let current = SplitLayout.row([.leaf(a), .leaf(b)]).normalized()
        let removed = current.removingLeaf(b) ?? .leaf(a)
        let result = removed.splitting(a, with: b, edge: .right).normalized()
        XCTAssertEqual(result, current, "dropping a pane where it already sits must be a no-op")
        // …but dropping b on a's LEFT edge does change it.
        let changed = (current.removingLeaf(b) ?? .leaf(a))
            .splitting(a, with: b, edge: .left).normalized()
        XCTAssertNotEqual(changed, current)
    }

    func testMoveAcrossTree() {
        // a | b  →  drop a below b  →  b over a in one column
        let start = SplitLayout.row([.leaf(a), .leaf(b)])
        let moved = (start.removingLeaf(a) ?? .leaf(b))
            .splitting(b, with: a, edge: .bottom).normalized()
        XCTAssertEqual(moved, .column([.leaf(b), .leaf(a)]))
    }
}

final class ShellEscapeTests: XCTestCase {
    // Dropped file paths must arrive at the prompt in one piece.
    func testEscapesShellSensitiveCharacters() {
        XCTAssertEqual(Shell.escape("/tmp/my file.png"), "/tmp/my\\ file.png")
        XCTAssertEqual(Shell.escape("/a/(b)/c'd\"e"), "/a/\\(b\\)/c\\'d\\\"e")
        XCTAssertEqual(Shell.escape("plain/path.png"), "plain/path.png")
        XCTAssertEqual(Shell.escape("a$b`c!d"), "a\\$b\\`c\\!d")
    }
}

final class ControlAPITests: XCTestCase {
    // Hook events and control requests share one socket: a hook payload must
    // never be mistaken for a command.
    func testHookPayloadsAreNotRequests() {
        XCTAssertNil(ControlAPI.parse(["planchette_session": "x", "event": [:]]))
        XCTAssertNil(ControlAPI.parse([:]))
    }

    func testParsesKnownCommandAndKeepsArguments() throws {
        let parsed = ControlAPI.parse([
            "planchette_request": "session.prompt",
            "id": "11111111-2222-3333-4444-555555555555",
            "text": "go",
            "submit": false,
        ])
        guard case .success(let request) = try XCTUnwrap(parsed) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(request.command, .sessionPrompt)
        XCTAssertEqual(request.string("text"), "go")
        XCTAssertEqual(request.bool("submit"), false)
        XCTAssertNotNil(request.uuid("id"))
        // The command name itself is not an argument.
        XCTAssertNil(request.string("planchette_request"))
    }

    // An unknown command must say what *is* known: the caller is a shell script.
    func testUnknownCommandListsTheSurface() throws {
        guard case .failure(let failure) = try XCTUnwrap(
            ControlAPI.parse(["planchette_request": "session.frobnicate"]))
        else { return XCTFail("expected a failure") }
        XCTAssertTrue(failure.message.contains("session.frobnicate"))
        for command in ControlAPI.Command.allCases {
            XCTAssertTrue(
                failure.message.contains(command.rawValue), "should list \(command.rawValue)")
        }
    }

    func testResponsesAreAlwaysDecodableJSONWithOK() throws {
        for data in [
            ControlAPI.encode(ok: true, result: ["sessions": []]),
            ControlAPI.encode(ok: false, error: "nope"),
        ] {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(object?["ok"] as? Bool)
        }
        let failure = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ControlAPI.encode(ok: false, error: "nope"))
                as? [String: Any])
        XCTAssertEqual(failure["error"] as? String, "nope")
        XCTAssertEqual(failure["ok"] as? Bool, false)
    }

    // Values JSONSerialization would choke on must not produce invalid output.
    func testUnencodableResultStillYieldsValidJSON() throws {
        let data = ControlAPI.encode(ok: true, result: ["bad": Double.nan])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, false)
    }

    func testUUIDArgumentsRejectGarbage() {
        guard case .success(let request)? = ControlAPI.parse([
            "planchette_request": "session.get", "id": "not-a-uuid",
        ]) else { return XCTFail("expected a parsed request") }
        XCTAssertNil(request.uuid("id"))
    }
}

final class SeenTrackingTests: XCTestCase {
    // "ready" means a turn ended at some point; unseen ready is the honest
    // answer to "what is waiting for my review?".
    func testSessionsStartSeen() {
        let session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        XCTAssertTrue(session.seen, "a fresh terminal has nothing unreviewed")
    }

    // Older state has no flag: it must not all show up as unreviewed work.
    func testDecodingOlderStateDefaultsToSeen() throws {
        let json = """
            {"id":"\(UUID().uuidString)","groupID":"\(UUID().uuidString)",
             "workingDirectory":"/tmp","state":"ready"}
            """
        let session = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
        XCTAssertTrue(session.seen)
        XCTAssertEqual(session.state, .ready)
    }

    func testSeenRoundTrips() throws {
        var session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        session.seen = false
        let data = try JSONEncoder().encode(session)
        XCTAssertFalse(try JSONDecoder().decode(TerminalSession.self, from: data).seen)
    }
}

final class DurableTests: XCTestCase {
    // A GUI app's PATH has no Homebrew, so tmux is looked up by absolute path.
    // Order matters: the first hit wins, Homebrew before a system tmux.
    func testPicksFirstExecutableCandidate() {
        let found = Durable.tmuxPath(
            searching: ["/opt/homebrew/bin/tmux", "/usr/bin/tmux"],
            isExecutable: { $0 == "/usr/bin/tmux" })
        XCTAssertEqual(found, "/usr/bin/tmux")

        let both = Durable.tmuxPath(
            searching: ["/opt/homebrew/bin/tmux", "/usr/bin/tmux"],
            isExecutable: { _ in true })
        XCTAssertEqual(both, "/opt/homebrew/bin/tmux")
    }

    func testNoTmuxAnywhereIsNotAnError() {
        XCTAssertNil(Durable.tmuxPath(searching: ["/nope"], isExecutable: { _ in false }))
    }

    // Re-attach only works because the name is derived from the persisted id:
    // same terminal, same name, across any number of app restarts.
    func testSessionNameIsStableAndTmuxSafe() {
        let id = UUID(uuidString: "6C3E1F2A-9B4D-4E7A-8F10-2D5C7B9E1A34")!
        let name = Durable.sessionName(for: id)
        XCTAssertEqual(name, "planchette-6c3e1f2a-9b4d-4e7a-8f10-2d5c7b9e1a34")
        XCTAssertEqual(name, Durable.sessionName(for: id), "must not vary between calls")
        // `.` and `:` separate window/pane in a tmux target — neither may appear.
        XCTAssertFalse(name.contains("."))
        XCTAssertFalse(name.contains(":"))
    }

    func testDifferentTerminalsGetDifferentSessions() {
        XCTAssertNotEqual(Durable.sessionName(for: UUID()), Durable.sessionName(for: UUID()))
    }

    // -A creates-or-attaches (one command for first launch and re-attach),
    // -D evicts the stale client a crashed Planchette left behind.
    func testAttachCommandCreatesOrAttachesAndEvicts() {
        let cmd = Durable.attachCommand(tmux: "/opt/homebrew/bin/tmux", session: "planchette-x")
        XCTAssertEqual(cmd, "/opt/homebrew/bin/tmux new-session -A -D -s planchette-x")
    }

    // The user's own tmux sessions are none of our business — reaping must
    // never kill them.
    func testParsesOnlyOurSessions() {
        let id = UUID()
        let output = """
            planchette-\(id.uuidString.lowercased()) 0
            work 1
            planchette-not-a-uuid 0
            0 1

            """
        let parsed = Durable.parseSessionList(output)
        XCTAssertEqual(parsed.map(\.id), [id])
        XCTAssertEqual(parsed.map(\.attached), [false])
    }

    func testParsesEmptyOutput() {
        XCTAssertTrue(Durable.parseSessionList("").isEmpty)
    }

    // Attachment is what separates "another Planchette is using this" from
    // "nobody is coming back for this".
    func testReadsTheAttachedFlag() {
        let live = UUID(), orphan = UUID()
        let output = """
            planchette-\(live.uuidString.lowercased()) 1
            planchette-\(orphan.uuidString.lowercased()) 0
            """
        let parsed = Durable.parseSessionList(output)
        XCTAssertEqual(parsed.first(where: { $0.id == live })?.attached, true)
        XCTAssertEqual(parsed.first(where: { $0.id == orphan })?.attached, false)
    }

    // A line we cannot fully read must not be treated as reapable: killing a
    // session we misparsed would destroy work, keeping it only leaks one.
    func testUnreadableAttachedCountCountsAsAttached() {
        let id = UUID()
        let parsed = Durable.parseSessionList("planchette-\(id.uuidString.lowercased())")
        XCTAssertEqual(parsed.map(\.attached), [true])
    }

    // Durability is decided at creation and persisted: a terminal that came
    // back must know to re-attach rather than start a fresh shell.
    func testDurableRoundTrips() throws {
        var session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        XCTAssertFalse(session.durable, "ordinary terminals stay ordinary")
        session.durable = true
        let data = try JSONEncoder().encode(session)
        XCTAssertTrue(try JSONDecoder().decode(TerminalSession.self, from: data).durable)
    }

    // State written before this feature existed must not claim a tmux session
    // that was never created.
    func testOlderStateIsNotDurable() throws {
        let json = """
            {"id":"\(UUID().uuidString)","groupID":"\(UUID().uuidString)",
             "workingDirectory":"/tmp"}
            """
        let session = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
        XCTAssertFalse(session.durable)
    }

    func testSettingDefaultsOffInOlderState() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertFalse(state.durableTerminals, "opt-in: it needs tmux installed")
    }
}

final class HookSocketTests: XCTestCase {
    func testRecognizesOurOwnSocketNames() {
        XCTAssertEqual(HookServer.pidOfSocketFile(named: "planchette-4321.sock"), 4321)
    }

    // Anything else in /tmp must survive the sweep untouched.
    func testIgnoresForeignAndMalformedNames() {
        for name in [
            "planchette.sock",              // the pre-per-instance name
            "planchette-.sock",             // no pid
            "planchette-abc.sock",          // not a number
            "planchette-12ab.sock",         // partly a number
            "planchette-0.sock",            // pid 0 is not a real target
            "planchette-4321.sock.bak",     // not our suffix
            "other-4321.sock",
            "planchette-4321",
        ] {
            XCTAssertNil(HookServer.pidOfSocketFile(named: name), "must ignore \(name)")
        }
    }

    // The sweep decides what to delete from this, so a negative pid — which
    // kill(2) reads as a process *group* — must never get through.
    func testRejectsNegativePid() {
        XCTAssertNil(HookServer.pidOfSocketFile(named: "planchette--1.sock"))
    }

    // Our own socket is live by definition; deleting it would unlink the socket
    // we are about to listen on.
    func testSweepKeepsOurOwnLiveSocket() throws {
        let own = HookServer.socketPath
        FileManager.default.createFile(atPath: own, contents: nil)
        defer { unlink(own) }
        HookServer.removeSocketsOfDeadInstances()
        XCTAssertTrue(FileManager.default.fileExists(atPath: own))
    }

    // The case that actually bit: an instance killed rather than quit leaves its
    // socket file behind, which makes every `-S` test lie.
    func testSweepRemovesADeadInstancesSocket() throws {
        // A pid that cannot be running: allocate one, then let it exit.
        let doomed = Process()
        doomed.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try doomed.run()
        doomed.waitUntilExit()
        let deadPID = doomed.processIdentifier

        let stale = "/tmp/planchette-\(deadPID).sock"
        FileManager.default.createFile(atPath: stale, contents: nil)
        defer { unlink(stale) }

        HookServer.removeSocketsOfDeadInstances()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stale),
            "a socket whose process is gone must not keep answering -S")
    }
}

final class WorktreeTests: XCTestCase {
    // A branch name is not a path: slashes and spaces must not create nested
    // directories or break the shell.
    func testSlugFlattensBranchNames() {
        XCTAssertEqual(Worktrees.slug(forBranch: "marcello/feat/NIE-123-x"), "marcello-feat-NIE-123-x")
        XCTAssertEqual(Worktrees.slug(forBranch: "fix bug"), "fix-bug")
        XCTAssertEqual(Worktrees.slug(forBranch: "release/1.2.0"), "release-1.2.0")
        XCTAssertEqual(Worktrees.slug(forBranch: "  spaced  "), "spaced")
        // Nothing usable left → still a valid single segment.
        XCTAssertEqual(Worktrees.slug(forBranch: "///"), "worktree")
        XCTAssertFalse(Worktrees.slug(forBranch: "a/b").contains("/"))
    }

    // Checkouts live beside the repo, never inside it: a nested checkout would
    // show up in git status, ripgrep, build globs and Planchette's own scans.
    func testCheckoutLivesBesideTheRepo() {
        let path = Worktrees.defaultPath(repoRoot: "/Users/me/dev/planchette", branch: "feat/x")
        XCTAssertEqual(path, "/Users/me/dev/planchette.worktrees/feat-x")
        XCTAssertFalse(path.hasPrefix("/Users/me/dev/planchette/"))
    }

    // The project name should read like the ticket you're working on.
    func testGroupNameUsesTheTicketWhenThereIsOne() {
        XCTAssertEqual(
            Worktrees.groupName(repoName: "planchette", branch: "marcello/feat/NIE-123-drop"),
            "planchette · NIE-123")
        XCTAssertEqual(
            Worktrees.groupName(repoName: "planchette", branch: "spike"), "planchette · spike")
    }

    func testParsesWorktreeList() {
        let output = """
            worktree /Users/me/dev/planchette
            HEAD abc123
            branch refs/heads/main

            worktree /Users/me/dev/planchette.worktrees/feat-x
            HEAD def456
            branch refs/heads/feat/x
            """
        XCTAssertEqual(
            Worktrees.parseWorktreeList(output),
            ["/Users/me/dev/planchette", "/Users/me/dev/planchette.worktrees/feat-x"])
        XCTAssertTrue(Worktrees.parseWorktreeList("").isEmpty)
    }
}

/// Exercises the real `git worktree` plumbing in a throwaway repo — the part
/// that pure tests cannot cover, and the part that actually breaks.
final class WorktreeGitTests: XCTestCase {
    private var repo: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-wt-\(UUID().uuidString)/repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repo = dir.path
        try Worktrees.git(["init", "-q", "-b", "main"], in: repo)
        try Worktrees.git(["config", "user.email", "test@example.com"], in: repo)
        try Worktrees.git(["config", "user.name", "Test"], in: repo)
        try "hello".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Worktrees.git(["add", "."], in: repo)
        try Worktrees.git(["commit", "-qm", "init"], in: repo)
    }

    override func tearDownWithError() throws {
        // The whole sandbox, including any checkout beside the repo.
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: repo).deletingLastPathComponent())
    }

    func testCreateOpensACheckoutOnANewBranch() throws {
        let path = try Worktrees.create(repoRoot: repo, branch: "feat/drop", base: nil)
        // The returned path is git's own, so it is comparable with worktree list
        // even where Foundation cannot resolve the symlink (/var vs /private/var).
        XCTAssertTrue(path.hasSuffix("repo.worktrees/feat-drop"), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/README.md"))
        // The checkout is on the new branch, and the repo knows about it.
        XCTAssertEqual(
            try Worktrees.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path), "feat/drop")
        XCTAssertTrue(Worktrees.list(repoRoot: repo).contains(path))
        XCTAssertEqual(Worktrees.repoRoot(of: path), path)
    }

    func testCreateChecksOutAnExistingBranch() throws {
        try Worktrees.git(["branch", "existing"], in: repo)
        let path = try Worktrees.create(repoRoot: repo, branch: "existing", base: nil)
        XCTAssertEqual(
            try Worktrees.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path), "existing")
    }

    func testCreateRefusesToOverwriteAnExistingPath() throws {
        _ = try Worktrees.create(repoRoot: repo, branch: "twice", base: nil)
        XCTAssertThrowsError(try Worktrees.create(repoRoot: repo, branch: "twice", base: nil))
    }

    // The guard: git itself refuses to remove a dirty checkout, and we surface
    // that instead of forcing it. Losing uncommitted agent work is unacceptable.
    func testRemoveRefusesWhileThereAreUncommittedChanges() throws {
        let path = try Worktrees.create(repoRoot: repo, branch: "dirty", base: nil)
        try "scratch".write(
            to: URL(fileURLWithPath: path).appendingPathComponent("wip.txt"),
            atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Worktrees.remove(path: path, repoRoot: repo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "checkout must survive")
        // Clean → removable.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path + "/wip.txt"))
        try Worktrees.remove(path: path, repoRoot: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRepoRootIsNilOutsideARepo() {
        XCTAssertNil(Worktrees.repoRoot(of: "/tmp"))
    }
}

final class ScreenDetectionTests: XCTestCase {
    private var claudeRules: [ScreenRule] { ScreenDetector.builtIn.rules(for: .claude) }

    // A permission prompt is the one thing only the screen can know when a hook
    // misses it. These are the strings Claude Code actually renders.
    func testPermissionPromptIsABlocker() {
        let screen = """
            ● Bash(rm -rf build)
              Do you want to proceed?
              ❯ 1. Yes
                2. No, and tell Claude what to do differently (esc)
            """
        let detection = ScreenDetector.detect(
            lines: screen.components(separatedBy: "\n"), rules: claudeRules)
        XCTAssertEqual(detection?.state, .blocked)
        XCTAssertTrue(detection?.visibleBlocker == true)
    }

    func testIdleFooterDetectsAQuietPrompt() {
        let screen = """
            ╭───────────────────────────────╮
            │ >                             │
            ╰───────────────────────────────╯
              ? for shortcuts
            """
        XCTAssertEqual(
            ScreenDetector.detect(lines: screen.components(separatedBy: "\n"), rules: claudeRules)?
                .state, .idle)
    }

    // The footer is also on screen *behind* an open prompt — the blocker must
    // win, which is what the priority ordering is for.
    func testBlockerOutranksIdleFooter() {
        let screen = """
            Do you want to proceed?
            ❯ 1. Yes
              2. No
            ? for shortcuts
            """
        let detection = ScreenDetector.detect(
            lines: screen.components(separatedBy: "\n"), rules: claudeRules)
        XCTAssertEqual(detection?.state, .blocked)
    }

    // Scrolled-back history must never be read as the live state.
    func testTranscriptViewerSuppressesTheReading() {
        let screen = """
            Do you want to proceed?
            Showing detailed transcript · ctrl+o to toggle
            """
        let detection = ScreenDetector.detect(
            lines: screen.components(separatedBy: "\n"), rules: claudeRules)
        XCTAssertTrue(detection?.skipStateUpdate == true)
        XCTAssertNil(
            AttentionState.fromScreen(
                detection, agent: .claude, hookAuthority: false, current: .running))
    }

    func testUnrelatedOutputMatchesNothing() {
        let screen = "$ ls -la\ntotal 42\ndrwxr-xr-x  5 me  staff  160 Jul 31 12:00 ."
        XCTAssertNil(
            ScreenDetector.detect(lines: screen.components(separatedBy: "\n"), rules: claudeRules))
    }

    func testRegionIsBoundedToTheTail() {
        // The prompt is far above the rule's tail window → not a live blocker.
        let noise = Array(repeating: "building…", count: 30).joined(separator: "\n")
        let screen = "Do you want to proceed?\n" + noise
        XCTAssertNil(
            ScreenDetector.detect(lines: screen.components(separatedBy: "\n"), rules: claudeRules))
    }

    // Regex rules are what an override file will mostly use, and they run on a
    // 1.5s timer — the pattern is compiled once and cached, so matching must
    // stay correct across repeated calls.
    func testLineRegexRulesMatchAndAreReusable() {
        let rule = ScreenRule(
            id: "prompt_caret", state: .idle, priority: 10, tailLines: 4,
            lineRegex: ["^\\s*❯\\s*$"])
        for _ in 0..<3 {
            XCTAssertEqual(
                ScreenDetector.detect(lines: ["building…", "  ❯  "], rules: [rule])?.state, .idle)
            XCTAssertNil(ScreenDetector.detect(lines: ["❯ run this"], rules: [rule]))
        }
    }

    // A malformed pattern in an override file must not match everything (or
    // crash) — it simply never matches.
    func testInvalidRegexNeverMatches() {
        let rule = ScreenRule(
            id: "broken", state: .blocked, priority: 10, lineRegex: ["([unclosed"])
        XCTAssertNil(ScreenDetector.detect(lines: ["([unclosed"], rules: [rule]))
    }

    /// `rules/screen-rules.json` is what a release publishes and what the app
    /// fetches; `ScreenDetector.builtIn` is the compiled floor. To keep exactly
    /// one hand-maintained source of rules, the file is *generated* from the
    /// floor — and this test fails (with the fresh contents) when it drifts.
    func testShippedRulesFileMatchesTheBuiltInFloor() throws {
        let repo = URL(fileURLWithPath: #filePath)          // …/Tests/PlanchetteTests/LogicTests.swift
            .deletingLastPathComponent()                     // …/Tests/PlanchetteTests
            .deletingLastPathComponent()                     // …/Tests
            .deletingLastPathComponent()                     // …/Planchette
            .deletingLastPathComponent()                     // …/macos
            .deletingLastPathComponent()                     // repo root
        let shipped = repo.appendingPathComponent("rules/screen-rules.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let expected = try encoder.encode(ScreenDetector.builtIn)

        guard let onDisk = try? Data(contentsOf: shipped) else {
            XCTFail("""
                rules/screen-rules.json is missing. Regenerate it with:
                \(String(decoding: expected, as: UTF8.self))
                """)
            return
        }
        // Compare decoded values, not bytes: formatting must not fail the build.
        let a = try JSONDecoder().decode(ScreenRuleSet.self, from: onDisk)
        let b = try JSONDecoder().decode(ScreenRuleSet.self, from: expected)
        XCTAssertEqual(a.engine, b.engine, "shipped rules target a different engine")
        XCTAssertEqual(a.version, b.version, "shipped rules are a different version")
        XCTAssertEqual(
            a.agents.mapValues { $0.map(\.id) }, b.agents.mapValues { $0.map(\.id) },
            "shipped rules drifted from ScreenDetector.builtIn — regenerate rules/screen-rules.json")
    }

    // Rules are data: an override file has to survive a round-trip.
    func testRuleSetIsCodable() throws {
        let data = try JSONEncoder().encode(ScreenDetector.builtIn)
        let decoded = try JSONDecoder().decode(ScreenRuleSet.self, from: data)
        XCTAssertEqual(decoded.engine, ScreenRuleSet.engineVersion)
        XCTAssertEqual(decoded.rules(for: .claude).count, claudeRules.count)
    }
}

final class LiveRuleUpdateTests: XCTestCase {
    private func encoded(_ set: ScreenRuleSet) throws -> Data {
        try JSONEncoder().encode(set)
    }

    private func ruleSet(version: Int, engine: Int = ScreenRuleSet.engineVersion) -> ScreenRuleSet {
        ScreenRuleSet(
            version: version, engine: engine,
            agents: ["claude": [ScreenRule(id: "r", state: .idle, priority: 1)]])
    }

    // A downloaded or edited file is only accepted if it can actually drive
    // detection. Everything else must leave the running rules alone.
    func testValidationAcceptsOnlyUsableRuleSets() throws {
        XCTAssertNotNil(ScreenDetector.validated(try encoded(ruleSet(version: 2))))
        // Garbage.
        XCTAssertNil(ScreenDetector.validated(Data("not json".utf8)))
        XCTAssertNil(ScreenDetector.validated(Data()))
        // Built for a different engine — its rule shape may not match ours.
        XCTAssertNil(ScreenDetector.validated(
            try encoded(ruleSet(version: 9, engine: ScreenRuleSet.engineVersion + 1))))
        // Structurally fine but empty: accepting it would silently stop detection.
        XCTAssertNil(ScreenDetector.validated(try encoded(
            ScreenRuleSet(version: 3, engine: ScreenRuleSet.engineVersion, agents: ["claude": []]))))
    }

    // Only forward, and only within one engine: a re-download or a rolled-back
    // release must not downgrade the rules that are working.
    func testOnlyNewerSameEngineRulesReplaceCurrent() {
        let current = ruleSet(version: 5)
        XCTAssertTrue(ScreenDetector.isNewer(ruleSet(version: 6), than: current))
        XCTAssertFalse(ScreenDetector.isNewer(ruleSet(version: 5), than: current))
        XCTAssertFalse(ScreenDetector.isNewer(ruleSet(version: 4), than: current))
        XCTAssertFalse(ScreenDetector.isNewer(
            ruleSet(version: 99, engine: ScreenRuleSet.engineVersion + 1), than: current))
    }

    // The built-in floor must itself be a valid ruleset — it is what every
    // failure path falls back to.
    func testBuiltInFloorIsValid() throws {
        XCTAssertNotNil(ScreenDetector.validated(try encoded(ScreenDetector.builtIn)))
    }
}

final class StateArbitrationTests: XCTestCase {
    private let blocker = ScreenDetection(
        state: .blocked, ruleID: "t", visibleBlocker: true)
    private let idle = ScreenDetection(state: .idle, ruleID: "t")
    private let working = ScreenDetection(state: .working, ruleID: "t")

    // While hooks are authoritative the screen may do exactly one thing:
    // escalate to waiting when something is visibly blocked.
    func testHookAuthorityOnlyAllowsBlockerEscalation() {
        XCTAssertEqual(
            AttentionState.fromScreen(blocker, agent: .claude, hookAuthority: true, current: .running),
            .waiting)
        // Everything else is the hooks' business.
        for screen in [idle, working] {
            for current in [AttentionState.running, .ready, .free, .waiting, .error] {
                XCTAssertNil(
                    AttentionState.fromScreen(
                        screen, agent: .claude, hookAuthority: true, current: current),
                    "screen must not move \(current) while hooks are live")
            }
        }
    }

    // Already asking (or errored) → nothing to escalate, and no churn.
    func testBlockerDoesNotRestateAnExistingAlert() {
        XCTAssertNil(
            AttentionState.fromScreen(blocker, agent: .claude, hookAuthority: true, current: .waiting))
        XCTAssertNil(
            AttentionState.fromScreen(blocker, agent: .claude, hookAuthority: true, current: .error))
    }

    // No hook authority (no integration, or an agent that only claims its
    // session): the screen is all we have, so it drives every state.
    func testWithoutHookAuthorityScreenDrivesEverything() {
        XCTAssertEqual(
            AttentionState.fromScreen(working, agent: .codex, hookAuthority: false, current: .free),
            .running)
        XCTAssertEqual(
            AttentionState.fromScreen(blocker, agent: .codex, hookAuthority: false, current: .running),
            .waiting)
        // A finished turn left a result to review.
        XCTAssertEqual(
            AttentionState.fromScreen(idle, agent: .codex, hookAuthority: false, current: .running),
            .ready)
        // An already-quiet terminal stays put — idle is not news.
        XCTAssertNil(
            AttentionState.fromScreen(idle, agent: .codex, hookAuthority: false, current: .free))
        XCTAssertNil(
            AttentionState.fromScreen(idle, agent: .codex, hookAuthority: false, current: .ready))
    }

    // Repeated identical readings must not thrash the state (every change
    // resets stateSince and the escalation timer).
    func testRepeatedReadingsAreStable() {
        XCTAssertNil(
            AttentionState.fromScreen(working, agent: .codex, hookAuthority: false, current: .running))
        XCTAssertNil(
            AttentionState.fromScreen(blocker, agent: .codex, hookAuthority: false, current: .waiting))
    }

    func testNoDetectionChangesNothing() {
        XCTAssertNil(
            AttentionState.fromScreen(nil, agent: .claude, hookAuthority: false, current: .running))
    }
}

final class AgentIntegrationTests: XCTestCase {
    // One script serves every agent, so the command must carry the label and
    // still be recognizable as ours inside a foreign config.
    func testHookCommandCarriesAgentLabel() {
        let cmd = HookInstaller.hookCommand(for: .codex)
        XCTAssertTrue(cmd.hasSuffix(" codex"))
        XCTAssertTrue(HookInstaller.isPlanchetteCommand(cmd))
        XCTAssertEqual(
            HookInstaller.scriptPath(ofCommand: cmd), HookInstaller.hookScriptURL.path)
        // A foreign hook that merely lives in a similar place is not ours.
        XCTAssertFalse(HookInstaller.isPlanchetteCommand("/opt/other/peon.sh claude"))
        // The pre-label form stays recognizable, so upgrades replace it.
        XCTAssertTrue(HookInstaller.isPlanchetteCommand(HookInstaller.hookScriptURL.path))
    }

    func testAgentKindParsesHookLabel() {
        XCTAssertEqual(AgentKind(hookLabel: "claude"), .claude)
        XCTAssertEqual(AgentKind(hookLabel: "Codex"), .codex)
        XCTAssertEqual(AgentKind(hookLabel: "gemini"), .none)
        XCTAssertEqual(AgentKind(hookLabel: nil), .none)
    }

    // Only Claude Code reports every transition; anything else needs the screen
    // to fill the gaps, which is what the fallback layer keys off.
    func testOnlyClaudeReportsFullLifecycle() {
        XCTAssertTrue(AgentKind.claude.reportsFullLifecycle)
        XCTAssertFalse(AgentKind.codex.reportsFullLifecycle)
        XCTAssertFalse(AgentKind.none.reportsFullLifecycle)
    }

    // Codex runs hooks only when the feature is enabled, and its config.toml is
    // the user's file — we edit the one line and touch nothing else.
    func testCodexConfigEnablesHooksFeature() {
        // Fresh file → append the section.
        XCTAssertEqual(
            HookInstaller.codexConfigEnablingHooks(""), "[features]\nhooks = true\n")
        // Existing [features] → insert the key, keep the rest verbatim.
        let existing = "model = \"gpt-5\"\n\n[features]\nweb_search = true\n"
        XCTAssertEqual(
            HookInstaller.codexConfigEnablingHooks(existing),
            "model = \"gpt-5\"\n\n[features]\nhooks = true\nweb_search = true\n")
        // Explicit false → flipped.
        XCTAssertEqual(
            HookInstaller.codexConfigEnablingHooks("[features]\nhooks = false\n"),
            "[features]\nhooks = true\n")
        // Already on → nothing to write.
        XCTAssertNil(HookInstaller.codexConfigEnablingHooks("[features]\nhooks = true\n"))
        // A `hooks` key in someone else's table must not count.
        XCTAssertNotNil(HookInstaller.codexConfigEnablingHooks("[mcp]\nhooks = true\n"))
    }

    // Codex only gets a session claim: a `working` event with no matching
    // `finished` event would leave a terminal purple forever.
    func testCodexInstallsSessionClaimOnly() {
        XCTAssertEqual(HookInstaller.codexEvents, ["SessionStart"])
        XCTAssertTrue(HookInstaller.events.count > HookInstaller.codexEvents.count)
    }
}

final class DropActionTests: XCTestCase {
    private let shot = URL(fileURLWithPath: "/Users/me/Desktop/Screen Shot.png")
    private let doc = URL(fileURLWithPath: "/Users/me/notes.md")

    // The whole point: a screenshot dropped on a live Claude is pasted, not typed.
    func testImagesOnLiveClaudeArePasted() {
        XCTAssertEqual(
            Drop.action(urlString: nil, urls: [shot], string: nil, canPasteImages: true),
            .pasteImages([shot]))
    }

    // No Claude running → ⌃V would be quoted-insert in the shell, so type the path.
    func testImagesWithoutClaudeFallBackToPath() {
        XCTAssertEqual(
            Drop.action(urlString: nil, urls: [shot], string: nil, canPasteImages: false),
            .typeText("/Users/me/Desktop/Screen\\ Shot.png"))
    }

    // A mixed drop stays one consistent line of paths.
    func testMixedDropTypesPaths() {
        XCTAssertEqual(
            Drop.action(urlString: nil, urls: [shot, doc], string: nil, canPasteImages: true),
            .typeText("/Users/me/Desktop/Screen\\ Shot.png /Users/me/notes.md"))
    }

    // Ghostty's precedence for everything that isn't an image drop.
    func testURLBeatsFilesAndStringsStayUnescaped() {
        XCTAssertEqual(
            Drop.action(urlString: "https://a.dev/x y", urls: [doc], string: "s", canPasteImages: true),
            .typeText("https://a.dev/x\\ y"))
        XCTAssertEqual(
            Drop.action(urlString: nil, urls: [], string: "git status", canPasteImages: true),
            .typeText("git status"))
        XCTAssertNil(Drop.action(urlString: nil, urls: [], string: nil, canPasteImages: true))
    }

    func testImageDetectionIsExtensionBasedAndCaseInsensitive() {
        XCTAssertTrue(Drop.isImage(URL(fileURLWithPath: "/a/b.JPEG")))
        XCTAssertTrue(Drop.isImage(URL(fileURLWithPath: "/a/b.webp")))
        XCTAssertFalse(Drop.isImage(URL(fileURLWithPath: "/a/b.pdf")))
        XCTAssertFalse(Drop.isImage(URL(string: "https://a.dev/b.png")!))
    }
}

final class StatusColorTests: XCTestCase {
    // Each state must map to its documented color — this is the whole point of
    // the app (which terminal is idle / in use / waiting / errored).
    func testTintPerState() {
        XCTAssertEqual(AttentionState.ready.tint, Color.green)
        XCTAssertEqual(AttentionState.running.tint, Color.purple)
        XCTAssertEqual(AttentionState.waiting.tint, Color.blue)
        XCTAssertEqual(AttentionState.error.tint, Color.red)
        XCTAssertEqual(AttentionState.free.tint, Color.gray)
    }

    func testEveryStateHasADistinctSymbol() {
        let all: [AttentionState] = [.ready, .running, .waiting, .error, .free]
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count)
    }

    func testInboxContainsOnlyWaitingAndError() {
        XCTAssertTrue(AttentionState.waiting.needsAttention)
        XCTAssertTrue(AttentionState.error.needsAttention)
        XCTAssertFalse(AttentionState.running.needsAttention)
        XCTAssertFalse(AttentionState.ready.needsAttention)
        XCTAssertFalse(AttentionState.free.needsAttention)
    }

    // Hook events → states (the live "in use / waiting / idle" transitions).
    func testHookEventTransitions() {
        XCTAssertEqual(AttentionState.forHookEvent("UserPromptSubmit"), .running)
        XCTAssertEqual(AttentionState.forHookEvent("Notification"), .waiting)
        XCTAssertEqual(AttentionState.forHookEvent("PermissionRequest"), .waiting)
        XCTAssertEqual(AttentionState.forHookEvent("Stop"), .ready)
        XCTAssertEqual(AttentionState.forHookEvent("SubagentStop"), .ready)
        // Claude exited entirely: nothing to review, the terminal is free.
        XCTAssertEqual(AttentionState.forHookEvent("SessionEnd"), .free)
        XCTAssertNil(AttentionState.forHookEvent("whatever"))
    }

    // A conversation that just began has nothing to review and nothing to
    // answer. `/clear` sends SessionEnd(clear) + SessionStart(clear): landing on
    // gray must not depend on both arriving.
    func testFreshSessionStartIsFree() {
        XCTAssertEqual(AttentionState.forHookEvent("SessionStart", source: "clear"), .free)
        XCTAssertEqual(AttentionState.forHookEvent("SessionStart", source: "startup"), .free)
        XCTAssertEqual(AttentionState.forHookEvent("SessionStart", source: "resume"), .free)
    }

    // Compaction and forking happen mid-turn — they must not clear a running
    // or waiting agent.
    func testMidTurnSessionStartKeepsState() {
        XCTAssertNil(AttentionState.forHookEvent("SessionStart", source: "compact"))
        XCTAssertNil(AttentionState.forHookEvent("SessionStart", source: "fork"))
    }

    // The whole hook surface as one table, so a new event or source can't be
    // wired up without a decision being recorded here. Every event Planchette
    // installs (see HookInstaller.events) must appear, and `nil` must be a
    // deliberate "keep the current state", never an oversight.
    func testHookEventTable() {
        let table: [(event: String, source: String?, expected: AttentionState?)] = [
            ("UserPromptSubmit", nil, .running),
            ("Notification", nil, .waiting),
            ("PermissionRequest", nil, .waiting),
            ("Stop", nil, .ready),
            ("SubagentStop", nil, .ready),
            ("SessionEnd", nil, .free),
            // SessionEnd frees the terminal whatever the reason.
            ("SessionEnd", "clear", .free),
            ("SessionStart", "startup", .free),
            ("SessionStart", "clear", .free),
            ("SessionStart", "resume", .free),
            ("SessionStart", "fork", nil),
            ("SessionStart", "compact", nil),
            // An unknown source is a *new* Claude Code source: treat a fresh
            // conversation as free rather than leaving a stale state behind.
            ("SessionStart", "brand-new-source", .free),
            ("SessionStart", nil, .free),
            // Events we don't install must never move the indicator.
            ("PreToolUse", nil, nil),
            ("PostToolUse", nil, nil),
            ("PreCompact", nil, nil),
            ("", nil, nil),
        ]
        for row in table {
            XCTAssertEqual(
                AttentionState.forHookEvent(row.event, source: row.source), row.expected,
                "\(row.event)/\(row.source ?? "-")")
        }
        // Every installed event is covered by the table above.
        let covered = Set(table.map(\.event))
        for event in HookInstaller.events {
            XCTAssertTrue(covered.contains(event), "installed hook \(event) is untested")
        }
    }

    // The command-finish matrix in full: exit code × current state. An agent
    // turn always wins; at the prompt the exit code decides.
    func testCommandFinishTable() {
        let all: [AttentionState] = [.ready, .running, .waiting, .error, .free]
        for current in all {
            for code in [0, 1, 2, 130] {
                let result = AttentionState.afterCommandFinish(exitCode: code, current: current)
                switch (current, code) {
                case (.running, _), (.waiting, _):
                    XCTAssertNil(result, "agent turn must own the indicator (\(current), \(code))")
                case (_, 130):
                    XCTAssertEqual(result, .free, "⌃C is a deliberate stop (\(current))")
                case (_, 0):
                    XCTAssertEqual(result, .ready, "clean exit leaves a result (\(current))")
                default:
                    XCTAssertEqual(result, .error, "non-zero exit is an error (\(current))")
                }
            }
        }
    }

    // A shell command result must never stomp an active agent turn, but at the
    // prompt the exit code decides idle (green) vs error (red).
    func testCommandFinishHonorsAgentTurn() {
        XCTAssertNil(AttentionState.afterCommandFinish(exitCode: 0, current: .running))
        XCTAssertNil(AttentionState.afterCommandFinish(exitCode: 1, current: .running))
        XCTAssertNil(AttentionState.afterCommandFinish(exitCode: 1, current: .waiting))
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 0, current: .ready), .ready)
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 2, current: .ready), .error)
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 1, current: .error), .error)
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 0, current: .error), .ready)
    }

    // Exit 130 (Ctrl+C) is a deliberate stop — not an error, nothing to
    // review: the terminal is free.
    func testCommandFinishTreatsCtrlCAsFree() {
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 130, current: .ready), .free)
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 130, current: .error), .free)
        XCTAssertNil(AttentionState.afterCommandFinish(exitCode: 130, current: .running))
    }

    // A command finishing in a free terminal produced a result to look at.
    func testCommandFinishInFreeTerminal() {
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 0, current: .free), .ready)
        XCTAssertEqual(AttentionState.afterCommandFinish(exitCode: 3, current: .free), .error)
    }

    // Inbox ordering: error is most urgent, free least.
    func testRankOrdering() {
        XCTAssertLessThan(AttentionState.error.rank, AttentionState.waiting.rank)
        XCTAssertLessThan(AttentionState.waiting.rank, AttentionState.running.rank)
        XCTAssertLessThan(AttentionState.running.rank, AttentionState.ready.rank)
        XCTAssertLessThan(AttentionState.ready.rank, AttentionState.free.rank)
    }

    // Old persisted raw values must land on the right modern state.
    func testRawValueMigration() throws {
        func decode(_ raw: String) throws -> AttentionState {
            try JSONDecoder().decode([AttentionState].self, from: Data("[\"\(raw)\"]".utf8))[0]
        }
        XCTAssertEqual(try decode("working"), .running)
        XCTAssertEqual(try decode("asking"), .waiting)
        XCTAssertEqual(try decode("done"), .ready)
        XCTAssertEqual(try decode("ready"), .ready)
        XCTAssertEqual(try decode("free"), .free)
        XCTAssertEqual(try decode("banana"), .free)
    }

    // The one-line "working on…" label from a submitted prompt.
    func testTaskLineFromPrompt() {
        XCTAssertEqual(TerminalSession.taskLine(fromPrompt: "fix the tests\nand more"), "fix the tests")
        XCTAssertEqual(TerminalSession.taskLine(fromPrompt: "  padded  "), "padded")
        XCTAssertNil(TerminalSession.taskLine(fromPrompt: "\n\n"))
        XCTAssertNil(TerminalSession.taskLine(fromPrompt: ""))
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(TerminalSession.taskLine(fromPrompt: long)?.count, 120)
    }
}

final class DisplayTitleTests: XCTestCase {
    private func session(osc: String?, custom: String? = nil) -> TerminalSession {
        var s = TerminalSession(groupID: UUID(), workingDirectory: "/tmp/proj")
        s.oscTitle = osc
        s.customTitle = custom
        return s
    }

    func testStripsLeadingStatusGlyph() {
        XCTAssertEqual(session(osc: "✳ Building app").displayTitle, "Building app")
        XCTAssertEqual(session(osc: "● Deploy").displayTitle, "Deploy")
        XCTAssertFalse(session(osc: "✳ Claude Code").displayTitle.hasPrefix("✳"))
    }

    func testKeepsNormalTitles() {
        XCTAssertEqual(session(osc: "npm run dev").displayTitle, "npm run dev")
    }

    func testCustomTitleWins() {
        XCTAssertEqual(session(osc: "✳ x", custom: "My Title").displayTitle, "My Title")
    }

    func testIdleShellPromptShowsFree() {
        L10n.current = .en
        var s = session(osc: "marcello.alte@PCL2023110901:~/development/mp/x")
        s.state = .free
        XCTAssertEqual(s.displayTitle, "free")
    }

    func testDoneShowsFolderNotFree() {
        var s = session(osc: "marcello.alte@host:~/x")
        s.state = .ready   // finished = result to review, not a free terminal
        XCTAssertEqual(s.displayTitle, "proj")
    }

    func testRunningWithoutTitleShowsFolderNotFree() {
        var s = session(osc: "marcello.alte@host:~/x")
        s.state = .running
        XCTAssertEqual(s.displayTitle, "proj")   // not idle → folder, not "free"
    }

    func testGlyphOnlyIdleShowsFree() {
        L10n.current = .en
        XCTAssertEqual(session(osc: "✳").displayTitle, "free")   // idle by default
    }

    func testShellPromptDetection() {
        XCTAssertTrue(Titles.looksLikeShellPrompt("marcello.alte@PCL2023110901:~/dev"))
        XCTAssertTrue(Titles.looksLikeShellPrompt("user@host:/path"))
        XCTAssertFalse(Titles.looksLikeShellPrompt("npm run dev"))
        XCTAssertFalse(Titles.looksLikeShellPrompt("Implementiere neues Detail"))
        XCTAssertFalse(Titles.looksLikeShellPrompt("build @scope/pkg"))
    }
}

final class RestoreCommandTests: XCTestCase {
    func testResumesExactSessionAndNeverContinues() {
        let cmd = RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "/x",
            startupCommand: nil, claudeSessionID: "abc", resumeClaude: true) ?? ""
        XCTAssertTrue(cmd.contains("claude --resume abc || claude"))
        // Must NOT hijack another terminal's conversation via --continue.
        XCTAssertFalse(cmd.contains("--continue"))
    }

    func testSkipsScrollbackReplayWhenResumingClaude() {
        // Claude redraws its own conversation, so we don't cat its TUI snapshot.
        let cmd = RestoreCommand.input(
            hasScrollback: true, scrollbackPath: "/x",
            startupCommand: nil, claudeSessionID: "abc", resumeClaude: true) ?? ""
        XCTAssertFalse(cmd.contains("cat "))
        XCTAssertTrue(cmd.contains("claude --resume abc"))
    }

    func testReplaysScrollbackForPlainTerminal() {
        let cmd = RestoreCommand.input(
            hasScrollback: true, scrollbackPath: "/tmp/s b.txt",
            startupCommand: nil, claudeSessionID: nil, resumeClaude: true) ?? ""
        XCTAssertTrue(cmd.contains("clear; cat "))
        XCTAssertFalse(cmd.contains("claude"))
    }

    func testEscapesSingleQuotesInPath() {
        let cmd = RestoreCommand.input(
            hasScrollback: true, scrollbackPath: "/a'b.txt",
            startupCommand: nil, claudeSessionID: nil, resumeClaude: false) ?? ""
        XCTAssertTrue(cmd.contains("'/a'\\''b.txt'"))
    }

    func testNoCommandsWhenNothingToRestore() {
        XCTAssertNil(RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "/x",
            startupCommand: nil, claudeSessionID: nil, resumeClaude: true))
    }

    func testStartupCommandIncluded() {
        let cmd = RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "/x",
            startupCommand: "npm run dev", claudeSessionID: nil, resumeClaude: false) ?? ""
        XCTAssertTrue(cmd.contains("npm run dev"))
    }

    // Pending input is re-typed at the prompt WITHOUT a trailing newline (so it
    // never auto-runs), and only for a plain shell.
    func testPendingInputTypedButNotSent() {
        let cmd = RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "/x",
            startupCommand: nil, claudeSessionID: nil, resumeClaude: false,
            pendingInput: "git push") ?? ""
        XCTAssertEqual(cmd, "git push")          // no trailing newline
        XCTAssertFalse(cmd.hasSuffix("\n"))
    }

    func testPendingInputAfterScrollbackReplay() {
        let cmd = RestoreCommand.input(
            hasScrollback: true, scrollbackPath: "/tmp/s.txt",
            startupCommand: nil, claudeSessionID: nil, resumeClaude: false,
            pendingInput: "make test") ?? ""
        XCTAssertTrue(cmd.contains("clear; cat "))
        XCTAssertTrue(cmd.hasSuffix("make test"))  // sits at the prompt after replay
    }

    func testPendingInputSkippedWhenResumingClaude() {
        // Would land in Claude's TUI, not the shell — so we don't inject it.
        let cmd = RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "/x",
            startupCommand: nil, claudeSessionID: "abc", resumeClaude: true,
            pendingInput: "secret") ?? ""
        XCTAssertFalse(cmd.contains("secret"))
    }

    func testPendingInputSkippedWithStartupCommand() {
        let cmd = RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "/x",
            startupCommand: "npm run dev", claudeSessionID: nil, resumeClaude: false,
            pendingInput: "ls") ?? ""
        XCTAssertFalse(cmd.hasSuffix("ls"))
    }
}

final class ClaudeResumeTests: XCTestCase {
    func testEncodedProjectName() {
        XCTAssertEqual(
            ClaudeResume.encodedProjectName("/Users/marcello.alte/development/mp/2nd-designer"),
            "-Users-marcello-alte-development-mp-2nd-designer")
    }

    func testSessionIDFromTranscriptPath() {
        XCTAssertEqual(ClaudeResume.sessionID(fromTranscriptPath: "/a/b/abc-123.jsonl"), "abc-123")
        XCTAssertNil(ClaudeResume.sessionID(fromTranscriptPath: "/a/b/notes.txt"))
        XCTAssertNil(ClaudeResume.sessionID(fromTranscriptPath: "/a/b/.jsonl"))
    }

    private let cwd = "/Users/me/proj"

    private func makeProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ClaudeResume.encodedProjectName(cwd)),
            withIntermediateDirectories: true)
        return root
    }

    private func writeTranscript(_ root: URL, _ id: String, ageSeconds: TimeInterval) throws {
        let url = root.appendingPathComponent(ClaudeResume.encodedProjectName(cwd))
            .appendingPathComponent("\(id).jsonl")
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
    }

    func testPrefersRecordedTranscriptWhenItExists() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "exact-id", ageSeconds: 100)
        try writeTranscript(root, "newer-other", ageSeconds: 1)
        let tp = root.appendingPathComponent(ClaudeResume.encodedProjectName(cwd))
            .appendingPathComponent("exact-id.jsonl").path
        XCTAssertEqual(ClaudeResume.resolveSessionID(
            claudeSessionID: "stale", transcriptPath: tp, currentDirectory: cwd, projectsDir: root), "exact-id")
    }

    // The datadog case: nothing was captured, but the folder has transcripts.
    func testRecoversNewestWhenNothingRecorded() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "old", ageSeconds: 100)
        try writeTranscript(root, "newest", ageSeconds: 1)
        XCTAssertEqual(ClaudeResume.resolveSessionID(
            claudeSessionID: nil, transcriptPath: nil, currentDirectory: cwd, projectsDir: root), "newest")
    }

    func testUsesRecordedIDWhenTranscriptExistsButPathGone() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "known", ageSeconds: 10)
        XCTAssertEqual(ClaudeResume.resolveSessionID(
            claudeSessionID: "known", transcriptPath: "/nope/gone.jsonl", currentDirectory: cwd, projectsDir: root), "known")
    }

    func testStaleIDFallsBackToNewestTranscript() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "actual", ageSeconds: 1)
        XCTAssertEqual(ClaudeResume.resolveSessionID(
            claudeSessionID: "stale-no-file", transcriptPath: nil, currentDirectory: cwd, projectsDir: root), "actual")
    }

    func testNilWhenNoHistoryAtAll() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(ClaudeResume.resolveSessionID(
            claudeSessionID: nil, transcriptPath: nil, currentDirectory: cwd, projectsDir: root))
    }

    // MARK: resolveAll — several tabs of one project must never share a conversation

    private func transcriptPath(_ root: URL, _ id: String) -> String {
        root.appendingPathComponent(ClaudeResume.encodedProjectName(cwd))
            .appendingPathComponent("\(id).jsonl").path
    }

    private func terminal(_ id: String? = nil, _ tp: String? = nil) -> ClaudeResume.Terminal {
        ClaudeResume.Terminal(
            id: UUID(), claudeSessionID: id, transcriptPath: tp, currentDirectory: cwd)
    }

    func testEachTabKeepsItsOwnConversation() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "conv-a", ageSeconds: 100)
        try writeTranscript(root, "conv-b", ageSeconds: 1)
        let a = terminal("conv-a", transcriptPath(root, "conv-a"))
        let b = terminal("conv-b", transcriptPath(root, "conv-b"))
        let resolved = ClaudeResume.resolveAll([a, b], projectsDir: root)
        XCTAssertEqual(resolved[a.id], "conv-a")
        XCTAssertEqual(resolved[b.id], "conv-b")
    }

    // The reported bug's poisoned state: several tabs recorded the SAME id
    // (a past restore converged them). They must come back with DISTINCT
    // conversations — first keeps the shared one, the rest spread onto the
    // project's remaining transcripts, newest first.
    func testTabsPoisonedWithSameIDSpreadOntoDistinctTranscripts() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "shared", ageSeconds: 1)
        try writeTranscript(root, "other-1", ageSeconds: 100)
        try writeTranscript(root, "other-2", ageSeconds: 200)
        let tabs = (0..<3).map { _ in terminal("shared", transcriptPath(root, "shared")) }
        let resolved = ClaudeResume.resolveAll(tabs, projectsDir: root)
        XCTAssertEqual(resolved[tabs[0].id], "shared")
        XCTAssertEqual(resolved[tabs[1].id], "other-1")
        XCTAssertEqual(resolved[tabs[2].id], "other-2")
    }

    // A later tab's exact record must beat an earlier tab's weak fallback —
    // the earlier tab must not steal the later one's conversation.
    func testExactRecordBeatsEarlierTabsFallback() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "newest", ageSeconds: 1)
        try writeTranscript(root, "older", ageSeconds: 100)
        let stale = terminal("gone-id", nil)                              // falls back
        let exact = terminal("newest", transcriptPath(root, "newest"))    // exact match
        let resolved = ClaudeResume.resolveAll([stale, exact], projectsDir: root)
        XCTAssertEqual(resolved[exact.id], "newest")
        XCTAssertEqual(resolved[stale.id], "older")
    }

    // A plain-shell tab (no Claude evidence) next to a Claude tab must not
    // hijack a conversation on restore.
    func testPlainShellTabDoesNotHijackAConversation() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "conv-a", ageSeconds: 1)
        try writeTranscript(root, "conv-old", ageSeconds: 100)
        let claudeTab = terminal("conv-a", transcriptPath(root, "conv-a"))
        let shellTab = terminal()
        let resolved = ClaudeResume.resolveAll([claudeTab, shellTab], projectsDir: root)
        XCTAssertEqual(resolved[claudeTab.id], "conv-a")
        XCTAssertNil(resolved[shellTab.id])
    }

    // A project's SOLE tab without records still recovers the newest
    // transcript (hooks may not have been installed when it was captured).
    func testSoleTabWithoutRecordsStillRecoversNewest() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "only", ageSeconds: 1)
        let tab = terminal()
        let resolved = ClaudeResume.resolveAll([tab], projectsDir: root)
        XCTAssertEqual(resolved[tab.id], "only")
    }

    // More poisoned tabs than transcripts: the leftover tab restores as a
    // plain shell rather than duplicating a conversation another tab owns.
    func testLeftoverPoisonedTabGetsNoConversation() throws {
        let root = try makeProject(); defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root, "shared", ageSeconds: 1)
        let tabs = (0..<2).map { _ in terminal("shared", transcriptPath(root, "shared")) }
        let resolved = ClaudeResume.resolveAll(tabs, projectsDir: root)
        XCTAssertEqual(resolved[tabs[0].id], "shared")
        XCTAssertNil(resolved[tabs[1].id])
    }
}

final class LocalizationTests: XCTestCase {
    func testEveryKeyHasEnglishBase() {
        // English is the fallback table; every key must resolve there.
        L10n.current = .en
        for key in LKey.allCases {
            XCTAssertFalse(L10n.t(key).isEmpty, "missing English string for \(key)")
        }
    }

    func testResolvedNeverReturnsSystem() {
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
    }
}

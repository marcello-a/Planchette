import CryptoKit
import GhosttyKit
import XCTest
@testable import Planchette

// Tests for the performance / stability / security pass. Kept apart from
// LogicTests.swift so each group sits next to the behaviour it guards.

// MARK: - Subprocess

final class SubprocessTests: XCTestCase {
    func testCollectsStdoutAndStatus() throws {
        let result = try XCTUnwrap(Subprocess.run("/bin/echo", ["hello"]))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdoutString, "hello\n")
        XCTAssertFalse(result.timedOut)
    }

    func testReportsANonZeroStatus() throws {
        let result = try XCTUnwrap(Subprocess.run("/usr/bin/false"))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status, 1)
    }

    func testMissingBinaryIsNilNotACrash() {
        XCTAssertNil(Subprocess.run("/nonexistent/tool-\(UUID().uuidString)"))
    }

    // The point of the helper: a hung tool costs its timeout, not forever.
    func testKillsAProcessThatOutlivesItsDeadline() throws {
        let started = Date()
        let result = try XCTUnwrap(Subprocess.run("/bin/sleep", ["30"], timeout: 0.4))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must not wait for the child")
    }

    // A pipe held open by a grandchild does not close when the child dies, so a
    // plain readDataToEndOfFile() would block until the grandchild exits.
    func testDoesNotWaitOnAPipeAGrandchildHoldsOpen() throws {
        let started = Date()
        // The deadline has to cover the shell's own start: on a starved machine 0.5 s was
        // not enough for it to print anything. The grandchild sleeps 20 s, so a run that
        // ends near the deadline still proves it did not wait for the pipe.
        let result = try XCTUnwrap(
            Subprocess.run("/bin/sh", ["-c", "sleep 20 & echo done"], timeout: 4))
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertEqual(result.stdoutString, "done\n", "what was written before the cut survives")
        XCTAssertTrue(result.timedOut, "output cannot be trusted to be complete")
    }

    // Both pipes full at once: reading one to the end before the other deadlocks.
    func testLargeStdoutAndStderrTogetherDoNotDeadlock() throws {
        let script = "yes out | head -c 3000000; yes err | head -c 3000000 1>&2"
        let result = try XCTUnwrap(
            Subprocess.run("/bin/sh", ["-c", script], timeout: 20, stderr: .capture))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 3_000_000)
        XCTAssertEqual(result.stderr.count, 3_000_000)
    }

    func testDiscardedStderrIsNotCollected() throws {
        let result = try XCTUnwrap(
            Subprocess.run("/bin/sh", ["-c", "echo oops 1>&2; echo fine"]))
        XCTAssertEqual(result.stdoutString, "fine\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testRunsInTheGivenDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try XCTUnwrap(Subprocess.run("/bin/pwd", in: dir.path))
        // /var → /private/var: compare resolved paths.
        XCTAssertEqual(
            URL(fileURLWithPath: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath().path,
            dir.resolvingSymlinksInPath().path)
    }

    // A helper must never block on the app's own stdin.
    func testStdinIsClosed() throws {
        let started = Date()
        let result = try XCTUnwrap(Subprocess.run("/bin/cat", timeout: 5))
        XCTAssertTrue(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

// MARK: - Branch lookup without a subprocess

/// `Worktrees.currentBranch` reads HEAD off disk. These pin it to what
/// `git branch --show-current` says for every layout the app meets.
final class HeadBranchTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-head-\(UUID().uuidString)")
        let dir = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repo = dir.path
        try fixtureGit(["init", "-q", "-b", "main"], in: repo)
        try fixtureGit(["config", "user.email", "test@example.com"], in: repo)
        try fixtureGit(["config", "user.name", "Test"], in: repo)
        try "hello".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try fixtureGit(["add", "."], in: repo)
        try fixtureGit(["commit", "-qm", "init"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// What git itself answers — the reference the file read must agree with.
    private func gitSays(_ directory: String) throws -> String? {
        let branch = try fixtureGit(["branch", "--show-current"], in: directory)
        return branch.isEmpty ? nil : branch
    }

    func testAgreesWithGitOnABranch() throws {
        XCTAssertEqual(Worktrees.currentBranch(of: repo), "main")
        try fixtureGit(["checkout", "-q", "-b", "alice/feat/TICKET-1-x"], in: repo)
        XCTAssertEqual(Worktrees.currentBranch(of: repo), "alice/feat/TICKET-1-x")
        XCTAssertEqual(Worktrees.currentBranch(of: repo), try gitSays(repo))
    }

    // The terminal is usually in a package folder, not at the root.
    func testFindsTheRepositoryFromADeepSubdirectory() throws {
        var deep = URL(fileURLWithPath: repo)
        for part in (1...14).map({ "level\($0)" }) { deep.appendPathComponent(part) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        // Deeper than the title code's historical 10 levels — git has no limit,
        // and the branch must not vanish from the sidebar because of the depth.
        XCTAssertEqual(Worktrees.currentBranch(of: deep.path), "main")
        XCTAssertEqual(Worktrees.currentBranch(of: deep.path), try gitSays(deep.path))
    }

    func testDetachedHeadHasNoBranch() throws {
        try fixtureGit(["checkout", "-q", "--detach"], in: repo)
        XCTAssertNil(Worktrees.currentBranch(of: repo))
        XCTAssertNil(try gitSays(repo))
    }

    func testAnUnbornBranchIsStillNamed() throws {
        let fresh = sandbox.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try fixtureGit(["init", "-q", "-b", "trunk"], in: fresh.path)
        XCTAssertEqual(Worktrees.currentBranch(of: fresh.path), "trunk")
        XCTAssertEqual(Worktrees.currentBranch(of: fresh.path), try gitSays(fresh.path))
    }

    func testNoBranchOutsideARepository() {
        let plain = sandbox.appendingPathComponent("not-a-repo")
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertNil(Worktrees.currentBranch(of: plain.path))
        XCTAssertEqual(Titles.headState(forDirectory: plain.path, maxLevels: 64), .notARepository)
    }

    // A linked worktree's `.git` is a FILE pointing at its own git dir; each
    // checkout must report its own branch, not its parent's.
    func testLinkedWorktreesReportTheirOwnBranch() throws {
        let path = try Worktrees.create(repoRoot: repo, branch: "feat/side", base: nil)
        XCTAssertEqual(Worktrees.currentBranch(of: path), "feat/side")
        XCTAssertEqual(Worktrees.currentBranch(of: repo), "main")
        XCTAssertEqual(Worktrees.currentBranch(of: path), try gitSays(path))
    }

    // git's reftable format leaves HEAD as a stub; reading it would show a
    // branch called ".invalid". Only git can answer there.
    func testReftableStubDefersToGit() throws {
        let stub = sandbox.appendingPathComponent("reftable/.git")
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        try "ref: refs/heads/.invalid\n".write(
            to: stub.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            Titles.headState(forDirectory: stub.deletingLastPathComponent().path), .unknown)
    }

    func testTitlesKeepTheirTenLevelWalk() throws {
        var deep = URL(fileURLWithPath: repo)
        for part in (1...12).map({ "d\($0)" }) { deep.appendPathComponent(part) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertEqual(Titles.headState(forDirectory: deep.path), .notARepository,
                       "the title path is unchanged: ten levels, no more")
        XCTAssertEqual(Titles.headState(forDirectory: deep.path, maxLevels: 64), .branch("main"))
    }
}

// MARK: - Poll single-flight

final class SingleFlightTests: XCTestCase {
    func testFirstRequestMayStart() {
        var flight = SingleFlight()
        XCTAssertTrue(flight.begin())
        XCTAssertTrue(flight.isRunning)
    }

    // The whole point: a second tick during a slow poll must not start a copy.
    func testARequestDuringARunDoesNotStartASecondOne() {
        var flight = SingleFlight()
        XCTAssertTrue(flight.begin())
        XCTAssertFalse(flight.begin())
        XCTAssertFalse(flight.begin())
    }

    // ...but it is not lost: the data may have changed after the run read it.
    func testRequestsDuringARunCollapseIntoOneRerun() {
        var flight = SingleFlight()
        _ = flight.begin()
        _ = flight.begin()
        _ = flight.begin()
        XCTAssertTrue(flight.end(), "someone asked while it ran")
        // The rerun starts, finishes, and nobody asked again.
        XCTAssertTrue(flight.begin())
        XCTAssertFalse(flight.end())
        XCTAssertFalse(flight.isRunning)
    }

    func testQuietRunNeedsNoRerun() {
        var flight = SingleFlight()
        XCTAssertTrue(flight.begin())
        XCTAssertFalse(flight.end())
        XCTAssertTrue(flight.begin(), "a finished run frees the slot")
    }
}

// MARK: - Save debounce

final class SaveDebounceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testASingleChangeWaitsTheQuietPeriod() {
        var debounce = SaveDebounce()
        XCTAssertEqual(debounce.delay(changeAt: t0), 1, accuracy: 0.001)
    }

    func testABurstKeepsPushingTheSaveBack() {
        var debounce = SaveDebounce()
        _ = debounce.delay(changeAt: t0)
        XCTAssertEqual(debounce.delay(changeAt: t0.addingTimeInterval(0.5)), 1, accuracy: 0.001)
        XCTAssertEqual(debounce.delay(changeAt: t0.addingTimeInterval(1.2)), 1, accuracy: 0.001)
    }

    // The bug: a busy agent changes something every few hundred ms for minutes,
    // so a pure trailing debounce never saved. The ceiling bounds the wait.
    func testASteadyStreamStillSavesWithinTheCeiling() {
        var debounce = SaveDebounce()
        _ = debounce.delay(changeAt: t0)
        // 9.5 s in, with changes still arriving: only 0.5 s may remain.
        XCTAssertEqual(debounce.delay(changeAt: t0.addingTimeInterval(9.5)), 0.5, accuracy: 0.001)
        // Past the ceiling: save now.
        XCTAssertEqual(debounce.delay(changeAt: t0.addingTimeInterval(11)), 0, accuracy: 0.001)
    }

    func testSavingStartsAFreshWindow() {
        var debounce = SaveDebounce()
        _ = debounce.delay(changeAt: t0)
        _ = debounce.delay(changeAt: t0.addingTimeInterval(9))
        debounce.saved()
        XCTAssertNil(debounce.firstPendingAt)
        XCTAssertEqual(debounce.delay(changeAt: t0.addingTimeInterval(20)), 1, accuracy: 0.001)
    }
}

// MARK: - Title glyphs

final class TitleCleaningTests: XCTestCase {
    func testStripsTheLeadingStatusGlyph() {
        XCTAssertEqual(TerminalSession.cleanedTitle("✳ Claude Code"), "Claude Code")
        XCTAssertEqual(TerminalSession.cleanedTitle("● refactor the sidebar"), "refactor the sidebar")
        XCTAssertEqual(TerminalSession.cleanedTitle("  ⠂ Working"), "Working")
    }

    // The bug: every spinner frame was a different string, so every frame was a
    // "change" that republished the whole UI and rewrote state.json.
    func testAnimatedFramesAreTheSameTitle() {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let cleaned = Set(frames.map { TerminalSession.cleanedTitle("\($0) Claude Code") })
        XCTAssertEqual(cleaned, ["Claude Code"])
    }

    func testGlyphOnlyChangeDoesNotChangeTheSession() {
        var a = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        var b = a
        a.oscTitle = TerminalSession.cleanedTitle("⠋ Claude Code")
        b.oscTitle = TerminalSession.cleanedTitle("⠙ Claude Code")
        XCTAssertEqual(a, b, "update() compares sessions; equal means no publish, no save")
    }

    func testAPlainTitleIsUntouched() {
        XCTAssertEqual(TerminalSession.cleanedTitle("npm run dev"), "npm run dev")
        XCTAssertEqual(TerminalSession.cleanedTitle(""), "")
    }

    // What is shown must not change: the display path now cleans an already
    // clean value, which has to be a no-op.
    func testDisplayIsUnchangedForRawAndCleanedStorage() {
        var raw = TerminalSession(groupID: UUID(), workingDirectory: "/tmp/not-a-repo-\(UUID().uuidString)")
        raw.oscTitle = "✳ Fix the flaky test"
        var cleaned = raw
        cleaned.oscTitle = TerminalSession.cleanedTitle("✳ Fix the flaky test")
        XCTAssertEqual(raw.displayTitle, cleaned.displayTitle)
        XCTAssertEqual(raw.displayTitle, "Fix the flaky test")
    }
}

// MARK: - Working directory of a process, in-process

final class ProcessDirectoryTests: XCTestCase {
    func testReadsOurOwnWorkingDirectory() throws {
        let expected = FileManager.default.currentDirectoryPath
        let found = try XCTUnwrap(DevServerScanner.workingDirectory(ofPID: Int(getpid())))
        XCTAssertEqual(
            URL(fileURLWithPath: found).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: expected).resolvingSymlinksInPath().path)
    }

    func testFollowsAChildThatChangedDirectory() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        child.currentDirectoryURL = URL(fileURLWithPath: "/usr")
        try child.run()
        defer { child.terminate() }
        let found = try XCTUnwrap(
            DevServerScanner.workingDirectory(ofPID: Int(child.processIdentifier)))
        XCTAssertEqual(URL(fileURLWithPath: found).resolvingSymlinksInPath().path, "/usr")
    }

    func testNilForANonexistentOrInvalidProcess() {
        XCTAssertNil(DevServerScanner.workingDirectory(ofPID: 0))
        XCTAssertNil(DevServerScanner.workingDirectory(ofPID: -5))
        XCTAssertNil(DevServerScanner.workingDirectory(ofPID: Int.max))
        XCTAssertNil(DevServerScanner.workingDirectory(ofPID: 2_147_483_000))
    }
}

// MARK: - Support directory permissions

final class SupportPathsSecurityTests: XCTestCase {
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    func testTightensAnOpenDirectoryWeOwn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        SupportPaths.secure(dir)

        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testLeavesAnAlreadyPrivateDirectoryAlone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        SupportPaths.secure(dir)
        XCTAssertEqual(try mode(dir), 0o700)
    }

    // An override that points at someone else's directory (or /tmp) must never
    // be chmod'ed. /private/var is root's.
    func testNeverTouchesADirectoryAnotherUserOwns() throws {
        let rootOwned = URL(fileURLWithPath: "/private/var")
        let before = try mode(rootOwned)
        SupportPaths.secure(rootOwned)
        XCTAssertEqual(try mode(rootOwned), before)
    }

    func testMissingDirectoryIsANoOp() {
        SupportPaths.secure(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    }
}

// MARK: - Hook server I/O

final class HookServerIOTests: XCTestCase {
    /// A connected pair of unix sockets: (server side, client side).
    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        // The test writers outlive the reader they feed; a write after the other
        // end closed must fail with EPIPE, not kill the test process with SIGPIPE
        // (the app gets the same protection from `admit`).
        var on: Int32 = 1
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return (fds[0], fds[1])
    }

    private func send(_ text: String, on fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    func testReadsEverythingUntilTheClientCloses() throws {
        let (server, client) = try pair()
        defer { close(server) }
        send(#"{"a":1}"#, on: client)
        close(client)
        let data = HookServer.readPayload(from: server, deadline: 2, maxBytes: 1024)
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, #"{"a":1}"#)
    }

    // macOS `nc` cannot half-close: a hook client may send a full event and then
    // simply stay connected. It must still be served — at the deadline.
    func testServesAClientThatNeverCloses() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        send(#"{"hook":"Stop"}"#, on: client)
        let started = Date()
        let data = HookServer.readPayload(from: server, deadline: 0.4, maxBytes: 1024)
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, #"{"hook":"Stop"}"#)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // The bug a per-read timeout allows: one byte every few seconds, forever.
    func testASlowTrickleCannotHoldTheReaderPastTheDeadline() throws {
        let (server, client) = try pair()
        defer { close(server) }
        let trickle = Thread {
            for _ in 0..<40 {
                self.send("x", on: client)
                Thread.sleep(forTimeInterval: 0.1)
            }
            close(client)
        }
        trickle.start()
        let started = Date()
        let data = HookServer.readPayload(from: server, deadline: 0.5, maxBytes: 1024)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the deadline covers the whole read")
        XCTAssertNotNil(data)
        XCTAssertLessThan(data?.count ?? 99, 20)
    }

    func testDropsAPayloadOverTheCap() throws {
        let (server, client) = try pair()
        defer { close(server) }
        let writer = Thread {
            send: for _ in 0..<64 {
                self.send(String(repeating: "a", count: 1024), on: client)
                continue send
            }
            close(client)
        }
        writer.start()
        XCTAssertNil(HookServer.readPayload(from: server, deadline: 2, maxBytes: 4096),
                     "half a request is not a request")
    }

    func testEmptyConnectionYieldsEmptyData() throws {
        let (server, client) = try pair()
        defer { close(server) }
        close(client)
        XCTAssertEqual(HookServer.readPayload(from: server, deadline: 1, maxBytes: 64)?.count, 0)
    }

    // Our own process is, by definition, the current user.
    func testAPeerRunningAsUsIsAccepted() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        XCTAssertTrue(HookServer.peerIsCurrentUser(server))
    }

    func testAnInvalidDescriptorIsNotAPermittedPeer() {
        XCTAssertFalse(HookServer.peerIsCurrentUser(-1))
    }

    func testPayloadLimitsAreSane() {
        XCTAssertGreaterThanOrEqual(HookServer.maxPayloadBytes, 1 << 20)
        XCTAssertGreaterThan(HookServer.maxConcurrentConnections, 8)
        XCTAssertGreaterThan(HookServer.maxPendingRequests, 8)
        XCTAssertLessThanOrEqual(HookServer.readDeadline, 30)
    }
}

// MARK: - The hook script and the CLI, against a real socket

/// A one-shot unix-socket server for driving the shipped scripts. Binds a short
/// path in /tmp (sun_path is only 104 bytes), accepts once, reads to EOF, and
/// optionally answers.
private final class FakeApp {
    let path = "/tmp/plt-\(UUID().uuidString.prefix(8)).sock"
    private var listener: Int32 = -1
    private let done = DispatchSemaphore(value: 0)
    private(set) var received = Data()
    private let reply: Data?

    init(reply: Data? = nil) throws {
        self.reply = reply
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyBytes(from: $0.prefix(buf.count - 1)) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            throw NSError(domain: "FakeApp", code: Int(errno))
        }
        Thread.detachNewThread { [self] in serve() }
    }


    // How long a slow machine may need before the script connects: under heavy load a
    // Python start alone took minutes. A test that expects no connection calls `stop()`.
    private let gate = NSLock()
    private var stopped = false
    func stop() { gate.lock(); stopped = true; gate.unlock() }
    private var isStopped: Bool { gate.lock(); defer { gate.unlock() }; return stopped }

    private func acceptScript() -> Int32 {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !isStopped {
            var watch = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&watch, 1, 200) > 0 { return accept(listener, nil, nil) }
        }
        return -1
    }

    private func serve() {
        defer { done.signal() }
        let client = acceptScript()
        guard client >= 0 else { return }
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var p = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 30_000) > 0 else { break }
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            received.append(buffer, count: n)
        }
        if let reply {
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        }
    }

    func waitUntilServed() { _ = done.wait(timeout: .now() + 120) }

    deinit {
        if listener >= 0 { close(listener) }
        unlink(path)
    }
}

final class HookScriptTests: XCTestCase {
    private var repoRoot: URL {
        // …/macos/Planchette/Tests/PlanchetteTests/HardeningTests.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func script(_ name: String) throws -> String {
        let path = repoRoot.appendingPathComponent("hook/\(name)").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("\(path) not found")
        }
        return path
    }

    /// A HOME with nothing in it, so a developer's real ~/.planchette/socket
    /// pointer can never be picked up by a test.
    private func emptyHome() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home.path
    }

    private func run(
        _ executable: String, _ arguments: [String], env: [String: String], stdin: String? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String, seconds: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        environment.merge(env) { $1 }
        process.environment = environment
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        let started = Date()
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            Date().timeIntervalSince(started))
    }

    // The happy path: the shipped hook still delivers a wrapped event to a socket
    // this user owns, quickly.
    func testHookDeliversTheWrappedEventToOurOwnSocket() throws {
        let hook = try script("planchette-hook")
        let app = try FakeApp()
        let session = UUID().uuidString
        let result = try run(
            "/bin/sh", [hook, "claude"],
            env: ["PLANCHETTE_SESSION": session, "PLANCHETTE_SOCKET": app.path, "HOME": try emptyHome()],
            stdin: #"{"hook_event_name":"Stop","session_id":"abc"}"#)
        app.waitUntilServed()
        XCTAssertEqual(result.status, 0, "a hook must always exit 0")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: app.received) as? [String: Any],
            String(decoding: app.received, as: UTF8.self))
        XCTAssertEqual(json["planchette_session"] as? String, session)
        XCTAssertEqual(json["agent"] as? String, "claude")
        XCTAssertEqual((json["event"] as? [String: Any])?["hook_event_name"] as? String, "Stop")
        XCTAssertLessThan(result.seconds, 4, "the hook must not linger on the connection")
    }

    func testHookIsANoOpOutsideAPlanchetteTerminal() throws {
        let hook = try script("planchette-hook")
        let result = try run("/bin/sh", [hook, "claude"],
                             env: ["HOME": try emptyHome()], stdin: "{}")
        XCTAssertEqual(result.status, 0)
    }

    // The reason for the owner check: a socket someone else owns must never be
    // handed an event. /var/run/mDNSResponder is a real socket owned by root.
    func testHookRefusesASocketOwnedBySomeoneElse() throws {
        let hook = try script("planchette-hook")
        let foreign = "/var/run/mDNSResponder"
        var info = stat()
        guard stat(foreign, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid != getuid()
        else { throw XCTSkip("no foreign-owned socket available on this machine") }
        // If the hook tried to connect, `nc` would be left talking to mDNSResponder
        // and take a moment; refusing is immediate and silent. The hook's own
        // contract (always exit 0) must hold either way.
        let result = try run(
            "/bin/sh", ["-x", hook, "claude"],
            env: ["PLANCHETTE_SESSION": UUID().uuidString, "PLANCHETTE_SOCKET": foreign,
                  "HOME": try emptyHome()],
            stdin: "{}")
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.stderr.contains("nc -U"),
                       "must not connect to a foreign socket:\n\(result.stderr)")
    }

    func testCLIAnswersFromOurOwnSocket() throws {
        let cli = try script("planchette")
        let app = try FakeApp(reply: Data(#"{"ok": true, "result": {"sessions": []}}"#.utf8))
        let result = try run(
            "/usr/bin/env", ["python3", cli, "session", "list"],
            env: ["PLANCHETTE_SOCKET": app.path, "PLANCHETTE_SESSION": UUID().uuidString,
                  "HOME": try emptyHome()])
        app.waitUntilServed()
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"ok\": true"), result.stdout)
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: app.received) as? [String: Any])
        XCTAssertEqual(request["planchette_request"] as? String, "session.list")
    }

    func testCLIRefusesASocketOwnedBySomeoneElse() throws {
        let cli = try script("planchette")
        let foreign = "/var/run/mDNSResponder"
        var info = stat()
        guard stat(foreign, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid != getuid()
        else { throw XCTSkip("no foreign-owned socket available on this machine") }
        let result = try run(
            "/usr/bin/env", ["python3", cli, "session", "list"],
            env: ["PLANCHETTE_SOCKET": foreign, "HOME": try emptyHome()])
        XCTAssertEqual(result.status, 2, "unreachable is exit 2")
        XCTAssertTrue(result.stderr.contains("not a socket owned by you"), result.stderr)
    }

    func testCLIRefusesAPlainFileInsteadOfASocket() throws {
        let cli = try script("planchette")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-notasocket-\(UUID().uuidString)")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try run(
            "/usr/bin/env", ["python3", cli, "session", "list"],
            env: ["PLANCHETTE_SOCKET": file.path, "HOME": try emptyHome()])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("not a socket owned by you"), result.stderr)
    }

    // The race the reviewer found: `[ -S ]` and `[ -O ]` follow symlinks, so a link
    // to MY OWN live socket passes both — and can be swapped for someone else's
    // listener before `nc` connects. A link is refused outright; /tmp's sticky bit
    // then guarantees that a real socket that passed is still the same file.
    func testHookRefusesASymlinkToOurOwnSocket() throws {
        let hook = try script("planchette-hook")
        let app = try FakeApp()
        defer { app.stop() }
        let link = "/tmp/plt-link-\(UUID().uuidString.prefix(8)).sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: app.path)
        defer { unlink(link) }
        let result = try run(
            "/bin/sh", ["-x", hook, "claude"],
            env: ["PLANCHETTE_SESSION": UUID().uuidString, "PLANCHETTE_SOCKET": link,
                  "HOME": try emptyHome()],
            stdin: "{}")
        XCTAssertEqual(result.status, 0, "a hook always exits 0")
        XCTAssertFalse(result.stderr.contains("nc -U"),
                       "must not connect through a symlink:\n\(result.stderr)")
    }

    func testCLIRefusesASymlinkToOurOwnSocket() throws {
        let cli = try script("planchette")
        let app = try FakeApp(reply: Data(#"{"ok": true, "result": {}}"#.utf8))
        defer { app.stop() }
        let link = "/tmp/plt-link-\(UUID().uuidString.prefix(8)).sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: app.path)
        defer { unlink(link) }
        let result = try run(
            "/usr/bin/env", ["python3", cli, "session", "list"],
            env: ["PLANCHETTE_SOCKET": link, "HOME": try emptyHome()])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("not a socket owned by you"), result.stderr)
    }

    // After the connect, the kernel's word about who is listening is the one that
    // counts (LOCAL_PEERCRED) — the path checks cannot close the check-then-connect
    // gap on their own.
    func testCLIPeerCheckAcceptsUsAndRejectsAnotherUid() throws {
        let cli = try script("planchette")
        let probe = """
            import importlib.machinery, importlib.util, os, socket, struct, sys
            loader = importlib.machinery.SourceFileLoader("planchette_cli", sys.argv[1])
            spec = importlib.util.spec_from_loader("planchette_cli", loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
            mine, _other = socket.socketpair()
            print("mine", module.peer_is_me(mine))
            class Foreign:
                def getsockopt(self, *args):
                    return struct.pack("=II", 0, os.getuid() + 1) + b"\\0" * 68
            print("foreign", module.peer_is_me(Foreign()))
            """
        let result = try run("/usr/bin/env", ["python3", "-c", probe, cli], env: ["HOME": try emptyHome()])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("mine True"), result.stdout)
        XCTAssertTrue(result.stdout.contains("foreign False"), result.stdout)
    }
}

// MARK: - Updater: checksums

final class UpdateChecksumTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)

    func testReadsATextModeLine() {
        XCTAssertEqual(
            UpdateService.checksum(in: "\(digest)  Planchette.zip\n", for: "Planchette.zip"), digest)
    }

    // `shasum -b` writes "hash *name". Reading the star as part of the name made a
    // valid file look like "no checksum for this download", which aborts the update.
    func testReadsABinaryModeLine() {
        XCTAssertEqual(
            UpdateService.checksum(in: "\(digest) *Planchette.zip", for: "Planchette.zip"), digest)
    }

    func testPicksTheRequestedFileOutOfSeveral() {
        let other = String(repeating: "cd", count: 32)
        let text = """
        \(other)  Planchette.dmg
        \(digest)  Planchette.zip
        \(other)  screen-rules.json
        """
        XCTAssertEqual(UpdateService.checksum(in: text, for: "Planchette.zip"), digest)
        XCTAssertEqual(UpdateService.checksum(in: text, for: "screen-rules.json"), other)
    }

    func testNormalisesTheCaseOfTheDigest() {
        XCTAssertEqual(
            UpdateService.checksum(in: "\(digest.uppercased())  a.zip", for: "a.zip"), digest)
    }

    func testAMissingEntryIsNil() {
        XCTAssertNil(UpdateService.checksum(in: "\(digest)  Other.zip", for: "Planchette.zip"))
        XCTAssertNil(UpdateService.checksum(in: "", for: "Planchette.zip"))
    }

    // Only the whole name counts: a signature file beside the archive is not it.
    func testANameThatMerelyEndsTheSameDoesNotMatch() {
        XCTAssertNil(
            UpdateService.checksum(in: "\(digest)  Planchette.zip.sig", for: "Planchette.zip"))
        XCTAssertNil(
            UpdateService.checksum(in: "\(digest)  old-Planchette.zip", for: "Planchette.zip"))
    }

    // An HTML error page is not a checksum file, whatever it contains.
    func testRejectsALineWhoseFirstFieldIsNotADigest() {
        XCTAssertNil(UpdateService.checksum(in: "<html> Planchette.zip", for: "Planchette.zip"))
        XCTAssertNil(UpdateService.checksum(in: "abc123  Planchette.zip", for: "Planchette.zip"))
        XCTAssertNil(UpdateService.checksum(
            in: "\(String(repeating: "zz", count: 32))  Planchette.zip", for: "Planchette.zip"))
    }

    func testSkipsBlankAndShortLines() {
        let text = "\n\n   \nlonely\n\(digest)  Planchette.zip\n"
        XCTAssertEqual(UpdateService.checksum(in: text, for: "Planchette.zip"), digest)
    }
}

// MARK: - Updater: streaming hash

final class UpdateHashTests: XCTestCase {
    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-hash-\(UUID().uuidString)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testKnownDigest() throws {
        let url = try tempFile(Data("abc".utf8))
        XCTAssertEqual(
            try UpdateService.sha256(ofFileAt: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // Bigger than one read chunk, and not a multiple of it: the loop's tail matters.
    func testAMultiChunkFileMatchesTheOneShotDigest() throws {
        var bytes = [UInt8](repeating: 0, count: (5 << 20) + 12_345)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
        let data = Data(bytes)
        let url = try tempFile(data)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try UpdateService.sha256(ofFileAt: url), expected)
    }

    func testAnEmptyFileHasTheEmptyDigest() throws {
        let url = try tempFile(Data())
        XCTAssertEqual(
            try UpdateService.sha256(ofFileAt: url),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAMissingFileThrowsInsteadOfHashingNothing() {
        XCTAssertThrowsError(
            try UpdateService.sha256(
                ofFileAt: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")))
    }
}

// MARK: - Updater: what is allowed to replace the running app

final class UpdateBundleVerificationTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// A minimal real app bundle: a Mach-O executable, an Info.plist and one
    /// sealed resource, optionally ad-hoc signed.
    private func makeApp(
        identifier: String = "build.planchette.app", version: String = "9.9.9",
        sign: Bool = true, in directory: URL? = nil
    ) throws -> URL {
        let parent = directory ?? sandbox.appendingPathComponent("app-\(UUID().uuidString)")
        let app = parent.appendingPathComponent("Planchette.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Planchette"))
        try "sealed".write(
            to: resources.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
            "CFBundleVersion": "1", "CFBundleExecutable": "Planchette",
            "CFBundlePackageType": "APPL", "CFBundleName": "Planchette",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign {
            let result = try XCTUnwrap(Subprocess.run(
                "/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path],
                timeout: 60, stderr: .capture))
            XCTAssertTrue(result.succeeded, result.stderrString)
        }
        return app
    }

    private func verify(
        _ app: URL, identifier: String? = "build.planchette.app",
        version: String = "9.9.9", current: String = "0.2.34"
    ) throws {
        try UpdateService.verifyBundle(
            app, bundleIdentifier: identifier, version: version, currentVersion: current)
    }

    func testAcceptsANewerIntactBuildOfThisApp() throws {
        XCTAssertNoThrow(try verify(try makeApp()))
    }

    func testRejectsAnotherAppsIdentity() throws {
        let app = try makeApp(identifier: "com.example.other")
        XCTAssertThrowsError(try verify(app))
    }

    // The tag says 9.9.9; a bundle that says otherwise is a mislabelled release
    // (or an old build served under a new name).
    func testRejectsAVersionThatDoesNotMatchTheRelease() throws {
        let app = try makeApp(version: "9.9.8")
        XCTAssertThrowsError(try verify(app, version: "9.9.9"))
    }

    // A rollback: the release is "new" by its tag, but the bundle is not.
    func testRejectsABundleThatIsNotNewerThanTheRunningApp() throws {
        let app = try makeApp(version: "0.2.34")
        XCTAssertThrowsError(try verify(app, version: "0.2.34", current: "0.2.34"))
        let older = try makeApp(version: "0.1.0")
        XCTAssertThrowsError(try verify(older, version: "0.1.0", current: "0.2.34"))
    }

    func testRejectsAnUnsignedBundle() throws {
        let app = try makeApp(sign: false)
        XCTAssertThrowsError(try verify(app))
    }

    // The integrity check: a sealed file changed after signing. This is what a
    // truncated or damaged extraction looks like.
    func testRejectsABundleModifiedAfterSigning() throws {
        let app = try makeApp()
        try "tampered".write(
            to: app.appendingPathComponent("Contents/Resources/data.txt"),
            atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try verify(app))
    }

    func testRejectsABundleWithoutItsExecutable() throws {
        let app = try makeApp()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/Planchette"))
        XCTAssertThrowsError(try verify(app))
    }

    func testRejectsADirectoryThatIsNotABundle() throws {
        let plain = sandbox.appendingPathComponent("Planchette.app")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertThrowsError(try verify(plain))
    }

    // End to end through the real archive format the release ships.
    func testExtractsAndVerifiesAZippedBuild() throws {
        let app = try makeApp()
        let zip = sandbox.appendingPathComponent("Planchette.zip")
        let made = try XCTUnwrap(Subprocess.run(
            "/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path], stderr: .capture))
        XCTAssertTrue(made.succeeded, made.stderrString)
        let work = sandbox.appendingPathComponent("\(UpdateService.workDirPrefix)\(UUID().uuidString)")
        let extracted = try UpdateService.extractAndVerify(
            zip: zip, into: work, bundleIdentifier: "build.planchette.app",
            version: "9.9.9", currentVersion: "0.2.34")
        XCTAssertEqual(extracted.lastPathComponent, "Planchette.app")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("Contents/Info.plist").path))
    }

    func testAnArchiveThatIsNotAZipIsRejected() throws {
        let junk = sandbox.appendingPathComponent("junk.zip")
        try Data("not a zip".utf8).write(to: junk)
        let work = sandbox.appendingPathComponent("\(UpdateService.workDirPrefix)x")
        XCTAssertThrowsError(try UpdateService.extractAndVerify(
            zip: junk, into: work, bundleIdentifier: nil, version: "9.9.9", currentVersion: "0.2.34"))
    }

    func testAnArchiveWithoutAnAppIsRejected() throws {
        let folder = sandbox.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let zip = sandbox.appendingPathComponent("noapp.zip")
        _ = Subprocess.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path])
        let work = sandbox.appendingPathComponent("\(UpdateService.workDirPrefix)y")
        XCTAssertThrowsError(try UpdateService.extractAndVerify(
            zip: zip, into: work, bundleIdentifier: nil, version: "9.9.9", currentVersion: "0.2.34"))
    }
}

// MARK: - Updater: download rules, against a real (local) HTTP server

/// A tiny HTTP/1.1 server on 127.0.0.1 for driving the downloader.
private final class LocalHTTP {
    struct Route {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    private(set) var port: UInt16 = 0
    private var listener: Int32 = -1
    private var routes: [String: Route]
    private let lock = NSLock()
    private var running = true

    init(routes: [String: Route]) throws {
        self.routes = routes
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            throw NSError(domain: "LocalHTTP", code: Int(errno))
        }
        var actual = sockaddr_in()
        var len = size
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func setRoute(_ path: String, _ route: Route) {
        lock.lock(); routes[path] = route; lock.unlock()
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        close(listener)
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let go = running; lock.unlock()
            guard go else { return }
            var watch = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&watch, 1, 200) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(Data("\r\n\r\n".utf8)) {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }
            request.append(buffer, count: count)
        }
        let line = String(decoding: request.prefix(while: { $0 != 0x0D }), as: UTF8.self)
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock(); let route = routes[path]; lock.unlock()
        let found = route ?? Route(status: 404, body: Data("not found".utf8))
        var head = "HTTP/1.1 \(found.status) X\r\nContent-Length: \(found.body.count)\r\nConnection: close\r\n"
        for (key, value) in found.headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        send(Data(head.utf8), to: client)
        send(found.body, to: client)
    }

    private func send(_ data: Data, to client: Int32) {
        var offset = 0
        data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

final class UpdateDownloadTests: XCTestCase {
    private func download(_ url: URL, maxBytes: Int64 = 1 << 20) async throws -> URL {
        try await Downloader.download(url, maxBytes: maxBytes) { _ in }
    }

    func testDownloadsAFileAndReturnsItsBytes() async throws {
        let payload = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })
        let server = try LocalHTTP(routes: ["/ok": .init(body: payload)])
        defer { server.stop() }
        let file = try await download(server.url("/ok"))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    // An error page used to be saved as if it were the archive and handed on to
    // the checksum step as "the download".
    func testANon200AnswerIsAFailureNotAFile() async throws {
        let server = try LocalHTTP(routes: [:])
        defer { server.stop() }
        do {
            let file = try await download(server.url("/missing"))
            try? FileManager.default.removeItem(at: file)
            XCTFail("a 404 must not produce a download")
        } catch {}
    }

    // The redirect target here is a perfectly working server — it is refused only
    // because it is not GitHub over HTTPS. If the redirect were followed this
    // download would succeed.
    func testARedirectOffGitHubIsNotFollowed() async throws {
        let elsewhere = try LocalHTTP(routes: ["/ok": .init(body: Data("payload".utf8))])
        defer { elsewhere.stop() }
        let server = try LocalHTTP(routes: [
            "/go": .init(status: 302, headers: ["Location": elsewhere.url("/ok").absoluteString]),
        ])
        defer { server.stop() }
        do {
            let file = try await download(server.url("/go"))
            try? FileManager.default.removeItem(at: file)
            XCTFail("a redirect to an untrusted host must not be followed")
        } catch {}
    }

    func testAnOversizedFileIsCutOff() async throws {
        let server = try LocalHTTP(routes: ["/huge": .init(body: Data(count: 4 << 20))])
        defer { server.stop() }
        do {
            let file = try await download(server.url("/huge"), maxBytes: 1 << 20)
            try? FileManager.default.removeItem(at: file)
            XCTFail("a download over the cap must be refused")
        } catch {}
    }

    // The default cap is a ceiling for a real release, not a tight bound.
    func testTheDefaultCapLeavesRoomForARealRelease() {
        XCTAssertGreaterThanOrEqual(UpdateService.maxDownloadBytes, 100 << 20)
    }
}

// MARK: - Updater: temp-folder hygiene

final class UpdateCleanupTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func make(_ name: String, age: TimeInterval) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private var exists: (URL) -> Bool { { FileManager.default.fileExists(atPath: $0.path) } }

    func testRemovesOnlyOldFilesOfItsOwn() throws {
        let oldWork = try make("planchette-update-aaa", age: 3 * 86_400)
        let oldZip = try make("planchette-dl-bbb.zip", age: 3 * 86_400)
        let oldScript = try make("planchette-swap-ccc.sh", age: 3 * 86_400)
        let fresh = try make("planchette-update-new", age: 60)
        let foreign = try make("somebody-elses-folder", age: 30 * 86_400)
        let lookalike = try make("not-planchette-update-x", age: 30 * 86_400)

        UpdateService.cleanStaleArtifacts(in: sandbox)

        XCTAssertFalse(exists(oldWork))
        XCTAssertFalse(exists(oldZip))
        XCTAssertFalse(exists(oldScript))
        XCTAssertTrue(exists(fresh), "a download in progress is not stale")
        XCTAssertTrue(exists(foreign), "never touch what is not ours")
        XCTAssertTrue(exists(lookalike), "the prefix must be at the start of the name")
    }

    // An update staged for the next quit can sit for days; it is not garbage.
    func testKeepsTheBundleAStagedUpdateStillNeeds() throws {
        let staged = try make("planchette-update-keepme", age: 10 * 86_400)
        let bundle = staged.appendingPathComponent("Planchette.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let other = try make("planchette-update-dropme", age: 10 * 86_400)

        UpdateService.cleanStaleArtifacts(in: sandbox, keeping: bundle.path)

        XCTAssertTrue(exists(staged))
        XCTAssertFalse(exists(other))
    }

    func testStagedBundlePathMustBeOurOwnExtraction() throws {
        let tmp = sandbox!
        let good = tmp.appendingPathComponent("\(UpdateService.workDirPrefix)abc/Planchette.app").path
        XCTAssertTrue(UpdateService.isStagedBundlePath(good, temporaryDirectory: tmp))
        // Not in the temp folder.
        XCTAssertFalse(UpdateService.isStagedBundlePath(
            "/Applications/Planchette.app", temporaryDirectory: tmp))
        // In it, but not a directory this updater made.
        XCTAssertFalse(UpdateService.isStagedBundlePath(
            tmp.appendingPathComponent("elsewhere/Planchette.app").path, temporaryDirectory: tmp))
        // Not an app.
        XCTAssertFalse(UpdateService.isStagedBundlePath(
            tmp.appendingPathComponent("\(UpdateService.workDirPrefix)abc/other").path,
            temporaryDirectory: tmp))
        // A traversal out of the work directory.
        XCTAssertFalse(UpdateService.isStagedBundlePath(
            tmp.appendingPathComponent("\(UpdateService.workDirPrefix)abc/../../x/Planchette.app").path,
            temporaryDirectory: tmp))
    }
}

// MARK: - Agent config files: symlinks, backups, idempotence

final class HookInstallerFilesTests: XCTestCase {
    private var sandbox: URL!
    private let command = "/Users/test/.planchette/planchette-hook claude"

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    // The bug: an atomic write replaced a dotfile-managed symlink with a regular
    // file, so the dotfiles repo stopped tracking settings.json and never saw the
    // hooks.
    func testASymlinkedSettingsFileStaysASymlinkAndTheTargetIsUpdated() throws {
        let target = sandbox.appendingPathComponent("dotfiles/claude/settings.json")
        try write(#"{"model": "opus", "env": {"A": "1"}}"#, to: target)
        let link = sandbox.appendingPathComponent("home/.claude/settings.json")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try HookInstaller.mergeSettings(at: link, hookCmd: command)

        XCTAssertTrue(isSymlink(link), "the link must survive")
        let merged = try json(target)
        XCTAssertEqual(merged["model"] as? String, "opus", "other settings are kept")
        XCTAssertEqual((merged["env"] as? [String: String])?["A"], "1")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        for event in HookInstaller.events {
            XCTAssertNotNil(hooks[event], "\(event) must be wired up")
        }
    }

    // A "backup" that is itself a link to the rewritten file protects nothing.
    func testTheBackupHoldsTheOriginalContentEvenForASymlink() throws {
        let target = sandbox.appendingPathComponent("dotfiles/settings.json")
        let original = #"{"model": "opus"}"#
        try write(original, to: target)
        let link = sandbox.appendingPathComponent("home/.claude/settings.json")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try HookInstaller.mergeSettings(at: link, hookCmd: command)

        let backup = link.deletingLastPathComponent()
            .appendingPathComponent("settings.json.planchette-bak")
        XCTAssertFalse(isSymlink(backup), "a copy of the file, not a second link to it")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
    }

    func testAPlainSettingsFileIsMergedAndBackedUp() throws {
        let file = sandbox.appendingPathComponent(".claude/settings.json")
        try write(#"{"theme": "dark"}"#, to: file)
        try HookInstaller.mergeSettings(at: file, hookCmd: command)
        XCTAssertEqual(try json(file)["theme"] as? String, "dark")
        XCTAssertNotNil(try json(file)["hooks"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent()
                .appendingPathComponent("settings.json.planchette-bak").path))
    }

    func testRunningTwiceChangesNothing() throws {
        let file = sandbox.appendingPathComponent(".claude/settings.json")
        try write("{}", to: file)
        try HookInstaller.mergeSettings(at: file, hookCmd: command)
        let first = try Data(contentsOf: file)
        try HookInstaller.mergeSettings(at: file, hookCmd: command)
        XCTAssertEqual(try Data(contentsOf: file), first)
    }

    func testForeignHooksAreKept() throws {
        let file = sandbox.appendingPathComponent(".claude/settings.json")
        try write("""
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"}]}]}}
            """, to: file)
        try HookInstaller.mergeSettings(at: file, hookCmd: command)
        let stop = try XCTUnwrap(
            (try json(file)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("/usr/local/bin/other-tool"))
        XCTAssertTrue(commands.contains(command))
    }

    // A file we cannot parse is the user's, not ours to rewrite.
    func testAnUnparseableFileIsLeftExactlyAsItWas() throws {
        let file = sandbox.appendingPathComponent(".claude/settings.json")
        let broken = "{ this is not json "
        try write(broken, to: file)
        try HookInstaller.mergeSettings(at: file, hookCmd: command)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
    }

    func testAMissingFileIsCreated() throws {
        let file = sandbox.appendingPathComponent("fresh/.claude/settings.json")
        try HookInstaller.mergeSettings(at: file, hookCmd: command)
        XCTAssertNotNil(try json(file)["hooks"])
    }

    func testCodexHooksFileKeepsItsSymlink() throws {
        let target = sandbox.appendingPathComponent("dotfiles/codex-hooks.json")
        try write(#"{"hooks": {}}"#, to: target)
        let codex = sandbox.appendingPathComponent("home/.codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let link = codex.appendingPathComponent("hooks.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try HookInstaller.mergeCodexHooks(
            dir: codex, hookCmd: "/Users/test/.planchette/planchette-hook codex")

        XCTAssertTrue(isSymlink(link))
        let hooks = try XCTUnwrap(try json(target)["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
    }

    func testCodexConfigTomlKeepsItsSymlink() throws {
        let target = sandbox.appendingPathComponent("dotfiles/config.toml")
        try write("model = \"gpt\"\n", to: target)
        let codex = sandbox.appendingPathComponent("home/.codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let link = codex.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try HookInstaller.enableCodexHooksFeature(dir: codex)

        XCTAssertTrue(isSymlink(link))
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("model = \"gpt\""))
        XCTAssertTrue(text.contains("hooks = true"))
    }
}

// MARK: - Clipboard confirmations

final class ClipboardConfirmationTests: XCTestCase {
    func testMapsLibghosttyRequestsToKinds() {
        XCTAssertEqual(ClipboardConfirmation.Kind(GHOSTTY_CLIPBOARD_REQUEST_PASTE), .unsafePaste)
        XCTAssertEqual(ClipboardConfirmation.Kind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ), .read)
        XCTAssertEqual(ClipboardConfirmation.Kind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE), .write)
    }

    func testOnlyProgramRequestsAreProgramStarted() {
        XCTAssertFalse(ClipboardConfirmation.Kind.unsafePaste.startedByProgram)
        XCTAssertTrue(ClipboardConfirmation.Kind.read.startedByProgram)
        XCTAssertTrue(ClipboardConfirmation.Kind.write.startedByProgram)
    }

    // Approval completes with exactly what the user reviewed.
    func testApprovalPassesTheReviewedTextThrough() {
        for kind in [ClipboardConfirmation.Kind.unsafePaste, .read, .write] {
            XCTAssertEqual(
                ClipboardConfirmation.answer(for: kind, text: "echo hi\nls", allowed: true),
                "echo hi\nls")
        }
    }

    // Refusing a paste pastes nothing, and a program that asked to read gets an
    // empty clipboard — not a hang and not the secret.
    func testDenyingAPasteOrAReadCompletesWithNothing() {
        XCTAssertEqual(ClipboardConfirmation.answer(for: .unsafePaste, text: "x\ny", allowed: false), "")
        XCTAssertEqual(ClipboardConfirmation.answer(for: .read, text: "hunter2", allowed: false), "")
    }

    // A write is never completed through libghostty; refusing it is doing nothing.
    func testDenyingAWriteLeavesTheRequestUnanswered() {
        XCTAssertNil(ClipboardConfirmation.answer(for: .write, text: "payload", allowed: false))
    }

    func testDenyNeverLeaksTheClipboardText() {
        let secret = "correct horse battery staple"
        for kind in [ClipboardConfirmation.Kind.unsafePaste, .read] {
            XCTAssertFalse(
                ClipboardConfirmation.answer(for: kind, text: secret, allowed: false)?
                    .contains(secret) ?? false)
        }
    }

    // MARK: preview

    private func englishPreview<T>(_ body: () -> T) -> T {
        let original = L10n.current
        defer { L10n.current = original }
        L10n.current = .en
        return body()
    }

    func testPreviewMakesControlCharactersVisible() {
        let preview = ClipboardConfirmation.preview("a\u{1B}[201~b\rc\u{7F}")
        XCTAssertEqual(preview, "a\u{241B}[201~b\u{240D}c\u{2421}")
        XCTAssertFalse(preview.unicodeScalars.contains { $0.value == 0x1B })
    }

    func testPreviewKeepsLineBreaksAndTabs() {
        XCTAssertEqual(ClipboardConfirmation.preview("one\n\ttwo"), "one\n\ttwo")
    }

    // The characters that hide things when rendered: a right-to-left override can
    // show `rm -rf x` backwards; a zero-width space splits a word invisibly.
    func testPreviewShowsInvisibleFormatCharacters() {
        let preview = ClipboardConfirmation.preview("ls\u{202E}fr- mr\u{200B}x\u{2028}y\u{85}z")
        XCTAssertTrue(preview.contains("⟨U+202E⟩"), preview)
        XCTAssertTrue(preview.contains("⟨U+200B⟩"), preview)
        XCTAssertTrue(preview.contains("⟨U+2028⟩"), preview)
        XCTAssertTrue(preview.contains("⟨U+0085⟩"), "a C1 control, preview: \(preview)")
        for hidden in [0x202E, 0x200B, 0x2028, 0x85] {
            XCTAssertFalse(preview.unicodeScalars.contains { $0.value == UInt32(hidden) },
                           "U+\(String(hidden, radix: 16)) must not reach the dialog raw")
        }
    }

    // A payload after a stretch of harmless text must not be invisible, and what is
    // left out must be counted.
    func testPreviewCountsWhatItLeavesOut() {
        let text = String(repeating: "x", count: 100) + "SECRET-TAIL"
        let shown = englishPreview { ClipboardConfirmation.preview(text, limit: 100) }
        XCTAssertTrue(shown.hasPrefix(String(repeating: "x", count: 100)))
        XCTAssertFalse(shown.contains("SECRET"))
        XCTAssertTrue(shown.hasSuffix("… 11 more characters"), shown)
    }

    func testPreviewOfShortTextHasNoMarker() {
        XCTAssertEqual(englishPreview { ClipboardConfirmation.preview("short", limit: 100) }, "short")
        XCTAssertEqual(englishPreview { ClipboardConfirmation.preview("", limit: 100) }, "")
    }

    // The default is generous: an ordinary multi-line paste is shown whole.
    func testThePreviewLimitHoldsAWholeOrdinaryPaste() {
        let paste = (1...60).map { "line \($0) of a pasted script" }.joined(separator: "\n")
        XCTAssertLessThan(paste.count, 4000)
        XCTAssertEqual(ClipboardConfirmation.preview(paste), paste)
    }

    func testPreviewOfNonASCIIIsLeftAlone() {
        XCTAssertEqual(ClipboardConfirmation.preview("naïve 日本語 🙂"), "naïve 日本語 🙂")
    }

    // MARK: gate

    private let terminal = UUID()
    private let now = Date(timeIntervalSinceReferenceDate: 5_000)

    // One sheet per window: a second request for the same window waits its turn
    // (here: is refused), another window is independent.
    func testOneDialogPerWindow() {
        var gate = ClipboardConfirmation.Gate()
        XCTAssertTrue(gate.admit(.read, terminal: terminal, window: 7, now: now))
        XCTAssertFalse(gate.admit(.read, terminal: UUID(), window: 7, now: now), "no stacked sheets")
        XCTAssertFalse(gate.admit(.unsafePaste, terminal: UUID(), window: 7, now: now))
        XCTAssertTrue(gate.admit(.unsafePaste, terminal: UUID(), window: 8, now: now),
                      "a paste in another window must not be refused by a sheet it cannot see")
        gate.finish(.read, terminal: terminal, window: 7, allowed: true, now: now)
        XCTAssertTrue(gate.admit(.unsafePaste, terminal: terminal, window: 7, now: now))
    }

    // The blocker: a terminal in a background tab has no window, so there is nowhere
    // to put a sheet the user could connect to the question. It is refused, and the
    // program that keeps asking is quieted.
    func testNoWindowMeansNoDialog() {
        var gate = ClipboardConfirmation.Gate()
        XCTAssertFalse(gate.admit(.read, terminal: terminal, window: nil, now: now))
        // Quiet now, even once a window exists.
        XCTAssertFalse(gate.admit(.read, terminal: terminal, window: 3, now: now.addingTimeInterval(5)))
        XCTAssertTrue(gate.admit(.read, terminal: terminal,
                                 window: 3, now: now.addingTimeInterval(ClipboardConfirmation.Gate.quietPeriod + 1)))
    }

    func testAPasteWithNoWindowIsRefusedButDoesNotSilenceTheUser() {
        var gate = ClipboardConfirmation.Gate()
        XCTAssertFalse(gate.admit(.unsafePaste, terminal: terminal, window: nil, now: now))
        XCTAssertTrue(gate.admit(.unsafePaste, terminal: terminal, window: 3, now: now.addingTimeInterval(1)))
    }

    // A program printing the request in a loop must not turn into a loop of dialogs.
    func testAProgramThatWasRefusedIsQuietedForAWhile() {
        var gate = ClipboardConfirmation.Gate()
        XCTAssertTrue(gate.admit(.read, terminal: terminal, window: 1, now: now))
        gate.finish(.read, terminal: terminal, window: 1, allowed: false, now: now)

        XCTAssertFalse(gate.admit(.read, terminal: terminal, window: 1, now: now.addingTimeInterval(5)))
        XCTAssertFalse(gate.admit(.write, terminal: terminal, window: 1, now: now.addingTimeInterval(29)))
        // …only for that terminal…
        XCTAssertTrue(gate.admit(.read, terminal: UUID(), window: 1, now: now.addingTimeInterval(5)))
    }

    func testTheQuietPeriodEnds() {
        var gate = ClipboardConfirmation.Gate()
        _ = gate.admit(.read, terminal: terminal, window: 1, now: now)
        gate.finish(.read, terminal: terminal, window: 1, allowed: false, now: now)
        let later = now.addingTimeInterval(ClipboardConfirmation.Gate.quietPeriod + 1)
        XCTAssertTrue(gate.admit(.read, terminal: terminal, window: 1, now: later))
    }

    // The user's own paste is theirs to repeat; only program-started requests are rationed.
    func testARefusedPasteDoesNotSilenceTheNextPaste() {
        var gate = ClipboardConfirmation.Gate()
        XCTAssertTrue(gate.admit(.unsafePaste, terminal: terminal, window: 1, now: now))
        gate.finish(.unsafePaste, terminal: terminal, window: 1, allowed: false, now: now)
        XCTAssertTrue(gate.admit(.unsafePaste, terminal: terminal, window: 1, now: now.addingTimeInterval(1)))
    }

    func testAnApprovedReadIsNotQuieted() {
        var gate = ClipboardConfirmation.Gate()
        XCTAssertTrue(gate.admit(.read, terminal: terminal, window: 1, now: now))
        gate.finish(.read, terminal: terminal, window: 1, allowed: true, now: now)
        XCTAssertTrue(gate.admit(.read, terminal: terminal, window: 1, now: now.addingTimeInterval(1)))
    }
}

// MARK: - New strings are translated everywhere

/// `LocalizationTests` only requires the English base. A missing translation
/// silently shows English, so the strings this pass added are held to more: each
/// must exist in every language and differ from the English text.
final class HardeningStringsTests: XCTestCase {
    private let keys: [LKey] = [
        .updateErrChecksumMismatch, .updateErrChecksumUnavailable, .updateErrNoApp,
        .updateErrDownload, .updateErrBundle,
        .clipboardPasteTitle, .clipboardPasteBody, .clipboardPasteConfirm, .clipboardPasteDeny,
        .clipboardReadTitle, .clipboardReadBody, .clipboardWriteTitle, .clipboardWriteBody,
        .clipboardAllow, .clipboardDeny, .clipboardHelpTitle, .clipboardHelpDetail,
        .clipboardPreviewMore,
    ]

    func testEveryNewKeyIsTranslatedInEveryLanguage() {
        let original = L10n.current
        defer { L10n.current = original }
        L10n.current = .en
        let english = Dictionary(uniqueKeysWithValues: keys.map { ($0, L10n.t($0)) })
        for (key, text) in english {
            XCTAssertFalse(text.isEmpty)
            XCTAssertNotEqual(text, key.rawValue, "\(key) has no English text")
        }
        for language in AppLanguage.allCases where language != .en && language != .system {
            L10n.current = language
            for key in keys {
                let translated = L10n.t(key)
                XCTAssertNotEqual(translated, english[key], "\(key) is not translated in \(language)")
                XCTAssertFalse(translated.isEmpty)
            }
        }
    }

    // The dialogs are read by a person deciding whether to approve something: a
    // translation must not drop the prompt's buttons or run on without end.
    func testDialogStringsAreShortEnoughForAnAlert() {
        let original = L10n.current
        defer { L10n.current = original }
        for language in AppLanguage.allCases where language != .system {
            L10n.current = language
            for key in [LKey.clipboardPasteConfirm, .clipboardPasteDeny, .clipboardAllow, .clipboardDeny] {
                XCTAssertLessThanOrEqual(L10n.t(key).count, 24, "\(key) in \(language) is a button label")
            }
            for key in [LKey.clipboardPasteTitle, .clipboardReadTitle, .clipboardWriteTitle] {
                XCTAssertLessThanOrEqual(L10n.t(key).count, 80, "\(key) in \(language) is a title")
            }
        }
    }
}

// MARK: - AI summarizer isolation

final class AISummarizerHardeningTests: XCTestCase {
    func testToolsAreSwitchedOffByDefault() {
        let command = AIAssist.claudeCommand(restrictTools: true)
        XCTAssertTrue(command.contains("--tools ''"), command)
        XCTAssertTrue(command.contains("-p"), "still headless print mode")
        XCTAssertTrue(command.contains("--model haiku"))
    }

    // What an older claude CLI gets: the original command, minus the stderr discard.
    func testTheFallbackIsTheOriginalCommand() {
        XCTAssertEqual(AIAssist.claudeCommand(restrictTools: false), "claude -p --model haiku")
    }

    // stderr is read, not thrown away: it is the only place "unknown option" can be
    // told apart from every other silent failure.
    func testStderrIsLeftForTheCallerToRead() {
        for restrict in [true, false] {
            let command = AIAssist.claudeCommand(restrictTools: restrict)
            XCTAssertFalse(command.contains("2>"), "no redirection of stderr: \(command)")
        }
    }

    // The reviewer's scenario: one unrelated failure must not switch the protection
    // off for the rest of the session.
    func testOnlyTheUnknownOptionMessageCountsAsAnUnsupportedFlag() {
        XCTAssertTrue(AIAssist.rejectsToolsFlag(stderr: "error: unknown option '--tools'\n"))
        XCTAssertTrue(AIAssist.rejectsToolsFlag(stderr: "Error: Unknown option '--tools' (did you mean ...)"))
        for unrelated in [
            "", "Execution error", "curl: (6) Could not resolve host: api.anthropic.com",
            "zsh:1: command not found: claude", "error: unknown option '--model'",
            "Please run /login", "error: could not read the --tools list",
        ] {
            XCTAssertFalse(AIAssist.rejectsToolsFlag(stderr: unrelated), unrelated)
        }
    }

    // The summarizer must not run from `/` (a GUI app's working directory).
    func testRunsInAPrivateEmptyDirectoryOfItsOwn() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let dir = try XCTUnwrap(AIAssist.summarizerDirectory(in: base))

        XCTAssertNotEqual(dir.path, "/")
        XCTAssertEqual(dir.deletingLastPathComponent().path, base.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let mode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as! NSNumber).intValue
        XCTAssertEqual(mode & 0o077, 0, "private to this user")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        // Asking twice is fine.
        XCTAssertEqual(AIAssist.summarizerDirectory(in: base), dir)
    }
}

// MARK: - Control API

final class ControlAPITailTests: XCTestCase {
    /// The behaviour `session.read` always had, kept as the reference.
    private func reference(_ text: String, _ lines: Int) -> String {
        text.components(separatedBy: "\n").suffix(max(1, lines)).joined(separator: "\n")
    }

    func testMatchesTheSplitAndJoinItReplaces() {
        let samples = [
            "", "one", "one\n", "\n", "\n\n", "a\nb", "a\nb\n", "a\nb\nc", "a\nb\nc\n",
            "\na\nb", "no newline at all", "trailing blank\n\n", "  indented\n\tline\nlast",
            "mixed\r\nendings\r\nhere", "emoji 🙂\nnaïve 日本語\nlast 🙂",
            String(repeating: "line\n", count: 200),
        ]
        for text in samples {
            for n in [-3, 0, 1, 2, 3, 5, 60, 500] {
                XCTAssertEqual(ControlAPI.tail(of: text, lines: n), reference(text, n),
                               "text \(text.debugDescription), lines \(n)")
            }
        }
    }

    func testKeepsOnlyTheLastLines() {
        let text = (1...100).map { "row \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ControlAPI.tail(of: text, lines: 3), "row 98\nrow 99\nrow 100")
    }

    func testAsksForAtLeastOneLine() {
        XCTAssertEqual(ControlAPI.tail(of: "a\nb\nc", lines: 0), "c")
        XCTAssertEqual(ControlAPI.tail(of: "a\nb\nc", lines: -10), "c")
    }

    // The point of the change: a multi-megabyte scrollback, a handful of lines. The
    // old implementation split the whole buffer (measured: 125 ms at 10 MB); this one
    // scans back from the end (about 0.02 ms). The BEST of five runs is compared, so a
    // busy machine cannot fail the test — it would have to stall every run — while the
    // old approach, which cannot get under ~100 ms, still does.
    func testALargeBufferIsCheap() {
        let big = String(repeating: "0123456789 some terminal output line\n", count: 300_000)  // ~11 MB
        var best = TimeInterval.infinity
        var tail = ""
        for _ in 0..<5 {
            let started = Date()
            tail = ControlAPI.tail(of: big, lines: 60)
            best = min(best, Date().timeIntervalSince(started))
        }
        XCTAssertLessThan(best, 0.05)
        XCTAssertEqual(tail.components(separatedBy: "\n").count, 60)
    }

    func testTheTerminalCeilingLeavesRoomAndStops() {
        XCTAssertTrue(ControlAPI.canOpenAnotherTerminal(open: 0))
        XCTAssertTrue(ControlAPI.canOpenAnotherTerminal(open: 50))
        XCTAssertTrue(ControlAPI.canOpenAnotherTerminal(open: ControlAPI.maxTerminals - 1))
        XCTAssertFalse(ControlAPI.canOpenAnotherTerminal(open: ControlAPI.maxTerminals))
        XCTAssertFalse(ControlAPI.canOpenAnotherTerminal(open: ControlAPI.maxTerminals + 5))
        XCTAssertGreaterThanOrEqual(ControlAPI.maxTerminals, 100)
    }
}

// MARK: - Opening links from terminal output

final class LinkOpeningPolicyTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func file(_ name: String, _ content: String = "x", executable: Bool = false) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    private func action(_ string: String) -> GhosttyRuntime.URLAction {
        GhosttyRuntime.action(for: URL(string: string)!)
    }

    private func link(_ name: String, to target: URL) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    func testWebAndMailLinksOpen() {
        XCTAssertEqual(action("https://example.com/a?b=c"), .open)
        XCTAssertEqual(action("http://localhost:3000"), .open)
        XCTAssertEqual(action("mailto:someone@example.com"), .open)
        XCTAssertEqual(action("HTTPS://EXAMPLE.COM"), .open, "scheme case does not matter")
    }

    func testOtherSchemesAreBlocked() {
        for link in [
            "javascript:alert(1)", "data:text/html,<script>1</script>", "vnc://host",
            "ssh://host", "x-apple.systempreferences:com.apple.preference.security",
            "itms-services://?action=download-manifest", "tel:123", "smb://server/share",
        ] {
            XCTAssertEqual(action(link), .block, link)
        }
    }

    func testADocumentOpens() throws {
        XCTAssertEqual(GhosttyRuntime.action(for: try file("notes.txt")), .open)
        XCTAssertEqual(GhosttyRuntime.action(for: try file("picture.png")), .open)
        XCTAssertEqual(GhosttyRuntime.action(for: try file("script.sh", "#!/bin/sh\n")), .open,
                       "no execute bit: it opens in an editor, it does not run")
    }

    func testAPlainFolderOpens() {
        XCTAssertEqual(GhosttyRuntime.action(for: sandbox), .open)
    }

    // A document package is a document, not a program: it is opened by its app.
    func testDocumentPackagesStillOpen() throws {
        for name in ["Project.xcodeproj", "Notes.rtfd"] {
            let package = sandbox.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            XCTAssertEqual(GhosttyRuntime.action(for: package), .open, name)
        }
    }

    // The case that matters: opening these runs them.
    func testAnExecutableIsRevealedNotRun() throws {
        // A real Mach-O program.
        let tool = sandbox.appendingPathComponent("tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)
        XCTAssertEqual(GhosttyRuntime.action(for: tool), .reveal)
        // A script with the execute bit and no extension: LaunchServices runs it in Terminal.
        XCTAssertEqual(
            GhosttyRuntime.action(for: try file("deploy", "#!/bin/sh\necho hi\n", executable: true)),
            .reveal)
    }

    // The execute bit alone is not the test: a text file with it set — which is every
    // file on an exFAT or SMB volume — is still a text file.
    func testATextFileWithTheExecuteBitStillOpens() throws {
        XCTAssertEqual(GhosttyRuntime.action(for: try file("notes.txt", executable: true)), .open)
        XCTAssertEqual(GhosttyRuntime.action(for: try file("README", "hello\n", executable: true)), .open)
    }

    func testAnExecutableScriptIsRevealed() throws {
        XCTAssertEqual(
            GhosttyRuntime.action(for: try file("run.sh", "#!/bin/sh\n", executable: true)), .reveal)
        XCTAssertEqual(
            GhosttyRuntime.action(for: try file("tool.py", "print(1)\n", executable: true)), .reveal)
    }

    func testLaunchingFileTypesAreRevealedEvenWithoutTheExecuteBit() throws {
        for name in ["run.command", "x.terminal", "installer.pkg", "disk.dmg", "tool.jar",
                     "link.webloc", "thing.workflow", "RUN.COMMAND"] {
            XCTAssertEqual(GhosttyRuntime.action(for: try file(name)), .reveal, name)
        }
    }

    func testAnApplicationBundleIsRevealed() throws {
        let app = sandbox.appendingPathComponent("Some.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(GhosttyRuntime.action(for: sandbox.appendingPathComponent("Some.app")), .reveal)
    }

    // ---- links: judged on where they lead, not on what they are called -----------------------

    func testASymlinkToAnExecutableIsRevealed() throws {
        let target = try file("real-tool", "#!/bin/sh\n", executable: true)
        XCTAssertEqual(GhosttyRuntime.action(for: try link("harmless.txt", to: target)), .reveal,
                       "the name says text, the target runs")
    }

    // The reviewer's scenario: a repository carries the link AND the application it
    // points at. LaunchServices follows the link, so it was opened as that app.
    func testASymlinkNamedLikeAFolderThatPointsAtAnAppIsRevealed() throws {
        let app = sandbox.appendingPathComponent("payload.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let decoy = try link("docs", to: sandbox.appendingPathComponent("payload.app"))
        XCTAssertEqual(GhosttyRuntime.action(for: decoy), .reveal)
        XCTAssertEqual(GhosttyRuntime.action(for: try link("CONTRIBUTING.md",
                                                           to: sandbox.appendingPathComponent("payload.app"))),
                       .reveal)
    }

    func testASymlinkNamedLikeTextThatPointsAtALaunchingFileIsRevealed() throws {
        let target = try file("x.terminal")
        XCTAssertEqual(GhosttyRuntime.action(for: try link("notes.txt", to: target)), .reveal)
    }

    func testASymlinkChainIsFollowedToTheEnd() throws {
        let target = try file("end.command")
        let first = try link("hop1.txt", to: target)
        XCTAssertEqual(GhosttyRuntime.action(for: try link("hop2.txt", to: first)), .reveal)
    }

    func testASymlinkToADocumentOpensAndOpensTheTarget() throws {
        let target = try file("real.txt")
        let alias = try link("shortcut.txt", to: target)
        let resolved = GhosttyRuntime.resolve(alias)
        XCTAssertEqual(resolved.action, .open)
        // What is opened is the resolved file, so it cannot be swapped after the check.
        XCTAssertEqual(
            resolved.target.resolvingSymlinksInPath().lastPathComponent, "real.txt")
        XCTAssertNotEqual(resolved.target.lastPathComponent, "shortcut.txt")
    }

    // A Finder alias is not a symlink; LaunchServices resolves it to anything.
    func testAFinderAliasIsRevealed() throws {
        let target = try file("target.txt")
        let alias = sandbox.appendingPathComponent("an alias")
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: alias)
        XCTAssertEqual(GhosttyRuntime.action(for: alias), .reveal)
    }

    func testAPathThatDoesNotExistIsBlocked() {
        XCTAssertEqual(
            GhosttyRuntime.action(for: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")), .block)
    }

    func testADanglingSymlinkIsBlocked() throws {
        let dangling = try link("gone.txt", to: sandbox.appendingPathComponent("nowhere"))
        XCTAssertEqual(GhosttyRuntime.action(for: dangling), .block)
    }

    func testRelativeTraversalIsResolvedBeforeTheCheck() throws {
        _ = try file("payload", "#!/bin/sh\n", executable: true)
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let sneaky = URL(string: "file://\(sandbox.path)/sub/../payload")!
        XCTAssertEqual(GhosttyRuntime.action(for: sneaky), .reveal)
    }

    func testAURLWithNoSchemeIsBlocked() {
        XCTAssertEqual(GhosttyRuntime.action(for: URL(string: "/just/a/path")!), .block)
    }
}

// MARK: - The notification click command

final class ClickCommandTests: XCTestCase {
    private func run(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
    }

    // The bug: a pointer path with a space became two arguments to `cat`.
    func testFindsTheAppThroughAPointerPathWithASpace() throws {
        let app = try FakeAppForClicks()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt click home \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let pointer = home.appendingPathComponent("socket")
        try (app.path + "\n").write(to: pointer, atomically: true, encoding: .utf8)
        let session = UUID()

        try run(GhosttySurfaceNSView.clickCommand(
            sessionID: session, socketPath: "/tmp/plt-no-such-\(UUID().uuidString).sock",
            pointerPath: pointer.path))
        app.waitUntilServed()

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: app.received) as? [String: Any],
            String(decoding: app.received, as: UTF8.self))
        XCTAssertEqual(json["planchette_session"] as? String, session.uuidString)
        XCTAssertEqual((json["event"] as? [String: Any])?["hook_event_name"] as? String,
                       "PlanchetteFocus")
    }

    func testUsesTheSocketNamedInTheEnvironmentFirst() throws {
        let app = try FakeAppForClicks()
        try run(GhosttySurfaceNSView.clickCommand(
            sessionID: UUID(), socketPath: app.path,
            pointerPath: "/nonexistent/pointer"))
        app.waitUntilServed()
        XCTAssertFalse(app.received.isEmpty)
    }

    // Hostile characters in a path must stay data.
    func testAPathCannotInjectShellSyntax() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-injected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let nasty = "/tmp/x'; touch '\(marker.path)'; echo '"
        try run(GhosttySurfaceNSView.clickCommand(
            sessionID: UUID(), socketPath: nasty, pointerPath: nasty))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "a quote in a path must not run commands")
    }

    func testCommandIsValidShell() throws {
        let command = GhosttySurfaceNSView.clickCommand(
            sessionID: UUID(), socketPath: "/tmp/a b.sock", pointerPath: "/Users/x y/.planchette/socket")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]   // parse only
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// `FakeApp` is private to the script tests above; the click command needs the
/// same one-shot server.
private final class FakeAppForClicks {
    let path = "/tmp/plt-\(UUID().uuidString.prefix(8)).sock"
    private var listener: Int32 = -1
    private let done = DispatchSemaphore(value: 0)
    private(set) var received = Data()

    init() throws {
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyBytes(from: $0.prefix(buf.count - 1)) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            throw NSError(domain: "FakeApp", code: Int(errno))
        }
        Thread.detachNewThread { [self] in serve() }
    }


    // How long a slow machine may need before the script connects: under heavy load a
    // Python start alone took minutes. A test that expects no connection calls `stop()`.
    private let gate = NSLock()
    private var stopped = false
    func stop() { gate.lock(); stopped = true; gate.unlock() }
    private var isStopped: Bool { gate.lock(); defer { gate.unlock() }; return stopped }

    private func acceptScript() -> Int32 {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !isStopped {
            var watch = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&watch, 1, 200) > 0 { return accept(listener, nil, nil) }
        }
        return -1
    }

    private func serve() {
        defer { done.signal() }
        let client = acceptScript()
        guard client >= 0 else { return }
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var p = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 30_000) > 0 else { break }
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            received.append(buffer, count: n)
        }
    }

    func waitUntilServed() { _ = done.wait(timeout: .now() + 120) }

    deinit {
        if listener >= 0 { close(listener) }
        unlink(path)
    }
}

// MARK: - The dialog's buttons

@MainActor
final class ClipboardDialogTests: XCTestCase {
    private let kinds: [ClipboardConfirmation.Kind] = [.unsafePaste, .read, .write]

    // AppKit gives a button titled "Cancel" the Escape key and removes the default
    // button altogether (measured), so Return would stop meaning "no". The safe
    // button must therefore never be titled Cancel, in any language.
    func testTheSafeButtonIsNeverTitledCancel() {
        let original = L10n.current
        defer { L10n.current = original }
        for language in AppLanguage.allCases where language != .system {
            L10n.current = language
            let cancel = L10n.t(.cancel)
            for kind in kinds {
                let first = ClipboardConfirmation.makeAlert(kind, text: "x\ny").buttons[0].title
                XCTAssertNotEqual(first, cancel, "\(kind) in \(language)")
                XCTAssertNotEqual(first, "Cancel", "\(kind) in \(language)")
            }
        }
    }

    // The order is the contract: first = refuse (the default), second = approve.
    func testRefusingIsFirstAndApprovingIsSecondInEveryLanguage() {
        let original = L10n.current
        defer { L10n.current = original }
        for language in AppLanguage.allCases where language != .system {
            L10n.current = language
            XCTAssertEqual(
                ClipboardConfirmation.makeAlert(.unsafePaste, text: "x\ny").buttons.map(\.title),
                [L10n.t(.clipboardPasteDeny), L10n.t(.clipboardPasteConfirm)], "\(language)")
            for kind in [ClipboardConfirmation.Kind.read, .write] {
                XCTAssertEqual(
                    ClipboardConfirmation.makeAlert(kind, text: "x").buttons.map(\.title),
                    [L10n.t(.clipboardDeny), L10n.t(.clipboardAllow)], "\(kind) in \(language)")
            }
        }
    }

    func testTheSafeButtonSaysNoAndTheSecondSaysYes() {
        let original = L10n.current
        defer { L10n.current = original }
        L10n.current = .en
        let paste = ClipboardConfirmation.makeAlert(.unsafePaste, text: "x\ny")
        XCTAssertEqual(paste.buttons.map(\.title), ["Don't Paste", "Paste"])
        let read = ClipboardConfirmation.makeAlert(.read, text: "")
        XCTAssertEqual(read.buttons.map(\.title), ["Don't Allow", "Allow"])
        let write = ClipboardConfirmation.makeAlert(.write, text: "x")
        XCTAssertEqual(write.buttons.map(\.title), ["Don't Allow", "Allow"])
    }

    // What is at stake is shown for a paste and a write — and never for a read,
    // where the decision is about trusting the program, not about the contents.
    func testThePreviewIsShownWhereTheTextIsTheQuestion() throws {
        let paste = ClipboardConfirmation.makeAlert(.unsafePaste, text: "rm -rf x\n\u{1B}[201~")
        let scroll = try XCTUnwrap(paste.accessoryView as? NSScrollView)
        let text = try XCTUnwrap((scroll.documentView as? NSTextView)?.string)
        XCTAssertTrue(text.contains("rm -rf x"))
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x1B }, "control characters are visible")
        XCTAssertNotNil(ClipboardConfirmation.makeAlert(.write, text: "x").accessoryView)
        XCTAssertNil(ClipboardConfirmation.makeAlert(.read, text: "secret").accessoryView,
                     "a read dialog must not put the clipboard on screen")
    }

    func testEveryDialogHasAWarningTitleAndBody() {
        for kind in kinds {
            let alert = ClipboardConfirmation.makeAlert(kind, text: "x")
            XCTAssertFalse(alert.messageText.isEmpty)
            XCTAssertFalse(alert.informativeText.isEmpty)
            XCTAssertEqual(alert.alertStyle, .warning)
        }
    }
}

// MARK: - Dev-server scan, end to end

/// `scan` joins a real `lsof` with the in-process working-directory lookup. The
/// pure halves have their own tests; this one runs a real listener through both.
final class DevServerScanIntegrationTests: XCTestCase {
    private func freePort() throws -> Int {
        // Below the ephemeral range, which the scanner deliberately ignores.
        for _ in 0..<200 {
            let port = Int.random(in: 20_000...40_000)
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(probe) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = in_port_t(port).bigEndian
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 { return port }
        }
        throw XCTSkip("no free port")
    }

    func testFindsARealServerAndAttributesItToItsProject() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-devserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let port = try freePort()

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.currentDirectoryURL = project
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }

        // Wait for it to listen (python can take seconds to start on a busy machine).
        var listening = false
        for _ in 0..<300 {
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = in_port_t(port).bigEndian
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(probe)
            if connected == 0 { listening = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try XCTSkipUnless(listening, "the test server did not start")

        // The kernel (and lsof) report the physical path, /private/var/…; Foundation's
        // resolvingSymlinksInPath leaves /var alone, so ask realpath(3).
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let physical = realpath(project.path, &buffer) != nil ? String(cString: buffer) : project.path

        let group = UUID(), other = UUID()
        // A scan that ran into its deadline answers nil; on a loaded machine that is
        // not what this test is about, so ask again.
        var scanned: [UUID: [DevServer]]?
        for _ in 0..<3 where scanned == nil {
            scanned = DevServerScanner.scan(projectDirs: [
                group: [physical],
                other: ["/nonexistent/elsewhere"],
            ])
        }
        let found = try XCTUnwrap(scanned)

        XCTAssertEqual(found[group]?.map(\.port), [port], "the server belongs to the project it runs in")
        XCTAssertNil(found[other], "and to no other")
    }

    func testNothingListeningMeansNothingFound() {
        let found = DevServerScanner.scan(projectDirs: [UUID(): ["/nonexistent/\(UUID().uuidString)"]])
        XCTAssertEqual(found?.isEmpty, true, "an answer of \"nothing\" — not a missing answer")
    }
}


// MARK: - A client that went away does not hold the server

final class HookServerClientGoneTests: XCTestCase {
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        var on: Int32 = 1
        for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        return (fds[0], fds[1])
    }

    func testAClientThatIsStillConnectedIsNotGone() {
        let (server, client) = pair()
        defer { close(server); close(client) }
        XCTAssertFalse(HookServer.clientHasGone(server))
    }

    // The protocol: the client sends its request and half-closes, then WAITS for the
    // answer. `poll` reports POLLIN|POLLHUP for it — exactly as for a client that is
    // gone (measured) — so a `session.wait` aborted on POLLHUP would never wait at all.
    func testAClientThatOnlyFinishedSendingIsStillWaitingNotGone() {
        let (server, client) = pair()
        defer { close(server); close(client) }
        shutdown(client, SHUT_WR)
        var watch = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        _ = poll(&watch, 1, 0)
        XCTAssertNotEqual(watch.revents & Int16(POLLHUP), 0,
                          "premise: poll cannot tell this client from a gone one")
        XCTAssertFalse(HookServer.clientHasGone(server))
    }

    // Ctrl-C, a timeout, a killed agent tool: the process is gone.
    func testAClientThatClosedIsGone() {
        let (server, client) = pair()
        defer { close(server) }
        close(client)
        var gone = HookServer.clientHasGone(server)
        for _ in 0..<40 where !gone {   // the kernel reports it at once; allow for a slow machine
            usleep(50_000)
            gone = HookServer.clientHasGone(server)
        }
        XCTAssertTrue(gone)
    }

    func testAnInvalidDescriptorIsNotReportedAsAGoneClient() {
        XCTAssertFalse(HookServer.clientHasGone(-1))
    }
}

// MARK: - Branch lookup through symlinks and broken git entries

final class HeadBranchSymlinkTests: XCTestCase {
    private var sandbox: URL!
    private var repo: String!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-headlink-\(UUID().uuidString)")
        let dir = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("packages/app"), withIntermediateDirectories: true)
        repo = dir.path
        try fixtureGit(["init", "-q", "-b", "main"], in: repo)
        try fixtureGit(["config", "user.email", "test@example.com"], in: repo)
        try fixtureGit(["config", "user.name", "Test"], in: repo)
        try "x".write(to: dir.appendingPathComponent("packages/app/a.txt"), atomically: true, encoding: .utf8)
        try fixtureGit(["add", "."], in: repo)
        try fixtureGit(["commit", "-qm", "init"], in: repo)
        try fixtureGit(["checkout", "-q", "-b", "feature/x"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func link(_ name: String, to target: String) throws -> String {
        let url = sandbox.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return url.path
    }

    // `~/code -> /Volumes/work/code`, terminal in `~/code/app`: a walk up the LOGICAL
    // path never reaches the repository. git works from the physical path, and so
    // must the file read — or the branch pill vanishes for everyone with a symlinked
    // projects folder (a regression against asking git).
    func testASymlinkedWorkingDirectoryFindsItsRepository() throws {
        let dir = try link("app-link", to: repo + "/packages/app")
        XCTAssertEqual(Worktrees.currentBranch(of: dir), "feature/x")
        XCTAssertEqual(Worktrees.currentBranch(of: dir), try fixtureGit(["branch", "--show-current"], in: dir))
    }

    // The mirror image: an unrelated repository sits on the logical path (a dotfiles
    // repo in the home folder is the usual one) and the walk would stop at it.
    func testAnUnrelatedRepositoryOnTheLogicalPathIsNotConsulted() throws {
        let outer = sandbox.appendingPathComponent("outer")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try fixtureGit(["init", "-q", "-b", "outer-branch"], in: outer.path)
        let dir = outer.appendingPathComponent("work").path
        try FileManager.default.createSymbolicLink(atPath: dir, withDestinationPath: repo + "/packages/app")
        XCTAssertEqual(Worktrees.currentBranch(of: dir), "feature/x")
        XCTAssertEqual(Worktrees.currentBranch(of: dir), try fixtureGit(["branch", "--show-current"], in: dir))
    }

    // A worktree whose git dir is gone: git stops with an error. Climbing on into
    // the repository around it would show that repository's branch for a directory
    // that is not in it.
    func testAGitFileWhoseGitdirIsGoneAsksGit() throws {
        let broken = URL(fileURLWithPath: repo).appendingPathComponent("packages/app/wt")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "gitdir: /nonexistent/\(UUID().uuidString)\n".write(
            to: broken.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Titles.headState(forDirectory: broken.path, maxLevels: 64), .unknown)
        XCTAssertNil(Worktrees.currentBranch(of: broken.path),
                     "git errors there, so there is no branch to show")
    }

    func testAGitDirectoryWithoutAReadableHeadAsksGit() throws {
        let odd = sandbox.appendingPathComponent("odd")
        try FileManager.default.createDirectory(
            at: odd.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(Titles.headState(forDirectory: odd.path), .unknown)
    }

    func testAPlainDirectoryInsideTheRepositoryStillResolves() {
        XCTAssertEqual(Worktrees.currentBranch(of: repo + "/packages/app"), "feature/x")
    }
}

// MARK: - The swap helper, run for real

/// The script that replaces the running app at quit. It has to survive its own
/// failures: whatever happens, the installed app must still be there.
final class SwapScriptTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeApp(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: url.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
    }

    private func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    private struct Layout {
        let installed: URL, newApp: URL, workDir: URL, log: URL, script: URL
    }

    private func layout(newAppExists: Bool = true) throws -> Layout {
        let installed = sandbox.appendingPathComponent("Applications/Planchette.app")
        let workDir = sandbox.appendingPathComponent("\(UpdateService.workDirPrefix)\(UUID().uuidString)")
        let newApp = workDir.appendingPathComponent("Planchette.app")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeApp(at: installed, marker: "old")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        if newAppExists { try makeApp(at: newApp, marker: "new") }
        return Layout(
            installed: installed, newApp: newApp, workDir: workDir,
            log: sandbox.appendingPathComponent("swap.log"),
            script: sandbox.appendingPathComponent("swap.sh"))
    }

    /// Run the real script text with a pid that is already gone, so it does not wait.
    @discardableResult
    private func run(_ l: Layout, cleanup: String?) throws -> String {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run(); finished.waitUntilExit()
        try UpdateService.swapScript(waitingForPID: finished.processIdentifier)
            .write(to: l.script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [l.script.path, l.newApp.path, l.installed.path, l.log.path, "0",
                             cleanup ?? ""]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the helper always exits 0")
        return (try? String(contentsOf: l.log, encoding: .utf8)) ?? ""
    }

    func testSwapsTheNewAppInAndLeavesNothingBehind() throws {
        let l = try layout()
        let log = try run(l, cleanup: l.workDir.path)
        XCTAssertEqual(marker(of: l.installed), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.installed.path + ".old"), "no .old left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.installed.path + ".new"), "no staging left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.workDir.path), "the extracted copy is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.script.path), "the script removes itself")
        XCTAssertTrue(log.contains("swap ok"), log)
    }

    // The property the whole script is built around: a failed copy must not cost the
    // user their working app.
    func testALostNewCopyLeavesTheInstalledAppUntouched() throws {
        let l = try layout(newAppExists: false)
        let log = try run(l, cleanup: l.workDir.path)
        XCTAssertEqual(marker(of: l.installed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.installed.path + ".new"))
        XCTAssertTrue(log.contains("ERROR"), log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.script.path), "cleanup also runs on failure")
    }

    // No cleanup directory given: nothing is removed but the script itself.
    func testWithoutACleanupDirectoryNothingElseIsRemoved() throws {
        let l = try layout()
        try run(l, cleanup: nil)
        XCTAssertEqual(marker(of: l.installed), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: l.workDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.script.path))
    }

    // Defence in depth in the script itself: only a directory named like one of ours.
    func testItNeverRemovesADirectoryThatIsNotNamedLikeAnExtraction() throws {
        let l = try layout()
        let userDir = sandbox.appendingPathComponent("my-documents")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try "precious".write(to: userDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try run(l, cleanup: userDir.path)
        XCTAssertEqual(try String(contentsOf: userDir.appendingPathComponent("file.txt"), encoding: .utf8), "precious")
    }

    // MARK: which directory the script is allowed to be pointed at (decided in Swift)

    func testOnlyAnExtractionInTheTempFolderIsACleanupTarget() throws {
        let tmp = sandbox!
        let good = tmp.appendingPathComponent("\(UpdateService.workDirPrefix)abc/Planchette.app").path
        XCTAssertEqual(
            UpdateService.cleanupDirectory(forStagedBundle: good, temporaryDirectory: tmp)
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            tmp.appendingPathComponent("\(UpdateService.workDirPrefix)abc").resolvingSymlinksInPath().path)
        XCTAssertNil(UpdateService.cleanupDirectory(
            forStagedBundle: "/Applications/Planchette.app", temporaryDirectory: tmp))
    }

    // The reviewer's scenario: a name that merely CONTAINS the prefix — in the user's
    // own folder, reached through a symlink in the temp folder — used to be deleted.
    func testADirectoryThatOnlyContainsThePrefixIsNeverATarget() throws {
        let tmp = sandbox!
        let userDir = sandbox.appendingPathComponent("userdir/\(UpdateService.workDirPrefix)notes")
        try makeApp(at: userDir.appendingPathComponent("Planchette.app"), marker: "mine")
        // Directly under the temp folder, but only by way of a symlink.
        let viaLink = tmp.appendingPathComponent("\(UpdateService.workDirPrefix)evil")
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: userDir)
        XCTAssertNil(UpdateService.cleanupDirectory(
            forStagedBundle: viaLink.appendingPathComponent("Planchette.app").path,
            temporaryDirectory: tmp))
        // And not by a path that merely sits somewhere else.
        XCTAssertNil(UpdateService.cleanupDirectory(
            forStagedBundle: userDir.appendingPathComponent("Planchette.app").path,
            temporaryDirectory: tmp))
    }
}

// MARK: - Config files: links that lead nowhere yet, read-only stores

final class HookInstallerLinkTests: XCTestCase {
    private var sandbox: URL!
    private let command = "/Users/test/.planchette/planchette-hook claude"

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-cfglink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A read-only directory cannot be deleted.
        if let enumerator = FileManager.default.enumerator(atPath: sandbox.path) {
            for case let path as String in enumerator {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: sandbox.appendingPathComponent(path).path)
            }
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    // Dotfiles that have not been checked out yet: the link exists, its target does not.
    func testADanglingLinkIsFollowedAndTheTargetIsCreated() throws {
        let dotfiles = sandbox.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let link = sandbox.appendingPathComponent("home/.claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: dotfiles.appendingPathComponent("settings.json").path)

        try HookInstaller.mergeSettings(at: link, hookCmd: command)

        XCTAssertTrue(isSymlink(link), "the link must survive")
        let created = dotfiles.appendingPathComponent("settings.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: created)) as? [String: Any])
        XCTAssertNotNil(json["hooks"])
    }

    func testARelativeDanglingLinkIsFollowedToo() throws {
        let dotfiles = sandbox.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let home = sandbox.appendingPathComponent("home/.claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../dotfiles/settings.json")

        try HookInstaller.mergeSettings(at: link, hookCmd: command)

        XCTAssertTrue(isSymlink(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("settings.json").path))
    }

    // Never clobber a link to somewhere that cannot be written: when the target's
    // directory is missing, the write fails and the link is left exactly as it was.
    func testALinkIntoAMissingDirectoryIsLeftAlone() throws {
        let link = sandbox.appendingPathComponent("home/.claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/\(UUID().uuidString)/settings.json")
        XCTAssertThrowsError(try HookInstaller.mergeSettings(at: link, hookCmd: command))
        XCTAssertTrue(isSymlink(link), "not replaced by a regular file")
    }

    // A declarative store (home-manager, nix): the directory is read-only. The write
    // must fail and the link must stay, not be "fixed" by replacing it.
    func testAReadOnlyDirectoryIsLeftAloneAndTheLinkSurvives() throws {
        let store = sandbox.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let target = store.appendingPathComponent("settings.json")
        try "{\"model\": \"opus\"}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.path)
        let link = sandbox.appendingPathComponent("home/.claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        XCTAssertThrowsError(try HookInstaller.mergeSettings(at: link, hookCmd: command))

        XCTAssertTrue(isSymlink(link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{\"model\": \"opus\"}")
    }

    func testAChainOfLinksIsFollowedToTheRealFile() throws {
        let real = sandbox.appendingPathComponent("real.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        let second = sandbox.appendingPathComponent("second.json")
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: real.path)
        let first = sandbox.appendingPathComponent("first.json")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
        XCTAssertEqual(HookInstaller.realLocation(of: first).resolvingSymlinksInPath().path,
                       real.resolvingSymlinksInPath().path)
    }

    func testALinkLoopDoesNotHang() throws {
        let a = sandbox.appendingPathComponent("a.json"), b = sandbox.appendingPathComponent("b.json")
        try FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: b.path)
        try FileManager.default.createSymbolicLink(atPath: b.path, withDestinationPath: a.path)
        _ = HookInstaller.realLocation(of: a)   // returns, rather than looping forever
    }

    func testAReadOnlyFailureIsExplainedAsSuch() {
        let message = HookInstaller.describeWriteFailure(
            CocoaError(.fileWriteNoPermission), path: "/x/settings.json")
        XCTAssertTrue(message.contains("read-only"), message)
        XCTAssertTrue(message.contains("/x/settings.json"))
        let other = HookInstaller.describeWriteFailure(CocoaError(.fileWriteOutOfSpace), path: "/x/s.json")
        XCTAssertTrue(other.contains("could not write"), other)
    }
}

// MARK: - tmux did not answer is not "nothing is running"

final class DurableRestoreTests: XCTestCase {
    private let a = UUID(), b = UUID()

    // The reviewer's scenario: a slow tmux (now bounded by a deadline) must not make a
    // restore conclude every agent is dead and type a replay into live ones.
    func testNoAnswerFromTmuxMeansEveryDurableAgentIsAssumedAlive() {
        XCTAssertEqual(Durable.liveIDsForRestore(listed: nil, durableIDs: [a, b]), [a, b])
    }

    func testAnEmptyAnswerReallyMeansNoneAreAlive() {
        XCTAssertEqual(Durable.liveIDsForRestore(listed: [], durableIDs: [a, b]), [])
    }

    func testAnAnswerIsTrustedAsItIs() {
        XCTAssertEqual(
            Durable.liveIDsForRestore(listed: [(id: a, attached: false)], durableIDs: [a, b]), [a])
    }

    func testNoDurableTerminalsMeansNothingToAssume() {
        XCTAssertEqual(Durable.liveIDsForRestore(listed: nil, durableIDs: []), [])
    }
}

// MARK: - Dialogs must not stop the app

@MainActor
final class ModalAlertTests: XCTestCase {
    // The fix: a body that spins a nested run loop — what `runModal()` does — from a
    // run-loop callout leaves the main queue serviced, so libghostty keeps ticking
    // and the control API keeps answering while a dialog is up.
    func testMainQueueWorkRunsWhileTheBodySpinsANestedLoop() async {
        let serviced: Bool = await ModalAlert.runFromRunLoop {
            var ran = false
            DispatchQueue.main.async { ran = true }
            let deadline = Date().addingTimeInterval(1)
            while !ran, Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.02, false) }
            return ran
        }
        XCTAssertTrue(serviced, "main-queue work must run while a modal-style loop is spinning")
    }

    func testMainActorTasksRunWhileTheBodySpinsANestedLoop() async {
        let serviced: Bool = await ModalAlert.runFromRunLoop {
            var ran = false
            Task { @MainActor in ran = true }
            let deadline = Date().addingTimeInterval(1)
            while !ran, Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.02, false) }
            return ran
        }
        XCTAssertTrue(serviced)
    }

    // The premise, measured: the same nested loop started from INSIDE a block the main
    // queue is running does not service the queue. This is what `runModal()` did from
    // every `await` — if this test ever fails, AppKit changed and `ModalAlert` is no
    // longer needed.
    func testPremiseANestedLoopInsideAMainQueueBlockStarvesTheQueue() {
        let finished = expectation(description: "probe finished")
        var serviced = true
        DispatchQueue.main.async {
            var ran = false
            DispatchQueue.main.async { ran = true }
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.02, false) }
            serviced = ran
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(serviced, "premise of ModalAlert: the queue is starved in this context")
    }

    func testTheBodyRunsOnTheMainThreadAndReturnsItsValue() async {
        let result: (Bool, Int) = await ModalAlert.runFromRunLoop { (Thread.isMainThread, 42) }
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, 42)
    }
}

// MARK: - A terminal that could not start is tried again

final class SurfaceRetryTests: XCTestCase {
    // A failed attempt with a display active (cheap enough to repeat, but not worth
    // hammering): quick at first, then every five seconds.
    func testBacksOffThenSettles() {
        var retry = SurfaceRetry()
        let delays = (1...6).map { _ in retry.failed() }
        XCTAssertEqual(delays, [1, 2, 4, 5, 5, 5])
    }

    // …and it never gives up: a terminal that waited out the night must still start
    // in the morning, and nothing notifies the app that a display woke (measured).
    func testSlowsDownButNeverStops() {
        var retry = SurfaceRetry()
        for _ in 0..<SurfaceRetry.fastAttempts { _ = retry.failed() }
        for _ in 0..<5 { XCTAssertEqual(retry.failed(), SurfaceRetry.slowDelay) }
    }

    func testTheFastAttemptsCoverAboutAMinuteAndAHalf() {
        var retry = SurfaceRetry()
        let total = (0..<SurfaceRetry.fastAttempts).reduce(0.0) { sum, _ in sum + retry.failed() }
        XCTAssertGreaterThan(total, 60)
        XCTAssertLessThan(total, 120)
    }

    // While no display is active there is nothing to attempt, only a check to repeat —
    // so the wait is short, and it is not counted as a failure.
    func testAWaitForADisplayIsShort() {
        XCTAssertLessThanOrEqual(SurfaceRetry.darkDelay, 5)
        XCTAssertGreaterThan(SurfaceRetry.darkDelay, 0)
    }

    func testASuccessStartsOver() {
        var retry = SurfaceRetry()
        for _ in 0..<10 { _ = retry.failed() }
        retry.succeeded()
        XCTAssertEqual(retry.failures, 0)
        XCTAssertEqual(retry.failed(), 1)
    }

    // A terminal that cannot start must not fill the log: the first failure, then every
    // twelfth attempt (a line a minute at five seconds).
    func testLogsTheFirstFailureAndThenRarely() {
        var retry = SurfaceRetry()
        var logged: [Int] = []
        for _ in 0..<40 {
            _ = retry.failed()
            if retry.shouldLog { logged.append(retry.failures) }
        }
        XCTAssertEqual(logged, [1, 12, 24, 36])
    }

    // The check that decides whether an attempt can work at all: it must answer
    // without crashing and agree with the system's own count of active displays.
    func testTheDisplayCheckAgreesWithTheSystem() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        XCTAssertEqual(GhosttySurfaceNSView.hasActiveDisplay(), count > 0)
    }
}

// MARK: - The installer must not copy the app over the user's CLI

final class HookInstallerDeployTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-deploy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func bundle(at url: URL) throws -> Bundle {
        try XCTUnwrap(Bundle(url: url), "no bundle object for \(url.path)")
    }

    // The bug: a dev run (`./.build/debug/Planchette`) has no bundle, so the resources
    // folder is the folder holding the executable — and on a case-insensitive file
    // system `planchette` is the executable `Planchette`. Every dev run copied the
    // whole 27 MB binary over the user's installed `~/.planchette/planchette`.
    func testAFolderHoldingABareExecutableHasNothingToDeploy() throws {
        let buildFolder = sandbox.appendingPathComponent("debug")
        try FileManager.default.createDirectory(at: buildFolder, withIntermediateDirectories: true)
        let executable = buildFolder.appendingPathComponent("Planchette")
        try Data(repeating: 0xCF, count: 4096).write(to: executable)

        let bare = try bundle(at: buildFolder)
        XCTAssertNil(HookInstaller.bundledResource(named: "planchette", in: bare),
                     "the executable must not pass for the bundled CLI")
        XCTAssertNil(HookInstaller.bundledResource(named: "Planchette", in: bare))

        let destination = sandbox.appendingPathComponent("home/.planchette/planchette")
        try HookInstaller.deploy("planchette", to: destination, from: bare)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a dev run must leave the installed CLI alone")
    }

    // …and what already sits there is left exactly as it was.
    func testAnInstalledCLIIsNotReplacedByADevRun() throws {
        let buildFolder = sandbox.appendingPathComponent("debug")
        try FileManager.default.createDirectory(at: buildFolder, withIntermediateDirectories: true)
        try Data(repeating: 0xCF, count: 4096).write(to: buildFolder.appendingPathComponent("Planchette"))
        let destination = sandbox.appendingPathComponent("home/.planchette/planchette")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env python3\nprint('the real CLI')\n".write(to: destination, atomically: true, encoding: .utf8)

        try HookInstaller.deploy("planchette", to: destination, from: try bundle(at: buildFolder))

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8),
                       "#!/usr/bin/env python3\nprint('the real CLI')\n")
    }

    private func makeApp(resource name: String, content: String) throws -> Bundle {
        let app = sandbox.appendingPathComponent("Planchette.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try content.write(to: resources.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return try bundle(at: app)
    }

    func testAPackagedAppDeploysItsResource() throws {
        let app = try makeApp(resource: "planchette", content: "#!/bin/sh\necho cli\n")
        let destination = sandbox.appendingPathComponent("home/.planchette/planchette")

        try HookInstaller.deploy("planchette", to: destination, from: app)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "#!/bin/sh\necho cli\n")
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testAnUpdateReplacesAnOlderCopy() throws {
        let destination = sandbox.appendingPathComponent("home/.planchette/planchette")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: destination, atomically: true, encoding: .utf8)
        let app = try makeApp(resource: "planchette", content: "new")

        try HookInstaller.deploy("planchette", to: destination, from: app)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
    }

    func testAMissingResourceInAPackagedAppIsNotAnError() throws {
        let app = try makeApp(resource: "something-else", content: "x")
        XCTAssertNil(HookInstaller.bundledResource(named: "planchette", in: app))
        let destination = sandbox.appendingPathComponent("home/.planchette/planchette")
        try HookInstaller.deploy("planchette", to: destination, from: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // The test run itself is a dev run: the real installer must find nothing to deploy,
    // which is what keeps `swift test` — and every isolated instance — away from the
    // user's ~/.planchette.
    func testThisProcessIsNotAPackagedApp() {
        XCTAssertNil(HookInstaller.bundledResource(named: "planchette"))
        XCTAssertNil(HookInstaller.bundledResource(named: "planchette-hook"))
    }
}

// MARK: - Prompts to one terminal run one after the other

/// None of these tests depends on a clock: they ran on a machine that was thirty times
/// slower than normal, and every "wait 5 ms, then …" or "done within 0.6 s" failed.
/// Order comes from creating tasks in sequence (the main actor starts them in that
/// order), and overlap or progress is observed, not timed.
@MainActor
final class KeyedSerializerTests: XCTestCase {
    private final class Log { var events: [String] = [] }

    // `session.prompt` is "paste, pause, Enter". Two prompts that overlapped would be
    // paste, paste, Enter, Enter — one message instead of two.
    func testJobsWithTheSameKeyDoNotOverlapAndKeepTheirOrder() async {
        let serializer = KeyedSerializer<String>()
        let log = Log()
        var tasks: [Task<Void, Never>] = []
        for index in 1...4 {
            tasks.append(Task { @MainActor in
                await serializer.run("terminal") {
                    log.events.append("start \(index)")
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    log.events.append("end \(index)")
                }
            })
        }
        for task in tasks { await task.value }
        XCTAssertEqual(log.events, [
            "start 1", "end 1", "start 2", "end 2", "start 3", "end 3", "start 4", "end 4",
        ])
    }

    // Jobs for different keys may run at the same time: each job waits until all four
    // have started. Jobs that were queued behind each other could never get there, and
    // each would give up after its own wait (5 s) — so the failure is slow, not a hang.
    func testJobsWithDifferentKeysRunSideBySide() async {
        let serializer = KeyedSerializer<String>()
        var started = 0
        var sawAllRunning: [Bool] = []
        var tasks: [Task<Void, Never>] = []
        for key in ["a", "b", "c", "d"] {
            tasks.append(Task { @MainActor in
                await serializer.run(key) {
                    started += 1
                    var waited = 0
                    while started < 4, waited < 500 {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        waited += 1
                    }
                    sawAllRunning.append(started == 4)
                }
            })
        }
        for task in tasks { await task.value }
        XCTAssertEqual(sawAllRunning, [true, true, true, true])
    }

    // The wait inside a job must not block the main actor: other work (the UI, the
    // other terminals, libghostty's tick) keeps running during the pause. The job waits
    // until a ticker on the main actor has made five turns, at most five seconds; a
    // blocked actor would leave it stuck at one.
    func testWaitingInsideAJobDoesNotBlockTheMainActor() async {
        let serializer = KeyedSerializer<String>()
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        await serializer.run("terminal") {
            for _ in 0..<500 where ticks < 5 { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        ticker.cancel()
        XCTAssertGreaterThanOrEqual(ticks, 5)
    }

    func testTheTableEmptiesWhenEverythingIsDone() async {
        let serializer = KeyedSerializer<Int>()
        var tasks: [Task<Void, Never>] = []
        for key in 0..<5 {
            for _ in 0..<3 {
                tasks.append(Task { @MainActor in await serializer.run(key) {} })
            }
        }
        for task in tasks { await task.value }
        XCTAssertEqual(serializer.activeKeys, 0)
    }

    func testAnEarlierJobFinishingDoesNotDropALaterOne() async {
        let serializer = KeyedSerializer<String>()
        let log = Log()
        let first = Task { @MainActor in
            await serializer.run("t") {
                try? await Task.sleep(nanoseconds: 60_000_000)
                log.events.append("first")
            }
        }
        let second = Task { @MainActor in
            await serializer.run("t") { log.events.append("second") }
        }
        await first.value
        await second.value
        XCTAssertEqual(log.events, ["first", "second"])
        XCTAssertEqual(serializer.activeKeys, 0)
    }
}

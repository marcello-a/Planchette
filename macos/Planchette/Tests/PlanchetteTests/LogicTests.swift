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
        XCTAssertEqual(try decode("free"), .ready)
        // New values round-trip; unknown falls back to ready.
        XCTAssertEqual(try decode("error"), .error)
        XCTAssertEqual(try decode("bogus"), .ready)
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

final class StatusColorTests: XCTestCase {
    // Each state must map to its documented color — this is the whole point of
    // the app (which terminal is idle / in use / waiting / errored).
    func testTintPerState() {
        XCTAssertEqual(AttentionState.ready.tint, Color.green)
        XCTAssertEqual(AttentionState.running.tint, Color.purple)
        XCTAssertEqual(AttentionState.waiting.tint, Color.blue)
        XCTAssertEqual(AttentionState.error.tint, Color.red)
    }

    func testEveryStateHasADistinctSymbol() {
        let all: [AttentionState] = [.ready, .running, .waiting, .error]
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count)
    }

    func testInboxContainsOnlyWaitingAndError() {
        XCTAssertTrue(AttentionState.waiting.needsAttention)
        XCTAssertTrue(AttentionState.error.needsAttention)
        XCTAssertFalse(AttentionState.running.needsAttention)
        XCTAssertFalse(AttentionState.ready.needsAttention)
    }

    // Hook events → states (the live "in use / waiting / idle" transitions).
    func testHookEventTransitions() {
        XCTAssertEqual(AttentionState.forHookEvent("UserPromptSubmit"), .running)
        XCTAssertEqual(AttentionState.forHookEvent("Notification"), .waiting)
        XCTAssertEqual(AttentionState.forHookEvent("PermissionRequest"), .waiting)
        XCTAssertEqual(AttentionState.forHookEvent("Stop"), .ready)
        XCTAssertEqual(AttentionState.forHookEvent("SubagentStop"), .ready)
        XCTAssertEqual(AttentionState.forHookEvent("SessionEnd"), .ready)
        XCTAssertNil(AttentionState.forHookEvent("SessionStart"))
        XCTAssertNil(AttentionState.forHookEvent("whatever"))
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

    // Inbox ordering: error is most urgent, ready least.
    func testRankOrdering() {
        XCTAssertLessThan(AttentionState.error.rank, AttentionState.waiting.rank)
        XCTAssertLessThan(AttentionState.waiting.rank, AttentionState.running.rank)
        XCTAssertLessThan(AttentionState.running.rank, AttentionState.ready.rank)
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
        s.state = .ready
        XCTAssertEqual(s.displayTitle, "free")
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

import XCTest
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
}

final class HookInstallerTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planchette-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testInstallMergesAndPreservesExistingHooks() throws {
        let dir = try tempDir()
        let settings = dir.appendingPathComponent("settings.json")
        let hookBin = dir.appendingPathComponent("planchette-hook")
        try #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other.sh"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertFalse(HookInstaller.isInstalled(settings: settings))
        try HookInstaller.install(settings: settings, hookBin: hookBin)

        XCTAssertTrue(HookInstaller.isInstalled(settings: settings))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hookBin.path))
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(root["model"] as? String, "opus")
        let hooks = root["hooks"] as! [String: Any]
        for event in HookInstaller.events {
            let entries = hooks[event] as! [[String: Any]]
            let commands = entries.flatMap { ($0["hooks"] as! [[String: Any]]) }
                .compactMap { $0["command"] as? String }
            XCTAssertTrue(commands.contains(hookBin.path), "missing hook for \(event)")
        }
        // The pre-existing Stop hook survived.
        let stop = (hooks["Stop"] as! [[String: Any]])
            .flatMap { $0["hooks"] as! [[String: Any]] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(stop.contains("other.sh"))
        // Backup written next to the settings file.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: settings.appendingPathExtension("planchette-bak").path))
    }

    func testInstallIsIdempotent() throws {
        let dir = try tempDir()
        let settings = dir.appendingPathComponent("settings.json")
        let hookBin = dir.appendingPathComponent("planchette-hook")
        try HookInstaller.install(settings: settings, hookBin: hookBin)
        try HookInstaller.install(settings: settings, hookBin: hookBin)
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        for event in HookInstaller.events {
            XCTAssertEqual((hooks[event] as! [[String: Any]]).count, 1, "duplicate for \(event)")
        }
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

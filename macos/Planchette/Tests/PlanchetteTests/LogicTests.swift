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

// MARK: "What's new" in the update dialog (parsed off the release body)

final class ReleaseNotesTests: XCTestCase {
    private let body = """
    ### Added
    - **Terminals name themselves.** A tab is now called `NIE-1902 · Add the
      switch`: the ticket of its checkout plus the task you last sent it.
      - a nested detail nobody needs in a dialog
    - **A folder is a page, not just a box** — click it and the main area shows
      what is inside.

    ### Fixed
    - A project row's click and its drag no longer fight over the gesture. See
      [the PR](https://github.com/x/y/pull/7) for why.
    """

    func testTakesTheBoldLeadInAsTheTitle() {
        let (items, _) = ReleaseNotes.highlights(from: body)
        XCTAssertEqual(items.first, "Terminals name themselves")
        XCTAssertEqual(items[1], "A folder is a page, not just a box")
    }

    // A plain bullet has no bold lead-in: its first sentence is the title.
    func testFallsBackToTheFirstSentence() {
        let (items, _) = ReleaseNotes.highlights(from: body)
        XCTAssertEqual(items[2], "A project row's click and its drag no longer fight over the…")
    }

    func testSkipsNestedBulletsAndHeadings() {
        let (items, _) = ReleaseNotes.highlights(from: body)
        XCTAssertEqual(items.count, 3)
        XCTAssertFalse(items.contains { $0.contains("nested") })
        XCTAssertFalse(items.contains { $0.contains("Added") })
    }

    // The dialog has room for a few lines, not for a whole changelog.
    func testCutsTheListAndCountsTheRest() {
        let long = (1...9).map { "- **Entry \($0).** Details." }.joined(separator: "\n")
        let (items, more) = ReleaseNotes.highlights(from: long, limit: 4)
        XCTAssertEqual(items, ["Entry 1", "Entry 2", "Entry 3", "Entry 4"])
        XCTAssertEqual(more, 5)
    }

    func testMarkdownIsNotReadOutAsPunctuation() {
        let (items, _) = ReleaseNotes.highlights(from: "- **A `code` name.** rest")
        XCTAssertEqual(items, ["A code name"])
        let (links, _) = ReleaseNotes.highlights(from: "- Fixed [the thing](http://x/y) at last.")
        XCTAssertEqual(links, ["Fixed the thing at last"])
    }

    // A release published by hand may have no list at all — then the dialog must
    // simply say nothing new, not show an empty "What's new" block.
    func testNoBulletsMeansNoHighlights() {
        let (items, more) = ReleaseNotes.highlights(from: "Stable release 0.2.16.")
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(more, 0)
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

    // Which states are a report you can have read: a question, an error, a
    // finished turn. Starting work is not news, and neither is idleness.
    func testOnlyReportsCanBeUnread() {
        XCTAssertTrue(AttentionState.ready.isReport)
        XCTAssertTrue(AttentionState.waiting.isReport)
        XCTAssertTrue(AttentionState.error.isReport)
        XCTAssertFalse(AttentionState.running.isReport)
        XCTAssertFalse(AttentionState.free.isReport)
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
        XCTAssertTrue(cmd.hasPrefix("/opt/homebrew/bin/tmux -L planchette -f "))
        XCTAssertTrue(cmd.contains(" new-session -A -D -s planchette-x"))
    }

    // `-f` only applies when this command starts the server; re-sourcing on
    // every attach is what carries a config fix to servers an older app
    // version already started.
    func testAttachCommandResourcesTheConfig() {
        let cmd = Durable.attachCommand(tmux: "/usr/bin/tmux", session: "planchette-x")
        XCTAssertTrue(cmd.hasSuffix("\\; source-file '\(Durable.configURL.path)'"))
    }

    // Our own server is what makes the fidelity options safe: extended-keys,
    // set-clipboard and escape-time are SERVER options, so on a shared server
    // setting them would silently reconfigure the user's own tmux.
    func testRunsOnItsOwnServerWithItsOwnConfig() {
        let cmd = Durable.attachCommand(tmux: "/usr/bin/tmux", session: "planchette-x")
        XCTAssertTrue(cmd.contains("-L planchette"))
        XCTAssertTrue(cmd.contains("-f '\(Durable.configURL.path)'"))
    }

    // tmux must not show through: no status bar, no prefix eating C-b
    // (backward-char in every emacs-mode shell, and bound by agent TUIs).
    func testConfigHidesTmux() {
        let c = Durable.configContents
        XCTAssertTrue(c.contains("set -g status off"))
        XCTAssertTrue(c.contains("set -g prefix None"))
        XCTAssertTrue(c.contains("set -g history-limit"), "tmux's 2000 lines would cap scrollback")
    }

    // The regression that made this necessary: with extended-keys off (tmux's
    // default) Shift+Enter arrives as a plain Enter, so an agent submits the
    // prompt instead of inserting a newline.
    func testConfigPassesModifiedKeysThrough() {
        let c = Durable.configContents
        XCTAssertTrue(c.contains("set -s extended-keys on"))
        XCTAssertTrue(c.contains("extended-keys-format csi-u"))
        XCTAssertTrue(c.contains("extkeys"), "tmux must be told the terminal supports them")
    }

    // Everything else ghostty can do that tmux assumes it cannot.
    func testConfigDeclaresTheTerminalsRealCapabilities() {
        let c = Durable.configContents
        for feature in ["RGB", "clipboard", "focus", "cstyle", "hyperlinks", "sync"] {
            XCTAssertTrue(c.contains(feature), "terminal-features must include \(feature)")
        }
        XCTAssertTrue(c.contains("set -s set-clipboard on"))
        XCTAssertTrue(c.contains("set -g allow-passthrough on"))
    }

    // Without -e the second durable terminal runs with the FIRST one's identity:
    // one tmux server serves every session and keeps the environment of the
    // client that started it. Every hook event would name the wrong terminal.
    func testAttachCommandCarriesTheEnvironmentPerSession() {
        let cmd = Durable.attachCommand(
            tmux: "/usr/bin/tmux", session: "planchette-x",
            environment: [("PLANCHETTE_SESSION", "ABC"), ("PLANCHETTE_SOCKET", "/tmp/p.sock")])
        XCTAssertTrue(cmd.contains(
            "new-session -A -D -s planchette-x"
                + " -e 'PLANCHETTE_SESSION=ABC' -e 'PLANCHETTE_SOCKET=/tmp/p.sock'"))
    }

    // The regression that made this necessary: with mouse off, ghostty turns
    // wheel scrolls into arrow keys (tmux is always in the alternate screen),
    // so scrolling at a prompt cycled shell history. tmux's own context menus
    // must stay unbound — Planchette shows its native menu instead.
    func testConfigEnablesMouseWithoutTmuxMenus() {
        let c = Durable.configContents
        XCTAssertTrue(c.contains("set -g mouse on"))
        for binding in ["MouseDown3Pane", "MouseDown3Status", "MouseDown3StatusLeft"] {
            XCTAssertTrue(c.contains("unbind -n \(binding)"), "tmux menu \(binding) must be unbound")
            XCTAssertTrue(c.contains("unbind -n M-\(binding)"), "tmux menu M-\(binding) must be unbound")
        }
    }

    // The click command carries quotes, $ and | — it must survive the shell
    // that runs the tmux line, or the terminal fails to start at all.
    func testQuotesValuesContainingShellMetacharacters() {
        let nasty = "printf '%s' \"$E\" | nc -U \"$T\" && break"
        let cmd = Durable.attachCommand(
            tmux: "/usr/bin/tmux", session: "s", environment: [("K", nasty)])
        XCTAssertTrue(cmd.contains(
            "-e 'K=printf '\\''%s'\\'' \"$E\" | nc -U \"$T\" && break'"))
    }

    func testSingleQuotingIsShellCorrect() {
        XCTAssertEqual(Durable.singleQuoted("plain"), "'plain'")
        XCTAssertEqual(Durable.singleQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(Durable.singleQuoted(""), "''")
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

    // Both questions a restore asks tmux are derived from one listing, so the
    // main thread never spawns a probe per terminal.
    func testLiveAndUnattachedComeFromTheSameListing() {
        let attached = UUID(), orphan = UUID()
        let listed = [(id: attached, attached: true), (id: orphan, attached: false)]
        XCTAssertEqual(Durable.liveIDs(in: listed), [attached, orphan],
                       "a live agent is live whether or not we are attached to it")
        XCTAssertEqual(Durable.unattachedIDs(in: listed), [orphan],
                       "only the orphan may be reaped")
    }

    func testEmptyListingYieldsNothing() {
        XCTAssertTrue(Durable.liveIDs(in: []).isEmpty)
        XCTAssertTrue(Durable.unattachedIDs(in: []).isEmpty)
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

    // On for a fresh state, like every other setting. The cost has not changed --
    // tmux cannot pass Shift+Enter through -- so Settings states it and whoever
    // needs multi-line prompts turns it off. A state that already carries `false`
    // is a choice and survives (see below); this is only about never having chosen.
    func testSettingDefaultsOnForAFreshState() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.durableTerminals, "every setting ships on")
    }

    // A terminal is still only durable when tmux is actually there: the default
    // must not be able to hand a machine without tmux a broken session.
    func testDurabilityStillNeedsTmux() {
        XCTAssertNil(
            Durable.tmuxPath(isExecutable: { _ in false }),
            "no tmux found means no durable session, whatever the setting says")
        XCTAssertNotNil(Durable.tmuxPath(isExecutable: { _ in true }))
    }

    // 0.2.13 briefly forced it on. Whatever a state says now is respected —
    // nothing flips it in either direction behind the user's back.
    func testPersistedChoiceIsRespectedBothWays() throws {
        for value in [true, false] {
            let json = "{\"durableTerminals\":\(value)}"
            let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
            XCTAssertEqual(state.durableTerminals, value)
        }
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

    // The sidebar states the branch once: on the project while its terminals
    // agree, on each terminal when they do not.
    func testSharedBranchOnlyWhenEveryTerminalAgrees() {
        XCTAssertEqual(Worktrees.sharedBranch(["main", "main"]), "main")
        XCTAssertEqual(Worktrees.sharedBranch(["feat/x"]), "feat/x")
        XCTAssertNil(Worktrees.sharedBranch(["main", "feat/x"]))
        XCTAssertNil(Worktrees.sharedBranch([]), "a project without terminals")
    }

    // A terminal outside a repo has no branch to contribute, so it cannot agree:
    // one line on the project would claim a checkout it is not in.
    func testMissingBranchBreaksTheAgreement() {
        XCTAssertNil(Worktrees.sharedBranch(["main", nil]))
        XCTAssertNil(Worktrees.sharedBranch([nil, "main"]))
        XCTAssertNil(Worktrees.sharedBranch([nil, nil]))
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
        // A subagent finishing is not the turn finishing.
        XCTAssertNil(AttentionState.forHookEvent("SubagentStop"))
        // A tool call is proof the turn is still in flight.
        XCTAssertEqual(AttentionState.forHookEvent("PreToolUse"), .running)
        XCTAssertEqual(AttentionState.forHookEvent("PostToolUse"), .running)
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

    // Claude Code sends a Notification after a minute of idling at the prompt.
    // It is not a question: whatever the terminal reported still stands, and
    // turning it blue invents a question nobody asked.
    func testIdleNudgeIsNotAQuestion() {
        XCTAssertNil(AttentionState.forHookEvent(
            "Notification", message: "Claude is waiting for your input"))
        XCTAssertTrue(AttentionState.isIdleNudge("Claude is waiting for your input"))
        // A real permission request still asks.
        XCTAssertEqual(
            AttentionState.forHookEvent(
                "Notification", message: "Claude needs your permission to use Bash"),
            .waiting)
        XCTAssertFalse(AttentionState.isIdleNudge("Claude needs your permission to use Bash"))
        // No message at all: an unrecognized notification counts as a question,
        // because a missed one costs more than a spurious one.
        XCTAssertEqual(AttentionState.forHookEvent("Notification"), .waiting)
        XCTAssertFalse(AttentionState.isIdleNudge(nil))
    }

    // The sequence that used to lie: a tool asks for permission, you grant it,
    // and the terminal kept saying "waiting" until the whole turn ended.
    func testGrantedPermissionStopsAsking() {
        var state = AttentionState.forHookEvent("UserPromptSubmit") ?? .free
        XCTAssertEqual(state, .running)
        state = AttentionState.forHookEvent("PreToolUse") ?? state
        state = AttentionState.forHookEvent(
            "Notification", message: "Claude needs your permission to use Bash") ?? state
        XCTAssertEqual(state, .waiting, "the prompt is on screen")
        // Granting it produces no event of its own — the tool running does.
        state = AttentionState.forHookEvent("PostToolUse") ?? state
        XCTAssertEqual(state, .running, "answered, so it must stop asking")
        state = AttentionState.forHookEvent("Stop") ?? state
        XCTAssertEqual(state, .ready)
    }

    // A turn that spawns subagents must stay purple until it really ends.
    func testSubagentsDoNotEndTheTurn() {
        var state = AttentionState.forHookEvent("UserPromptSubmit") ?? .free
        state = AttentionState.forHookEvent("SubagentStop") ?? state
        XCTAssertEqual(state, .running, "the main agent is still working")
        state = AttentionState.forHookEvent("Stop") ?? state
        XCTAssertEqual(state, .ready)
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
            // Only `Stop` ends a turn. A `Task` subagent finishing leaves the
            // main agent working, so it must not report a result to review.
            ("SubagentStop", nil, nil),
            // A tool call proves the turn moved on — this is what clears a
            // permission you already granted.
            ("PreToolUse", nil, .running),
            ("PostToolUse", nil, .running),
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

    // MARK: Terminals that name themselves (ticket · task)

    func testTaskLabelKeepsAShortPromptAsItIs() {
        XCTAssertEqual(Titles.taskLabel("Add the format switch"), "Add the format switch")
    }

    func testTaskLabelCutsAtAWordBoundary() {
        let label = Titles.taskLabel(
            "Add the format switch to the product menu and cover it with a test", max: 24)
        XCTAssertEqual(label, "Add the format switch…")
        XCTAssertFalse(label!.contains("swi…"), "never cut mid-word")
    }

    // A single word longer than the budget is better cut than reduced to "…".
    func testTaskLabelCutsInsideOneLongWord() {
        XCTAssertEqual(Titles.taskLabel("Donaudampfschifffahrtsgesellschaft", max: 12),
                       "Donaudampfsc…")
    }

    func testTaskLabelCollapsesWhitespaceAndDropsTrailingPunctuation() {
        XCTAssertEqual(Titles.taskLabel("  fix   the   upload spec.  "), "fix the upload spec")
        XCTAssertNil(Titles.taskLabel("   \n  "))
    }

    func testAutoTitleCombinesWhatExists() {
        XCTAssertEqual(Titles.autoTitle(ticket: "NIE-1902", work: "Add the switch"),
                       "NIE-1902 · Add the switch")
        XCTAssertEqual(Titles.autoTitle(ticket: "NIE-1902", work: nil), "NIE-1902")
        XCTAssertEqual(Titles.autoTitle(ticket: nil, work: "Add the switch"), "Add the switch")
        XCTAssertNil(Titles.autoTitle(ticket: nil, work: nil))
    }

    // The task is what I sent this terminal to do; the program's own title
    // changes under it constantly, so the task has to win.
    func testTaskOutranksTheReportedTitle() {
        var s = session(osc: "✳ designer-library")
        s.currentTask = "Fix the flaky upload spec"
        XCTAssertEqual(s.displayTitle, "Fix the flaky upload spec")
    }

    func testReportedTitleIsUsedWhenThereIsNoTask() {
        XCTAssertEqual(session(osc: "npm run dev").displayTitle, "npm run dev")
    }

    func testManualNameStillWinsOverAnAutoTitle() {
        var s = session(osc: "✳ whatever", custom: "watcher")
        s.currentTask = "Fix the flaky upload spec"
        XCTAssertEqual(s.displayTitle, "watcher")
    }

    // A notification row names the checkout by its branch, from the ticket on:
    // the lead-in is the same on every branch one person makes.
    func testBranchIsCutAtTheTicket() {
        XCTAssertEqual(
            Titles.branchFromTicket("marcello/feat/NIE-1902-format-switch"),
            "NIE-1902-format-switch")
        XCTAssertEqual(Titles.branchFromTicket("NIE-1902"), "NIE-1902")
        // No ticket, no meaningful place to cut.
        XCTAssertEqual(Titles.branchFromTicket("main"), "main")
        XCTAssertEqual(Titles.branchFromTicket("feature/big-refactor"), "feature/big-refactor")
        XCTAssertEqual(Titles.branchFromTicket(""), "")
    }

    // The sidebar row carries the path and the last prompt on their own lines, so
    // the name in front of the path is only a rename or the ticket — a name built
    // from the task would repeat the line below it.
    func testRowNameIsTheRenameOrTheTicket() throws {
        var plain = session(osc: "✳ x")
        plain.currentTask = "Fix the flaky upload spec"
        XCTAssertNil(plain.rowName, "no rename and no ticket branch: the path names it")
        XCTAssertEqual(session(osc: "x", custom: "watcher").rowName, "watcher")

        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rowname-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/marcello/feat/NIE-1902-format-switch\n"
            .write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: repo) }

        var inRepo = TerminalSession(groupID: UUID(), workingDirectory: repo.path)
        inRepo.currentTask = "Add the format switch"
        XCTAssertEqual(inRepo.ticket, "NIE-1902")
        XCTAssertEqual(inRepo.rowName, "NIE-1902")
        inRepo.customTitle = "watcher"
        XCTAssertEqual(inRepo.rowName, "watcher", "a rename still wins")
    }

    // Two terminals in the same checkout must not read the same: the ticket
    // comes from the branch, the half after it from each terminal's own task.
    func testTicketAndTaskTogetherInAWorktree() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/marcello/feat/NIE-1902-format-switch\n"
            .write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: repo) }

        var a = TerminalSession(groupID: UUID(), workingDirectory: repo.path)
        a.currentTask = "Add the format switch to the product menu"
        var b = TerminalSession(groupID: UUID(), workingDirectory: repo.path)
        b.currentTask = "Fix the flaky upload spec"
        let c = TerminalSession(groupID: UUID(), workingDirectory: repo.path)

        XCTAssertEqual(a.displayTitle, "NIE-1902 · Add the format switch to the…")
        XCTAssertEqual(b.displayTitle, "NIE-1902 · Fix the flaky upload spec")
        XCTAssertEqual(c.displayTitle, "NIE-1902", "no task yet: the ticket alone")
        XCTAssertNotEqual(a.displayTitle, b.displayTitle)
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

// MARK: Snooze — "not now, remind me then"

/// The one "how long ago" label in the app: the sidebar, the notifications
/// panel, the folder overview and the quick switcher all render this.
final class WaitingTimeTests: XCTestCase {
    func testUsesUnitSymbols() {
        XCTAssertEqual(WaitingTimeText.format(0), "0s")
        XCTAssertEqual(WaitingTimeText.format(42), "42s")
        XCTAssertEqual(WaitingTimeText.format(59), "59s")
        XCTAssertEqual(WaitingTimeText.format(60), "1m")
        XCTAssertEqual(WaitingTimeText.format(59 * 60), "59m")
        XCTAssertEqual(WaitingTimeText.format(80 * 60), "1h 20m")
        XCTAssertEqual(WaitingTimeText.format(3 * 3600 + 25 * 60), "3h 25m")
        XCTAssertEqual(WaitingTimeText.format(50 * 3600), "2d 2h")
        XCTAssertEqual(WaitingTimeText.format(9 * 86400), "1w 2d")
    }

    // The smaller unit only earns its space while it says something.
    func testDropsAZeroRemainder() {
        XCTAssertEqual(WaitingTimeText.format(2 * 3600), "2h")
        XCTAssertEqual(WaitingTimeText.format(3 * 86400), "3d")
        XCTAssertEqual(WaitingTimeText.format(14 * 86400), "2w")
    }

    // The label redraws every second while it counts seconds, then once a
    // minute — otherwise "3s" would stand there for most of a minute.
    func testScheduleTicksPerSecondOnlyWhileFresh() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        let fresh = AgeSchedule(since: since).entries(from: since, mode: .normal)
        XCTAssertEqual(fresh.next(), since)
        XCTAssertEqual(fresh.next(), since.addingTimeInterval(1))

        let old = AgeSchedule(since: since)
            .entries(from: since.addingTimeInterval(600), mode: .normal)
        XCTAssertEqual(old.next(), since.addingTimeInterval(600))
        XCTAssertEqual(old.next(), since.addingTimeInterval(660))
    }

    // A clock that moved backwards must not print a count from the future.
    func testNegativeIntervalReadsAsZero() {
        XCTAssertEqual(WaitingTimeText.format(-90), "0s")
    }
}

final class SnoozeTests: XCTestCase {
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    func testHourOptionsAreExactOffsets() {
        let now = date("2026-08-10T14:05:00Z")
        XCTAssertEqual(SnoozeOption.oneHour.date(from: now), now.addingTimeInterval(3600))
        XCTAssertEqual(SnoozeOption.twoHours.date(from: now), now.addingTimeInterval(7200))
    }

    // The morning option means "the next 9:00", not "+24h": snoozing at 22:00
    // must land the next morning, not the one after.
    func testTomorrowMorningIsTheNextNineOClock() {
        let evening = date("2026-08-10T22:00:00Z")
        XCTAssertEqual(
            SnoozeOption.tomorrowMorning.date(from: evening, calendar: utc),
            date("2026-08-11T09:00:00Z"))
    }

    // Snoozing at 3 in the morning: the next 9:00 is today's, hours away —
    // waiting a further day would be a reminder nobody asked for.
    func testEarlyMorningSnoozeLandsTheSameDay() {
        let night = date("2026-08-10T03:00:00Z")
        XCTAssertEqual(
            SnoozeOption.tomorrowMorning.date(from: night, calendar: utc),
            date("2026-08-10T09:00:00Z"))
    }

    // Exactly 9:00 is not "still ahead" — it would fire instantly.
    func testAtNineExactlyGoesToTheNextDay() {
        let nine = date("2026-08-10T09:00:00Z")
        XCTAssertEqual(
            SnoozeOption.tomorrowMorning.date(from: nine, calendar: utc),
            date("2026-08-11T09:00:00Z"))
    }

    func testQuietWhileEitherSnoozeRuns() {
        let now = date("2026-08-10T12:00:00Z")
        let later = date("2026-08-10T13:00:00Z")
        let earlier = date("2026-08-10T11:00:00Z")
        XCTAssertTrue(Snooze.isActive(sessionUntil: later, groupUntil: nil, now: now),
                      "the terminal's own snooze silences it")
        XCTAssertTrue(Snooze.isActive(sessionUntil: nil, groupUntil: later, now: now),
                      "a snoozed project silences its terminals")
        XCTAssertTrue(Snooze.isActive(sessionUntil: earlier, groupUntil: later, now: now),
                      "the longer of the two decides")
        XCTAssertFalse(Snooze.isActive(sessionUntil: earlier, groupUntil: earlier, now: now))
        XCTAssertFalse(Snooze.isActive(sessionUntil: nil, groupUntil: nil, now: now))
    }

    func testEndIsTheLaterOfBoth() {
        let a = date("2026-08-10T13:00:00Z"), b = date("2026-08-10T15:00:00Z")
        XCTAssertEqual(Snooze.end(sessionUntil: a, groupUntil: b), b)
        XCTAssertEqual(Snooze.end(sessionUntil: nil, groupUntil: b), b)
        XCTAssertNil(Snooze.end(sessionUntil: nil, groupUntil: nil))
    }

    // A snooze is persisted state: a restart must not un-silence a terminal.
    func testSnoozeSurvivesEncoding() throws {
        var session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        session.snoozedUntil = date("2026-08-10T13:00:00Z")
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)
        XCTAssertEqual(decoded.snoozedUntil, session.snoozedUntil)
    }

    // State written before snoozing existed decodes as "not snoozed".
    func testOlderStateDecodesUnsnoozed() throws {
        let json = """
        {"id":"\(UUID().uuidString)","groupID":"\(UUID().uuidString)","workingDirectory":"/tmp"}
        """
        let session = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
        XCTAssertNil(session.snoozedUntil)
    }
}

// MARK: Project folders (grouping projects in one window's sidebar)

final class ProjectFolderTests: XCTestCase {
    func testLooseGroupsAreThoseInNoFolder() {
        let a = UUID(), b = UUID(), c = UUID()
        var window = WindowModel()
        window.groupIDs = [a, b, c]
        var folder = ProjectFolder(name: "myposter")
        folder.groupIDs = [b]
        window.folders = [folder]
        XCTAssertEqual(window.looseGroupIDs, [a, c])
        XCTAssertEqual(window.folder(of: b)?.name, "myposter")
        XCTAssertNil(window.folder(of: a))
    }

    // A window written before folders existed must still decode — the
    // synthesized decoder would have demanded the key.
    func testWindowWithoutFoldersDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","groupIDs":[]}
        """
        let window = try JSONDecoder().decode(WindowModel.self, from: Data(json.utf8))
        XCTAssertTrue(window.folders.isEmpty)
    }

    // MARK: Dragging projects between folders (WindowModel.move)

    private func window(_ groups: [UUID], folders: [(String, [UUID])] = []) -> WindowModel {
        var window = WindowModel()
        window.groupIDs = groups
        window.folders = folders.map { name, ids in
            var folder = ProjectFolder(name: name)
            folder.groupIDs = ids
            return folder
        }
        window.normalizeGroupOrder()
        return window
    }

    func testDropOnFolderFilesTheProject() {
        let a = UUID(), b = UUID(), c = UUID()
        var w = window([a, b, c], folders: [("box", [a])])
        w.move([c], toFolder: w.folders[0].id)
        XCTAssertEqual(w.folders[0].groupIDs, [a, c])
        XCTAssertEqual(w.looseGroupIDs, [b])
    }

    func testDropOnLooseZoneTakesItOutOfTheFolder() {
        let a = UUID(), b = UUID()
        var w = window([a, b], folders: [("box", [a, b])])
        w.move([a], toFolder: nil)
        XCTAssertEqual(w.folders[0].groupIDs, [b])
        XCTAssertEqual(w.looseGroupIDs, [a])
    }

    // Dropping on a project means "next to this one" — including landing in
    // whatever folder that project lives in.
    func testDropBeforeAProjectInsertsAtThatPosition() {
        let a = UUID(), b = UUID(), c = UUID()
        var w = window([a, b, c], folders: [("box", [a, b])])
        w.move([c], toFolder: w.folders[0].id, before: b)
        XCTAssertEqual(w.folders[0].groupIDs, [a, c, b])
    }

    func testMoveBetweenFoldersLeavesTheOldOne() {
        let a = UUID(), b = UUID()
        var w = window([a, b], folders: [("one", [a]), ("two", [b])])
        let two = w.folders[1].id
        w.move([a], toFolder: two)
        XCTAssertEqual(w.folders[0].groupIDs, [])
        XCTAssertEqual(w.folders[1].groupIDs, [b, a])
        XCTAssertNil(w.folder(of: a).map { $0.name == "one" }.flatMap { $0 ? true : nil })
    }

    // A dragged multi-selection is ONE move, and keeps the order you saw.
    func testMovingSeveralKeepsTheirOrder() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var w = window([a, b, c, d], folders: [("box", [])])
        w.move([c, a], toFolder: w.folders[0].id)
        XCTAssertEqual(w.folders[0].groupIDs, [a, c], "sidebar order, not click order")
        XCTAssertEqual(w.looseGroupIDs, [b, d])
    }

    func testReorderingWithinTheTopLevel() {
        let a = UUID(), b = UUID(), c = UUID()
        var w = window([a, b, c])
        w.move([c], toFolder: nil, before: a)
        XCTAssertEqual(w.looseGroupIDs, [c, a, b])
    }

    // Dropping a project on itself must not reshuffle anything.
    func testDropOnItselfIsANoOp() {
        let a = UUID(), b = UUID()
        var w = window([a, b], folders: [("box", [a, b])])
        let before = w
        w.move([a], toFolder: w.folders[0].id, before: a)
        XCTAssertEqual(w.folders[0].groupIDs, before.folders[0].groupIDs)
    }

    // A project from another window (or one already closed) is not ours to move.
    func testUnknownProjectsAreIgnored() {
        let a = UUID(), stranger = UUID()
        var w = window([a], folders: [("box", [])])
        w.move([stranger], toFolder: w.folders[0].id)
        XCTAssertEqual(w.folders[0].groupIDs, [])
        XCTAssertEqual(w.looseGroupIDs, [a])
    }

    // groupIDs must keep holding every project of the window: it is what
    // sanitizeWindows uses to decide a project lives here at all, so losing an
    // id here would quietly move the project to another window.
    func testEveryProjectStaysInTheWindow() {
        let ids = (0..<5).map { _ in UUID() }
        var w = window(ids, folders: [("one", [ids[0], ids[1]]), ("two", [ids[2]])])
        w.move([ids[3], ids[0]], toFolder: w.folders[1].id)
        w.move([ids[1]], toFolder: nil)
        XCTAssertEqual(Set(w.groupIDs), Set(ids))
        XCTAssertEqual(w.groupIDs.count, ids.count, "no duplicates either")
    }

    func testFolderRoundTrips() throws {
        var folder = ProjectFolder(name: "side")
        folder.color = .teal
        folder.collapsed = true
        folder.groupIDs = [UUID()]
        let decoded = try JSONDecoder().decode(
            ProjectFolder.self, from: try JSONEncoder().encode(folder))
        XCTAssertEqual(decoded, folder)
    }

    // A folder written before `collapsed`/`color` existed keeps working.
    func testFolderDecodesWithoutOptionalFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"box"}
        """
        let folder = try JSONDecoder().decode(ProjectFolder.self, from: Data(json.utf8))
        XCTAssertFalse(folder.collapsed)
        XCTAssertEqual(folder.color, .none)
        XCTAssertTrue(folder.groupIDs.isEmpty)
    }
}

// MARK: Folder overview (what a selected folder shows in the main area)

final class FolderOverviewTests: XCTestCase {
    private func session(_ state: AttentionState, since: Date = Date(),
                         message: String? = nil) -> TerminalSession {
        var s = TerminalSession(groupID: UUID(), workingDirectory: "/tmp/proj")
        s.state = state
        s.stateSince = since
        s.lastMessage = message
        return s
    }

    // A folder overview and a project can't both own the main area: picking a
    // project has to take the overview down, or the sidebar selection and what
    // is on screen drift apart.
    func testSelectingAProjectLeavesTheFolderOverview() {
        let folder = UUID(), project = UUID()
        var window = WindowModel()
        window.selectedFolderID = folder
        window.selectGroup(project)
        XCTAssertEqual(window.selectedGroupID, project)
        XCTAssertNil(window.selectedFolderID)
    }

    // A window written before the overview existed must still decode.
    func testWindowWithoutSelectedFolderDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","groupIDs":[]}
        """
        let window = try JSONDecoder().decode(WindowModel.self, from: Data(json.utf8))
        XCTAssertNil(window.selectedFolderID)
    }

    // The project badge must show the worst thing going on, never the calmest.
    func testProjectBadgeShowsTheMostUrgentState() {
        XCTAssertEqual(AttentionState.mostUrgent(of: [.free, .error, .running]), .error)
        XCTAssertEqual(AttentionState.mostUrgent(of: [.ready, .waiting]), .waiting)
        XCTAssertEqual(AttentionState.mostUrgent(of: [.free, .ready]), .ready)
        XCTAssertEqual(AttentionState.mostUrgent(of: []), .free, "no terminals = nothing going on")
    }

    func testFeedIsNewestFirst() {
        let old = session(.waiting, since: Date(timeIntervalSince1970: 100), message: "old?")
        let new = session(.error, since: Date(timeIntervalSince1970: 900), message: "boom")
        XCTAssertEqual(ActivityFeed.entries([old, new]).map(\.id), [new.id, old.id])
    }

    // A terminal with nothing to say is not a notification.
    func testFeedSkipsTerminalsWithoutAMessage() {
        let quiet = session(.free, message: "ignored while free")
        let silent = session(.ready)
        let loud = session(.waiting, message: "may I?")
        XCTAssertEqual(ActivityFeed.entries([quiet, silent, loud]).map(\.id), [loud.id])
    }

    func testFeedIsCapped() {
        let many = (0..<10).map {
            session(.waiting, since: Date(timeIntervalSince1970: Double($0)), message: "q\($0)")
        }
        XCTAssertEqual(ActivityFeed.entries(many, limit: 3).count, 3)
    }
}

// MARK: Presets (saved arrangements)

final class PresetTests: XCTestCase {
    // A preset's splits are stored by terminal index: the session ids it was
    // saved from are gone by the time it is opened again.
    func testLayoutRoundTripsThroughIndices() {
        let a = UUID(), b = UUID(), c = UUID()
        let live = SplitLayout.row([.leaf(a), .column([.leaf(b), .leaf(c)])])
        let stored = PresetLayout.from(live, sessionIDs: [a, b, c])
        XCTAssertEqual(stored, .row([.leaf(0), .column([.leaf(1), .leaf(2)])]))

        let x = UUID(), y = UUID(), z = UUID()
        XCTAssertEqual(
            stored?.resolved(with: [x, y, z]),
            .row([.leaf(x), .column([.leaf(y), .leaf(z)])]),
            "the arrangement must be rebuilt onto the freshly created terminals")
    }

    func testLayoutDropsPanesThatNoLongerExist() {
        let a = UUID(), b = UUID()
        let stored = PresetLayout.from(.row([.leaf(a), .leaf(b)]), sessionIDs: [a, b])
        // Opened with only one terminal: the missing leaf collapses away.
        XCTAssertEqual(stored?.resolved(with: [a]), .leaf(a))
    }

    func testLayoutIgnoresSessionsOutsideTheProject() {
        let a = UUID(), stray = UUID()
        XCTAssertEqual(PresetLayout.from(.row([.leaf(a), .leaf(stray)]), sessionIDs: [a]), .leaf(0))
        XCTAssertNil(PresetLayout.from(.leaf(stray), sessionIDs: [a]))
    }

    func testPresetRoundTrips() throws {
        var project = PresetProject(name: "designer-library")
        project.folderName = "myposter"
        project.viewMode = .cluster
        project.clusterLayout = .row([.leaf(0), .leaf(1)])
        var terminal = PresetTerminal(workingDirectory: "/tmp/x")
        terminal.startupCommand = "pnpm dev"
        terminal.tags = ["wip"]
        project.terminals = [terminal, PresetTerminal(workingDirectory: "/tmp/y")]
        let preset = Preset(name: "Frontend", projects: [project])

        let decoded = try JSONDecoder().decode(
            [Preset].self, from: try JSONEncoder().encode([preset]))
        XCTAssertEqual(decoded, [preset])
        XCTAssertEqual(decoded[0].terminalCount, 2)
    }

    // A preset is a template: it must never carry a Claude conversation id,
    // or opening it twice would put two terminals on the same conversation.
    func testPresetCarriesNoConversationID() throws {
        var terminal = PresetTerminal(workingDirectory: "/tmp/x")
        terminal.customTitle = "agent"
        let data = try JSONEncoder().encode(terminal)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("claude"))
        XCTAssertFalse(json.lowercased().contains("session"))
    }
}

// MARK: Help catalogue (the searchable feature list)

final class HelpTests: XCTestCase {
    // Every entry resolves to real text — a catalogue that lists a key nobody
    // translated would show the raw key to the user.
    func testEveryEntryHasText() {
        L10n.current = .en
        for section in Help.sections {
            XCTAssertFalse(L10n.t(section.titleKey).isEmpty, "\(section.titleKey)")
            for entry in section.entries {
                XCTAssertFalse(L10n.t(entry.titleKey).isEmpty, "\(entry.titleKey)")
                XCTAssertNotEqual(L10n.t(entry.titleKey), entry.titleKey.rawValue,
                                  "untranslated: \(entry.titleKey)")
                if let detail = entry.detailKey {
                    XCTAssertNotEqual(L10n.t(detail), detail.rawValue, "untranslated: \(detail)")
                }
            }
        }
    }

    func testSearchMatchesTitleAndDetail() {
        L10n.current = .en
        XCTAssertFalse(Help.sections(matching: "folder").isEmpty)
        XCTAssertFalse(Help.sections(matching: "⌘K").isEmpty, "shortcuts are searchable")
        // Every word has to hit, so a two-word query narrows instead of widening.
        XCTAssertTrue(Help.sections(matching: "folder zzzz").isEmpty)
    }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(Help.sections(matching: "   ").count, Help.sections.count)
    }

    func testFeatureRequestURLIsAGitHubIssue() throws {
        let url = try XCTUnwrap(Help.featureRequestURL(version: "9.9.9"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/issues/new"))
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("labels=enhancement"))
        XCTAssertTrue(url.absoluteString.contains("9.9.9"), "the build goes in the body")
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


final class DevServerScannerTests: XCTestCase {
    func testParseListenersReadsPidCommandPort() {
        let output = """
        p870
        cCode Helper (Plugin)
        f42
        n127.0.0.1:60054
        p18533
        cnode
        f46
        n127.0.0.1:8080
        """
        let listeners = DevServerScanner.parseListeners(output)
        XCTAssertEqual(listeners, [
            DevServerScanner.Listener(pid: 870, command: "Code Helper (Plugin)", port: 60054),
            DevServerScanner.Listener(pid: 18533, command: "node", port: 8080),
        ])
    }

    func testParseListenersDedupesIPv4AndIPv6Twins() {
        let output = """
        p100
        cnode
        f16
        n*:3000
        f17
        n[::1]:3000
        """
        XCTAssertEqual(DevServerScanner.parseListeners(output).count, 1)
    }

    func testParseCwdsMapsPidToDirectory() {
        let output = """
        p870
        fcwd
        n/
        p18533
        fcwd
        n/Users/x/dev/repo
        """
        XCTAssertEqual(DevServerScanner.parseCwds(output), [870: "/", 18533: "/Users/x/dev/repo"])
    }

    func testIsPathUnderRespectsComponentBoundaries() {
        XCTAssertTrue(DevServerScanner.isPath("/a/b", under: "/a/b"))
        XCTAssertTrue(DevServerScanner.isPath("/a/b/c", under: "/a/b"))
        XCTAssertFalse(DevServerScanner.isPath("/a/barn", under: "/a/b"))
    }

    func testMatchAttributesServerInsideProjectDirectory() {
        let group = UUID()
        let found = DevServerScanner.match(
            listeners: [.init(pid: 1, command: "node", port: 8080)],
            cwds: [1: "/dev/repo/packages/app"],
            projectDirs: [group: ["/dev/repo"]],
            isProjectRoot: { _ in false })
        XCTAssertEqual(found[group]?.map(\.port), [8080])
    }

    func testMatchAcceptsServerAtRepoRootAboveTerminal() {
        // Server started at the repo root (e.g. in an IDE terminal), while the
        // Planchette terminal sits in a package below it.
        let group = UUID()
        let found = DevServerScanner.match(
            listeners: [.init(pid: 1, command: "node", port: 5173)],
            cwds: [1: "/dev/repo"],
            projectDirs: [group: ["/dev/repo/packages/app"]],
            isProjectRoot: { $0 == "/dev/repo" })
        XCTAssertEqual(found[group]?.map(\.port), [5173])
    }

    func testMatchRejectsAncestorThatIsNoProjectRoot() {
        // A listener in ~/development must not claim every project below it.
        let group = UUID()
        let found = DevServerScanner.match(
            listeners: [.init(pid: 1, command: "node", port: 3000)],
            cwds: [1: "/Users/x/development"],
            projectDirs: [group: ["/Users/x/development/repo"]],
            isProjectRoot: { _ in false })
        XCTAssertTrue(found.isEmpty)
    }

    func testMatchSkipsEphemeralInspectorAndIDEHelperPorts() {
        let group = UUID()
        let found = DevServerScanner.match(
            listeners: [
                .init(pid: 1, command: "node", port: 55000),          // ephemeral
                .init(pid: 2, command: "node", port: 9229),           // inspector
                .init(pid: 3, command: "Code Helper (Plugin)", port: 8081),
            ],
            cwds: [1: "/dev/repo", 2: "/dev/repo", 3: "/dev/repo"],
            projectDirs: [group: ["/dev/repo"]],
            isProjectRoot: { _ in true })
        XCTAssertTrue(found.isEmpty)
    }

    func testMatchDedupesPortPerProjectAndSorts() {
        let group = UUID()
        let found = DevServerScanner.match(
            listeners: [
                .init(pid: 1, command: "node", port: 8080),
                .init(pid: 2, command: "node", port: 8080),
                .init(pid: 3, command: "node", port: 3000),
            ],
            cwds: [1: "/dev/repo", 2: "/dev/repo/sub", 3: "/dev/repo"],
            projectDirs: [group: ["/dev/repo"]],
            isProjectRoot: { _ in false })
        XCTAssertEqual(found[group]?.map(\.port), [3000, 8080])
    }
}

final class IDEResolveTests: XCTestCase {
    private var installed: [IDE] { IDEs.known }
    private func ide(_ name: String) -> IDE { IDEs.known.first { $0.name == name }! }

    // The bug this shipped with: every myposter checkout carries .idea, and the
    // button opened VS Code because it stood first in the list.
    func testProjectMarkerBeatsListOrder() {
        let target = IDEs.resolve(
            markers: [".idea", "package.json"],
            defaultBundleID: nil,
            running: ["com.microsoft.VSCode", "com.jetbrains.PhpStorm"],
            installed: installed)
        XCTAssertEqual(target, ide("PhpStorm"))
    }

    func testVSCodeMarkerPicksVSCode() {
        let target = IDEs.resolve(
            markers: [".vscode"],
            defaultBundleID: nil,
            running: ["com.jetbrains.PhpStorm", "com.microsoft.VSCode"],
            installed: installed)
        XCTAssertEqual(target, ide("Visual Studio Code"))
    }

    func testDefaultAlwaysWinsOverMarkerAndRunning() {
        let target = IDEs.resolve(
            markers: [".idea"],
            defaultBundleID: "com.microsoft.VSCode",
            running: ["com.jetbrains.PhpStorm"],
            installed: installed)
        XCTAssertEqual(target, ide("Visual Studio Code"))
    }

    func testLastActivatedBreaksTheTieWithoutAMarker() {
        let target = IDEs.resolve(
            markers: [],
            defaultBundleID: nil,
            running: ["com.microsoft.VSCode", "com.jetbrains.PhpStorm"],
            installed: installed,
            lastActivated: "com.jetbrains.PhpStorm")
        XCTAssertEqual(target, ide("PhpStorm"))
    }

    func testNoMarkerAndNothingRunningHasNoTarget() {
        // Then the button reads "open a new IDE" and asks instead of guessing.
        XCTAssertNil(IDEs.resolve(
            markers: [], defaultBundleID: nil, running: [], installed: installed))
    }

    // Handing Xcode a plain folder opens a window and closes it again — the
    // "I just see a blank, then it closes" report. It is only ever a target
    // when the checkout has something it can open.
    func testXcodeIsNoTargetForAPlainFolder() {
        let target = IDEs.resolve(
            markers: [],
            defaultBundleID: "com.apple.dt.Xcode",
            running: ["com.apple.dt.Xcode"],
            installed: [ide("Xcode")])
        XCTAssertNil(target)
    }

    func testXcodeIsATargetWithAProjectMarker() {
        let target = IDEs.resolve(
            markers: ["xcode"],
            defaultBundleID: nil,
            running: [],
            installed: [ide("Xcode")])
        XCTAssertEqual(target, ide("Xcode"))
    }

    func testUninstalledDefaultFallsBackToTheEvidence() {
        let target = IDEs.resolve(
            markers: [".idea"],
            defaultBundleID: "com.gone.ide",
            running: [],
            installed: installed)
        XCTAssertEqual(target, ide("WebStorm"))  // first .idea IDE in known order
    }

    func testMarkersAndXcodeTargetReadTheRealDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planchette-ide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".idea"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\n".write(
            to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markers = IDEs.markers(in: dir.path)
        XCTAssertTrue(markers.contains(".idea"))
        XCTAssertTrue(markers.contains("xcode"), "Package.swift is an Xcode target")
        XCTAssertEqual(
            IDEs.xcodeTarget(in: dir.path), dir.appendingPathComponent("Package.swift").path)
        XCTAssertEqual(IDEs.target(directory: dir.path, for: ide("PhpStorm")), dir.path)
    }
}

final class DevServerURLTests: XCTestCase {
    // The real Vite banner: the network address is the one worth a click, and
    // the scheme is https — guessing http://localhost opens a dead page.
    private let viteBanner = """
          VITE v8.1.0  ready in 4352 ms

          ➜  Local:   https://localhost:8082/
          ➜  Local:   https://vite.myposter.de:8082/
          ➜  Network: https://photo-frame-designer.myposter.de:8082/
        """

    func testPrefersTheNetworkAddress() {
        XCTAssertEqual(
            DevServerScanner.bestURL(forPort: 8082, in: viteBanner)?.absoluteString,
            "https://photo-frame-designer.myposter.de:8082/")
    }

    func testIgnoresOtherPorts() {
        XCTAssertNil(DevServerScanner.bestURL(forPort: 3000, in: viteBanner))
    }

    func testFallsBackToANonLocalLocalAddress() {
        let text = """
              ➜  Local:   https://localhost:8082/
              ➜  Local:   https://vite.kartenliebe.de:8082/
            """
        XCTAssertEqual(
            DevServerScanner.bestURL(forPort: 8082, in: text)?.absoluteString,
            "https://vite.kartenliebe.de:8082/")
    }

    func testKeepsTheSchemeOfALocalOnlyServer() {
        XCTAssertEqual(
            DevServerScanner.bestURL(forPort: 5173, in: "  Local: https://localhost:5173/")?
                .absoluteString,
            "https://localhost:5173/")
    }

    func testNothingAnnouncedMeansTheHonestGuess() {
        XCTAssertNil(DevServerScanner.bestURL(forPort: 8080, in: "Serving HTTP on :: port 8080"))
        let server = DevServer(port: 8080, processName: "python", directory: "/x")
        XCTAssertEqual(server.url.absoluteString, "http://localhost:8080")
        XCTAssertEqual(server.label, "8080", "the chip is the port alone")
    }

    func testLaterBannerWinsAfterARestart() {
        let text = """
            ➜  Network: http://old.example.com:8082/
            ➜  Network: https://new.example.com:8082/
            """
        XCTAssertEqual(
            DevServerScanner.bestURL(forPort: 8082, in: text)?.absoluteString,
            "https://new.example.com:8082/")
    }

    func testStripsTrailingProsePunctuation() {
        XCTAssertEqual(
            DevServerScanner.bestURL(forPort: 4000, in: "listening at http://app.test:4000.")?
                .absoluteString,
            "http://app.test:4000")
    }
}

/// The menu behind the "look at code" button. It is built in AppKit because a
/// SwiftUI `Menu` shipped as a blank flash next to a terminal surface; these
/// tests are what keeps "the menu came up empty" from happening unnoticed again.
@MainActor
final class IDEMenuTests: XCTestCase {
    private let vscode = IDEs.known.first { $0.name == "Visual Studio Code" }!
    private let phpstorm = IDEs.known.first { $0.name == "PhpStorm" }!
    private let xcode = IDEs.known.first { $0.name == "Xcode" }!

    private func menu(default def: String? = nil, target: IDE? = nil,
                      directory: String = "/tmp") -> NSMenu {
        IDEMenuActions.shared.menu(
            directory: directory,
            installed: [vscode, phpstorm, xcode],
            running: [phpstorm.bundleID],
            defaultBundleID: def,
            target: target)
    }

    func testMenuListsEveryInstalledIDEAndTheDefaultSubmenu() {
        let items = menu().items
        XCTAssertFalse(items.isEmpty, "the menu must never come up empty")
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Visual Studio Code"))
        XCTAssertTrue(titles.contains("PhpStorm"))
        XCTAssertTrue(titles.contains(L10n.t(.defaultIDEMenu)))
        let defaults = items.last?.submenu
        XCTAssertEqual(defaults?.items.count, 5, "3 IDEs + separator + None")
    }

    func testRunningIDEIsMarkedAndTheTargetIsBold() {
        let items = menu(target: phpstorm).items
        let php = items.first { $0.title == "PhpStorm" }
        let code = items.first { $0.title == "Visual Studio Code" }
        XCTAssertEqual(php?.state, .mixed, "running IDEs are marked")
        XCTAssertEqual(code?.state, .off)
        XCTAssertNotNil(php?.attributedTitle, "what a click opens reads bold")
    }

    func testXcodeIsListedButDisabledWithoutAProjectFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planchette-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = menu(directory: dir.path).items.first { $0.title == "Xcode" }
        XCTAssertNotNil(item, "it stays listed")
        XCTAssertFalse(item?.isEnabled ?? true, "but it cannot open a plain folder")
    }

    func testTheDefaultCarriesTheCheckmarkAndNoneIsTheAlternative() {
        let withDefault = menu(default: phpstorm.bundleID).items.last?.submenu?.items ?? []
        XCTAssertEqual(withDefault.first { $0.title == "PhpStorm" }?.state, .on)
        XCTAssertEqual(withDefault.first { $0.title == L10n.t(.noDefaultIDE) }?.state, .off)
        let withNone = menu().items.last?.submenu?.items ?? []
        XCTAssertEqual(withNone.first { $0.title == L10n.t(.noDefaultIDE) }?.state, .on)
    }
}

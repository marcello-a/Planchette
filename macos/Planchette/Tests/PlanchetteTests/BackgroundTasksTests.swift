import XCTest
@testable import Planchette

/// The payloads below are not invented: they are what Claude Code 2.1.299 sent
/// to its hooks when it ran against a local stand-in for the API
/// (`scripts/perf/README.md`), trimmed to the fields that matter here.
final class BackgroundTasksTests: XCTestCase {
    private func event(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private func read(_ json: String) -> BackgroundTaskSignal? {
        BackgroundTasks.signal(from: event(json))
    }

    private let shellOne = BackgroundTask(id: "bni865gr9", kind: .shell, title: "stub shell one")
    private let shellTwo = BackgroundTask(id: "b0n32jx3v", kind: .shell, title: "stub shell two")
    private let agent = BackgroundTask(id: "a1ac2601f78e3938a", kind: .agent, title: "stub background agent")

    private let stopWithThree = """
    {"hook_event_name":"Stop","stop_hook_active":false,"session_crons":[],"background_tasks":[
      {"id":"bni865gr9","type":"shell","status":"running","description":"stub shell one","command":"sleep 40"},
      {"id":"b0n32jx3v","type":"shell","status":"running","description":"stub shell two","command":"sleep 60"},
      {"id":"a1ac2601f78e3938a","type":"subagent","status":"running","description":"stub background agent","agent_type":"general-purpose"}]}
    """

    // MARK: Stop — Claude's own list

    func testStopCarriesTheListAsClaudeCountsIt() {
        XCTAssertEqual(read(stopWithThree), .snapshot([shellOne, shellTwo, agent]))
    }

    func testAnEmptyListMeansNothingRunsAnymore() {
        let signal = read(#"{"hook_event_name":"Stop","background_tasks":[],"session_crons":[]}"#)
        XCTAssertEqual(signal, .snapshot([]))
        XCTAssertEqual(BackgroundTasks.apply(try! XCTUnwrap(signal), to: [shellOne]), [])
    }

    func testAnOlderClaudeCodeWithoutTheListSaysNothing() {
        // Not "empty": silence must not erase what a shell launch already told us.
        XCTAssertNil(read(#"{"hook_event_name":"Stop","stop_hook_active":false}"#))
    }

    func testAnEntryThatIsOverIsNotCounted() {
        let signal = read("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"a","type":"shell","status":"completed","description":"done"},
          {"id":"b","type":"shell","status":"running","description":"live"},
          {"type":"shell","status":"running","description":"no id"}]}
        """)
        XCTAssertEqual(signal, .snapshot([BackgroundTask(id: "b", kind: .shell, title: "live")]))
    }

    func testUnknownTypesCountAsShellsAndAnyAgentTypeAsAnAgent() {
        let signal = read("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"m","type":"monitor","status":"running","command":"tail -f log"},
          {"id":"r","type":"remote_agent","status":"running","description":"cloud review"}]}
        """)
        XCTAssertEqual(signal, .snapshot([
            BackgroundTask(id: "m", kind: .shell, title: "tail -f log"),
            BackgroundTask(id: "r", kind: .agent, title: "cloud review"),
        ]))
    }

    func testAMultiLineTitleBecomesOneShortLine() throws {
        let long = String(repeating: "word ", count: 40)
        let signal = try XCTUnwrap(read("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"a","type":"shell","status":"running","description":"first\\nsecond  line \(long)"}]}
        """))
        guard case .snapshot(let tasks) = signal, let title = tasks.first?.title else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertFalse(title.contains("\n"))
        XCTAssertLessThanOrEqual(title.count, 61)
    }

    func testSubagentStopIsNotTrusted() {
        // It still lists the agent that is stopping as running.
        XCTAssertNil(read("""
        {"hook_event_name":"SubagentStop","background_tasks":[
          {"id":"a1ac2601f78e3938a","type":"subagent","status":"running"}]}
        """))
    }

    // MARK: PostToolUse — a launch, ahead of the Stop

    func testABackgroundShellIsNamedByItsToolResponse() {
        let signal = read("""
        {"hook_event_name":"PostToolUse","tool_name":"Bash",
         "tool_input":{"command":"sleep 40","description":"stub shell one","run_in_background":true},
         "tool_response":{"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"bni865gr9"}}
        """)
        XCTAssertEqual(signal, .started(shellOne))
    }

    func testAShellWithoutADescriptionIsNamedByItsCommand() {
        let signal = read("""
        {"hook_event_name":"PostToolUse","tool_name":"Bash",
         "tool_input":{"command":"npm run dev","run_in_background":true},
         "tool_response":{"backgroundTaskId":"x1"}}
        """)
        XCTAssertEqual(signal, .started(BackgroundTask(id: "x1", kind: .shell, title: "npm run dev")))
    }

    func testAForegroundCommandStartsNothing() {
        XCTAssertNil(read("""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},
         "tool_response":{"stdout":"a b","stderr":"","interrupted":false}}
        """))
    }

    func testAnAgentLaunchedWithoutWaitingIsABackgroundAgent() {
        let signal = read("""
        {"hook_event_name":"PostToolUse","tool_name":"Agent",
         "tool_input":{"description":"stub background agent","prompt":"work","subagent_type":"general-purpose"},
         "tool_response":{"isAsync":true,"status":"async_launched","agentId":"a1ac2601f78e3938a",
                          "description":"stub background agent"}}
        """)
        XCTAssertEqual(signal, .started(agent))
    }

    func testAnAgentThatWasWaitedForStartsNothing() {
        XCTAssertNil(read("""
        {"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"x"},
         "tool_response":{"status":"completed","agentId":"a1","content":[]}}
        """))
    }

    func testAToolResponseThatIsPlainTextIsIgnored() {
        XCTAssertNil(read(#"{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":"file text"}"#))
    }

    // MARK: Task notifications — the end of a task while Claude waits

    private func notification(id: String, status: String) -> String {
        "<task-notification>\\n<task-id>\(id)</task-id>\\n<tool-use-id>toolu_x</tool-use-id>\\n"
            + "<output-file>/tmp/x.output</output-file>\\n<status>\(status)</status>\\n"
            + "<summary>Background command \\\"x\\\" finished</summary>\\n</task-notification>"
    }

    func testANotificationEndsItsTask() {
        let json = #"{"hook_event_name":"UserPromptSubmit","prompt":"\#(notification(id: "bni865gr9", status: "completed"))"}"#
        XCTAssertEqual(read(json), .finished(["bni865gr9"]))
    }

    func testFailedAndKilledTasksAreOverToo() {
        for status in ["failed", "killed", "stopped"] {
            let json = #"{"hook_event_name":"UserPromptSubmit","prompt":"\#(notification(id: "t", status: status))"}"#
            XCTAssertEqual(read(json), .finished(["t"]), status)
        }
    }

    func testANotificationAboutATaskThatGoesOnRemovesNothing() {
        let json = #"{"hook_event_name":"UserPromptSubmit","prompt":"\#(notification(id: "t", status: "running"))"}"#
        XCTAssertNil(read(json))
        let noStatus = #"{"hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>t</task-id>\n<event>line of output</event>\n</task-notification>"}"#
        XCTAssertNil(read(noStatus))
    }

    func testTwoNotificationsInOnePromptEndBothTasks() {
        let prompt = notification(id: "one", status: "completed") + "\\n" + notification(id: "two", status: "killed")
        XCTAssertEqual(BackgroundTasks.finishedIDs(inNotification: prompt.replacingOccurrences(of: "\\n", with: "\n")),
                       ["one", "two"])
    }

    func testAPromptTheUserTypedEndsNothing() {
        XCTAssertNil(read(#"{"hook_event_name":"UserPromptSubmit","prompt":"fix the <task-id> parser"}"#))
        XCTAssertNil(read(#"{"hook_event_name":"UserPromptSubmit"}"#))
    }

    func testOnlyClaudesOwnNoticeIsANotification() {
        XCTAssertTrue(BackgroundTasks.isNotification("<task-notification>\n<task-id>a</task-id>"))
        XCTAssertTrue(BackgroundTasks.isNotification("  \n<task-notification>"))
        XCTAssertFalse(BackgroundTasks.isNotification("please explain <task-notification> to me"))
        XCTAssertFalse(BackgroundTasks.isNotification("fix the build"))
        XCTAssertFalse(BackgroundTasks.isNotification(""))
    }

    func testAMalformedNotificationDoesNotLoopOrCrash() {
        XCTAssertEqual(BackgroundTasks.finishedIDs(inNotification: "<task-notification>"), [])
        XCTAssertEqual(BackgroundTasks.finishedIDs(inNotification: "<task-notification><task-id>a</task-id>"), [])
        XCTAssertEqual(BackgroundTasks.finishedIDs(inNotification: "<task-notification></task-notification><task-notification>"), [])
    }

    // MARK: A Claude process starts or ends — the tasks are its, not the conversation's

    func testAClearKeepsTheTasksBecauseTheProcessGoesOn() {
        // Observed: after /clear the same shell was still listed, under a new session id.
        XCTAssertNil(read(#"{"hook_event_name":"SessionEnd","reason":"clear"}"#))
        XCTAssertNil(read(#"{"hook_event_name":"SessionStart","source":"clear"}"#))
        XCTAssertNil(read(#"{"hook_event_name":"SessionStart","source":"compact"}"#))
        XCTAssertNil(read(#"{"hook_event_name":"SessionStart","source":"fork"}"#))
    }

    func testANewClaudeProcessStartsWithNoTasks() {
        XCTAssertEqual(read(#"{"hook_event_name":"SessionStart","source":"startup"}"#), .reset)
        XCTAssertEqual(read(#"{"hook_event_name":"SessionStart","source":"resume"}"#), .reset)
    }

    func testAnEndedClaudeProcessTakesItsTasksAlong() {
        for reason in ["prompt_input_exit", "logout", "other"] {
            XCTAssertEqual(read(#"{"hook_event_name":"SessionEnd","reason":"\#(reason)"}"#), .reset, reason)
        }
        XCTAssertEqual(read(#"{"hook_event_name":"SessionEnd"}"#), .reset, "no reason: treat as the end")
        XCTAssertNil(read(#"{"hook_event_name":"SessionEnd","reason":"resume"}"#))
    }

    func testOtherEventsSayNothing() {
        for name in ["PreToolUse", "Notification", "PermissionRequest", "SubagentStart", "PreCompact"] {
            XCTAssertNil(read(#"{"hook_event_name":"\#(name)","background_tasks":[{"id":"a","type":"shell"}]}"#), name)
        }
        XCTAssertNil(read("{}"))
    }

    // MARK: Applying

    func testStartingTheSameTaskTwiceKeepsOneEntry() {
        let renamed = BackgroundTask(id: shellOne.id, kind: .shell, title: "renamed")
        let list = BackgroundTasks.apply(.started(renamed), to: BackgroundTasks.apply(.started(shellOne), to: [shellTwo]))
        XCTAssertEqual(list, [shellTwo, renamed])
    }

    func testFinishingAnUnknownTaskChangesNothing() {
        XCTAssertEqual(BackgroundTasks.apply(.finished(["nope"]), to: [shellOne]), [shellOne])
    }

    func testASnapshotReplacesWhatAGuessAddedBefore() {
        // A launch added a shell that ended within the same turn: the Stop does not list it.
        let list = BackgroundTasks.apply(.started(shellOne), to: [])
        XCTAssertEqual(BackgroundTasks.apply(.snapshot([]), to: list), [])
    }

    // MARK: The real session, replayed

    func testReplayOfTheCapturedSession() throws {
        func play(_ json: String, _ list: [BackgroundTask]) -> [BackgroundTask] {
            guard let signal = BackgroundTasks.signal(from: event(json)) else { return list }
            return BackgroundTasks.apply(signal, to: list)
        }
        var list: [BackgroundTask] = []
        list = play(#"{"hook_event_name":"SessionStart","source":"startup"}"#, list)
        // Shell one starts: the tool call, then the end of the turn.
        list = play("""
        {"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"description":"stub shell one"},
         "tool_response":{"backgroundTaskId":"bni865gr9"}}
        """, list)
        XCTAssertEqual(list, [shellOne], "visible while the turn still runs")
        list = play(#"{"hook_event_name":"Stop","background_tasks":[{"id":"bni865gr9","type":"shell","status":"running","description":"stub shell one"}]}"#, list)
        XCTAssertEqual(list, [shellOne])
        // Shell two and an agent.
        list = play(stopWithThree, list)
        XCTAssertEqual(BackgroundTasks.count(list, of: .shell), 2)
        XCTAssertEqual(BackgroundTasks.count(list, of: .agent), 1)
        // Shell one ends: the notification arrives as a prompt, before the next Stop.
        list = play(#"{"hook_event_name":"UserPromptSubmit","prompt":"\#(notification(id: "bni865gr9", status: "completed"))"}"#, list)
        XCTAssertEqual(list, [shellTwo, agent], "gone at once, not at the end of the follow-up turn")
        // /clear: a new session id, the same process — nothing changes.
        list = play(#"{"hook_event_name":"SessionEnd","reason":"clear"}"#, list)
        list = play(#"{"hook_event_name":"SessionStart","source":"clear"}"#, list)
        XCTAssertEqual(list, [shellTwo, agent])
        // The agent and shell two end; the last Stop lists nothing.
        list = play(#"{"hook_event_name":"UserPromptSubmit","prompt":"\#(notification(id: "a1ac2601f78e3938a", status: "completed"))"}"#, list)
        list = play(#"{"hook_event_name":"UserPromptSubmit","prompt":"\#(notification(id: "b0n32jx3v", status: "completed"))"}"#, list)
        XCTAssertEqual(list, [])
        list = play(stopWithThree, list)
        list = play(#"{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#, list)
        XCTAssertEqual(list, [], "Claude quit")
    }

    func testTheApiCountsByKindAndOmitsTheKeyWhenNothingRuns() {
        XCTAssertNil(BackgroundTasks.summary([]))
        XCTAssertEqual(BackgroundTasks.summary([shellOne, shellTwo, agent]), ["shells": 2, "agents": 1])
        XCTAssertEqual(BackgroundTasks.summary([agent]), ["shells": 0, "agents": 1])
    }

    // MARK: What the badge says

    func testTheTooltipNamesWhatRuns() {
        L10n.current = .en
        let tip = BackgroundTasks.tooltip(for: [shellOne, agent])
        XCTAssertEqual(tip, "Running in the background:\nShell: stub shell one\nAgent: stub background agent")
    }

    func testATaskWithoutATitleIsNamedByItsKind() {
        L10n.current = .en
        let tip = BackgroundTasks.tooltip(for: [BackgroundTask(id: "a", kind: .shell, title: "")])
        XCTAssertEqual(tip, "Running in the background:\nShell")
    }

    func testALongListIsCutAndSummed() {
        L10n.current = .en
        let tasks = (1...9).map { BackgroundTask(id: "\($0)", kind: .shell, title: "job \($0)") }
        let lines = BackgroundTasks.tooltip(for: tasks).split(separator: "\n")
        XCTAssertEqual(lines.count, 1 + BackgroundTasks.tooltipRows + 1)
        XCTAssertEqual(lines.last, "… and 3 more")
    }

    func testEveryLanguageHasTheTexts() {
        let keys: [LKey] = [.detailBackgroundTasks, .detailBackgroundTasksHelp, .backgroundTasksTooltip,
                            .backgroundShell, .backgroundAgent, .backgroundTasksMore]
        for language in AppLanguage.allCases {
            L10n.current = language
            for key in keys {
                XCTAssertNotEqual(L10n.t(key), key.rawValue, "\(language) \(key)")
            }
        }
        L10n.current = .en
    }
}

final class BackgroundTaskSpriteTests: XCTestCase {
    func testOneTaskIsTheTerminalPrompt() {
        XCTAssertEqual(BackgroundTaskSprite.rows(count: 1), BackgroundTaskSprite.prompt)
        XCTAssertEqual(BackgroundTaskSprite.rows(count: 0), BackgroundTaskSprite.prompt)
    }

    func testFromTwoOnTheWindowHoldsTheNumber() {
        for count in 2...9 {
            let rows = BackgroundTaskSprite.rows(count: count)
            XCTAssertNotEqual(rows, BackgroundTaskSprite.prompt, "\(count)")
            XCTAssertEqual(rows.count, BackgroundTaskSprite.height)
            XCTAssertEqual(Set(rows.map(\.count)).count, 1, "rows of one width: \(count)")
            XCTAssertEqual(rows[0].count, 9, "one digit keeps the prompt window's width")
        }
    }

    func testEveryDigitLooksDifferent() {
        let sprites = (2...9).map { BackgroundTaskSprite.rows(count: $0) }
        XCTAssertEqual(Set(sprites).count, sprites.count)
        XCTAssertNotEqual(BackgroundTaskSprite.rows(count: 10), BackgroundTaskSprite.rows(count: 11))
    }

    func testTwoDigitsMakeTheWindowWiderNotTaller() {
        let rows = BackgroundTaskSprite.rows(count: 12)
        XCTAssertEqual(rows.count, BackgroundTaskSprite.height)
        XCTAssertEqual(rows[0].count, 11)
        XCTAssertEqual(Set(rows.map(\.count)).count, 1)
    }

    func testTheNumberIsDrawnInsideTheFrameWithAirAroundIt() {
        for count in [2, 7, 10, 58, 99] {
            let rows = BackgroundTaskSprite.rows(count: count).map(Array.init)
            let width = rows[0].count
            // Frame: the corners are cut, the rest of the border is lit.
            XCTAssertEqual(rows[0][0], ".")
            XCTAssertEqual(rows[0][width - 1], ".")
            XCTAssertTrue(rows[0][1..<(width - 1)].allSatisfy { $0 == "#" })
            XCTAssertTrue(rows[8][1..<(width - 1)].allSatisfy { $0 == "#" })
            // Digits: 5 rows, and not a pixel on the row under the top border or above the bottom one.
            XCTAssertTrue(rows[1][1..<(width - 1)].allSatisfy { $0 == "." }, "\(count)")
            XCTAssertTrue(rows[7][1..<(width - 1)].allSatisfy { $0 == "." }, "\(count)")
            XCTAssertTrue(rows[2...6].contains { $0[1..<(width - 1)].contains("#") }, "\(count)")
            // Air to the left and right of the digits.
            for row in rows[2...6] {
                XCTAssertEqual(row[1], ".", "\(count)")
                XCTAssertEqual(row[width - 2], ".", "\(count)")
            }
        }
    }

    func testOnlyLitAndUnlitPixels() {
        for count in [1, 2, 10, 99, 500] {
            for row in BackgroundTaskSprite.rows(count: count) {
                XCTAssertTrue(row.allSatisfy { $0 == "#" || $0 == "." }, "\(count)")
            }
        }
    }

    func testAbsurdCountsStayAtTheLargestNumber() {
        XCTAssertEqual(BackgroundTaskSprite.rows(count: 100), BackgroundTaskSprite.rows(count: 99))
        XCTAssertEqual(BackgroundTaskSprite.rows(count: 5000), BackgroundTaskSprite.rows(count: 99))
    }
}

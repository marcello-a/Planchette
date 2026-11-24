import XCTest
@testable import Planchette

/// What the hooks say beyond an event's name: whether a notification asks something, whether
/// a turn died, and whether a question still stands. Ported from session-controller's hook
/// script, which learned them from what Claude Code actually sends.
final class HookQuestionTests: XCTestCase {
    // MARK: notification_type

    func testOnlyTheAskingNotificationTypesAreQuestions() {
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            XCTAssertEqual(AttentionState.forHookEvent("Notification", message: "x", notificationType: type), .waiting, type)
        }
        for type in ["idle_prompt", "auth_success", "auth_storage_failure", "elicitation_complete",
                     "agent_completed", "quota_auto_resume_fired", "plugin_notification", "brand_new_type"] {
            XCTAssertNil(AttentionState.forHookEvent("Notification", message: "x", notificationType: type), type)
        }
    }

    // An older Claude Code sends no type: only the idle nudge is known, by its words.
    func testWithoutATypeOnlyTheIdleNudgeIsNews() {
        XCTAssertNil(AttentionState.forHookEvent("Notification", message: "Claude is waiting for your input"))
        XCTAssertEqual(AttentionState.forHookEvent("Notification", message: "Claude needs your permission to use Bash"), .waiting)
        XCTAssertTrue(AttentionState.isQuestion(notificationType: nil, message: nil))
    }

    // MARK: StopFailure and subagents

    func testAFailedTurnIsAnError() {
        XCTAssertEqual(AttentionState.forHookEvent("StopFailure", message: "API Error: Rate limit reached"), .error)
    }

    // An in-process teammate reports its own Stop; the main agent works on.
    func testASubagentsStopIsNotTheTurns() {
        XCTAssertNil(AttentionState.forHookEvent("Stop", isSubagent: true))
        XCTAssertNil(AttentionState.forHookEvent("StopFailure", isSubagent: true))
        XCTAssertEqual(AttentionState.forHookEvent("Stop"), .ready)
    }

    // MARK: Which tool asked

    func testAPermissionNotificationNamesItsTool() {
        XCTAssertEqual(AttentionState.Question.tool(inMessage: "Claude needs your permission to use Bash"), "Bash")
        XCTAssertEqual(AttentionState.Question.tool(inMessage: "Claude needs your permission to use mcp__github__create_pr now"),
                       "mcp__github__create_pr")
        XCTAssertNil(AttentionState.Question.tool(inMessage: "Claude needs your permission"))
        XCTAssertNil(AttentionState.Question.tool(inMessage: nil))
    }

    // MARK: Whether a question stands

    private let bash = AttentionState.Question(tool: "Bash", toolUseID: nil)

    private func stands(_ question: AttentionState.Question, _ event: String,
                        subagent: Bool = false, tool: String? = nil, id: String? = nil) -> Bool {
        AttentionState.questionStands(question, after: event, isSubagent: subagent, toolName: tool, toolUseID: id)
    }

    // Parallel tools: Read finishing says nothing about the Bash call that waits on you.
    func testAnotherToolFinishingLeavesTheQuestion() {
        XCTAssertTrue(stands(bash, "PostToolUse", tool: "Read", id: "toolu_2"))
        XCTAssertTrue(stands(bash, "PostToolUseFailure", tool: "Grep"))
        XCTAssertTrue(stands(bash, "PermissionDenied", tool: "Write"))
    }

    // You granted it, and it ran: the question is answered.
    func testTheAskingToolFinishingEndsTheQuestion() {
        XCTAssertFalse(stands(bash, "PostToolUse", tool: "Bash", id: "toolu_1"))
        XCTAssertFalse(stands(bash, "PostToolUseFailure", tool: "Bash"))
        XCTAssertFalse(stands(bash, "PermissionDenied", tool: "Bash"))
    }

    // Two Bash calls at once: the call id decides when both events carry one.
    func testTheCallIDDecidesBetweenTwoCallsOfOneTool() {
        let asked = AttentionState.Question(tool: "Bash", toolUseID: "toolu_1")
        XCTAssertTrue(stands(asked, "PostToolUse", tool: "Bash", id: "toolu_2"))
        XCTAssertFalse(stands(asked, "PostToolUse", tool: "Bash", id: "toolu_1"))
    }

    // Nothing named the tool (an elicitation, an agent asking for input): nothing can be
    // matched, so the main agent's tool events end it as before; a subagent's do not.
    func testAnUnnamedQuestionEndsOnTheMainAgentsToolEvents() {
        let unknown = AttentionState.Question(tool: nil, toolUseID: nil)
        XCTAssertFalse(stands(unknown, "PostToolUse", tool: "Bash"))
        XCTAssertFalse(stands(unknown, "PreToolUse", tool: "Bash"))
        XCTAssertTrue(stands(unknown, "PostToolUse", subagent: true, tool: "Read"))
        XCTAssertTrue(stands(unknown, "PreToolUse", subagent: true, tool: "Read"))
        XCTAssertFalse(stands(unknown, "Stop"))
    }

    func testASubagentStartingAToolLeavesTheQuestion() {
        XCTAssertTrue(stands(bash, "PreToolUse", subagent: true, tool: "Read"))
        XCTAssertFalse(stands(bash, "PreToolUse", tool: "Read"), "the main agent's own next step ends it")
    }

    func testYourPromptAndTheEndOfTheTurnEndTheQuestion() {
        XCTAssertFalse(stands(bash, "UserPromptSubmit"))
        XCTAssertFalse(stands(bash, "Stop"))
        XCTAssertFalse(stands(bash, "StopFailure"))
        XCTAssertFalse(stands(bash, "SessionEnd"))
    }

    // MARK: The installed hooks

    func testTheNewEventsAreInstalledWithAToolMatcherWhereTheyTakeOne() {
        for event in ["StopFailure", "PostToolUseFailure", "PermissionDenied"] {
            XCTAssertTrue(HookInstaller.events.contains(event), event)
        }
        XCTAssertTrue(HookInstaller.toolEvents.isSuperset(of: ["PostToolUseFailure", "PermissionDenied"]))
        // StopFailure matches on the error type, with a narrower syntax than `*`: no matcher.
        XCTAssertFalse(HookInstaller.toolEvents.contains("StopFailure"))
    }

    // MARK: /rename

    func testARenameWinsOverClaudesTitle() {
        let text = """
            {"type":"ai-title","aiTitle":"Claude's own name","sessionId":"s"}
            {"type":"custom-title","customTitle":"  My name  ","sessionId":"s"}
            {"type":"ai-title","aiTitle":"A newer Claude name","sessionId":"s"}
            """
        XCTAssertEqual(AgentTitle.latestCustom(inJSONL: text[...]), "My name")
        XCTAssertEqual(AgentTitle.latest(inJSONL: text[...]), "A newer Claude name")
        let scan = TranscriptScan(title: "A newer Claude name", customTitle: "My name")
        XCTAssertEqual(scan.displayTitle, "My name")
        XCTAssertEqual(TranscriptScan(title: "Claude").displayTitle, "Claude")
    }

    // The rename is written once; the 512 KB window loses it as the session goes on.
    func testARenameOutsideTheWindowIsKept() {
        let earlier = TranscriptScan(title: "old", customTitle: "My name")
        let now = TranscriptScan(title: "new", customTitle: nil)
        XCTAssertEqual(now.keepingRename(of: earlier).displayTitle, "My name")
        let renamedAgain = TranscriptScan(title: "new", customTitle: "Second name")
        XCTAssertEqual(renamedAgain.keepingRename(of: earlier).displayTitle, "Second name")
        XCTAssertEqual(now.keepingRename(of: nil).displayTitle, "new")
        // After a restart the kept title comes from the terminal (`renamedTitle`).
        XCTAssertEqual(now.keepingRename(of: TranscriptScan(customTitle: "Kept")).displayTitle, "Kept")
    }
}

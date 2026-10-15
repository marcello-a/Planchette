import XCTest
@testable import Planchette

final class TabNamingTests: XCTestCase {
    private func inputs(
        custom: String? = nil, conversation: String? = nil, ai: String? = nil,
        first: String? = nil, last: String? = nil, reported: String? = nil,
        ticket: String? = nil, fallback: String = "free"
    ) -> TabNaming.Inputs {
        TabNaming.Inputs(
            customTitle: custom, conversationTitle: conversation, aiSummary: ai,
            firstPrompt: first, lastPrompt: last, reportedTitle: reported,
            ticket: ticket, fallback: fallback)
    }

    // MARK: The summary, the default

    func testTheSummaryIsTheNameClaudeGaveTheConversation() {
        let name = TabNaming.name(
            inputs(conversation: "NIE-2008 gallery wall menu", ai: "adds a menu", last: "ja, mach", ticket: "NIE-2008"),
            source: .summary)
        XCTAssertEqual(name, "NIE-2008 gallery wall menu")
    }

    func testTheSummaryFallsBackToTheAISummaryThenToTheLastPrompt() {
        XCTAssertEqual(TabNaming.name(inputs(ai: "adds a menu", last: "ja, mach"), source: .summary), "adds a menu")
        XCTAssertEqual(TabNaming.name(inputs(last: "ja, mach"), source: .summary), "ja, mach")
    }

    // A fresh terminal has no conversation yet: the title the program reports, then the plain fallback.
    func testTheSummaryFallsBackToTheReportedTitleAndLastToTheFallback() {
        XCTAssertEqual(TabNaming.name(inputs(reported: "npm run dev"), source: .summary), "npm run dev")
        XCTAssertEqual(TabNaming.name(inputs(), source: .summary), "free")
        XCTAssertEqual(TabNaming.name(inputs(fallback: "planchette"), source: .summary), "planchette")
    }

    // A source that holds only white space says nothing: it must not name a tab "".
    func testASourceWithNothingInItIsSkipped() {
        XCTAssertEqual(TabNaming.name(inputs(conversation: "  \n", last: "Fix the build"), source: .summary), "Fix the build")
    }

    // The branch is not a source of the name any more: the ticket is asked for by one choice only.
    func testTheTicketNeverEntersAnyNameButTheClassicOne() {
        for source in [TabName.summary, .lastPrompt, .firstPrompt] {
            let name = TabNaming.name(inputs(conversation: "Gallery menu", first: "Add a menu", last: "Fix it", ticket: "NIE-2008"), source: source)
            XCTAssertFalse(name.contains("NIE-2008"), "\(source) named a tab after the branch")
        }
    }

    // MARK: The prompts

    func testLastPromptIgnoresTheSummary() {
        let name = TabNaming.name(inputs(conversation: "Gallery menu", last: "Fix the spacing"), source: .lastPrompt)
        XCTAssertEqual(name, "Fix the spacing")
    }

    func testFirstPromptFallsBackToTheLastOne() {
        XCTAssertEqual(TabNaming.name(inputs(first: "Add a menu", last: "Fix it"), source: .firstPrompt), "Add a menu")
        XCTAssertEqual(TabNaming.name(inputs(last: "Fix it"), source: .firstPrompt), "Fix it")
    }

    // MARK: The classic name

    func testTicketAndPromptIsWhatTabsAlwaysSaid() {
        XCTAssertEqual(TabNaming.name(inputs(last: "Add the switch", ticket: "NIE-1902"), source: .ticketAndPrompt),
                       "NIE-1902 · Add the switch")
        XCTAssertEqual(TabNaming.name(inputs(ticket: "NIE-1902"), source: .ticketAndPrompt), "NIE-1902")
        XCTAssertEqual(TabNaming.name(inputs(last: "Add the switch"), source: .ticketAndPrompt), "Add the switch")
        XCTAssertEqual(TabNaming.name(inputs(), source: .ticketAndPrompt), "free")
    }

    // MARK: Every source

    func testAManualNameWinsOverEverythingAndIsNeverCut() {
        let long = String(repeating: "a long manual name ", count: 6)
        for source in TabName.allCases {
            XCTAssertEqual(TabNaming.name(inputs(custom: long, conversation: "x", last: "y", ticket: "NIE-1"), source: source), long)
        }
    }

    func testALongNameIsCutAtAWordBoundary() {
        let title = "Rework the checkout flow so that the express button covers every payment method"
        let name = TabNaming.name(inputs(conversation: title), source: .summary, max: 40)
        XCTAssertTrue(name.hasSuffix("…"))
        XCTAssertLessThanOrEqual(name.count, 41)
        XCTAssertTrue(title.hasPrefix(String(name.dropLast())), "cut in the middle of a word: \(name)")
    }
}

final class TabLayoutTests: XCTestCase {
    private func decode(_ json: String) throws -> TabLayout {
        try JSONDecoder().decode(TabLayout.self, from: Data(json.utf8))
    }

    func testTheDefaultIsTheSummaryWithFolderAndTagsAndNoBranch() {
        let layout = TabLayout()
        XCTAssertEqual(layout.name, .summary)
        XCTAssertTrue(layout.showsPath)
        XCTAssertFalse(layout.showsBranch)
        XCTAssertTrue(layout.showsTags)
    }

    func testAnEmptyBlockDecodesToTheDefaults() throws {
        XCTAssertEqual(try decode("{}"), TabLayout())
    }

    func testAWorkspaceFromBeforeTabsExistedGetsTheDefaults() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[]}"#
        let saved = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(saved.tabLayout, TabLayout())
    }

    // A value no version can read costs that one choice, never the workspace.
    func testAnUnreadableChoiceCostsOnlyThatChoice() throws {
        let layout = try decode(#"{"name":"from the future","showsPath":false,"showsBranch":"yes","showsTags":false}"#)
        XCTAssertEqual(layout.name, .summary)
        XCTAssertFalse(layout.showsPath)
        XCTAssertFalse(layout.showsBranch)
        XCTAssertFalse(layout.showsTags)
    }

    func testAnUnreadableBlockCostsOnlyTheLayout() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[],"tabLayout":42}"#
        XCTAssertEqual(try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8)).tabLayout, TabLayout())
    }

    func testAChoiceSurvivesASaveAndALoad() throws {
        var layout = TabLayout()
        layout.name = .ticketAndPrompt
        layout.showsBranch = true
        layout.showsPath = false
        let saved = PersistedState(
            groups: [], sessions: [], windows: [], aiEnabled: false, language: .en,
            appearance: .system, autoUpdateCheck: true, durableTerminals: true, tabLayout: layout)
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.tabLayout, layout)
    }

    // The sweep that finds the conversation's name costs a read: only the summary needs it.
    func testOnlyTheSummaryReadsTranscripts() {
        for name in TabName.allCases {
            var layout = TabLayout()
            layout.name = name
            XCTAssertEqual(layout.readsTranscripts, name == .summary)
        }
    }
}

final class WheelScrollTests: XCTestCase {
    func testAVerticalWheelTurnsTheListSideways() {
        // Scrolling down (the content moves up: a negative delta) goes right.
        XCTAssertEqual(WheelScroll.offset(current: 0, overflow: 500, deltaX: 0, deltaY: -3, precise: false), 36)
        XCTAssertEqual(WheelScroll.offset(current: 100, overflow: 500, deltaX: 0, deltaY: 3, precise: false), 64)
    }

    func testATrackpadMovesByPoints() {
        XCTAssertEqual(WheelScroll.offset(current: 10, overflow: 500, deltaX: 0, deltaY: -7, precise: true), 17)
    }

    func testTheOffsetStopsAtBothEnds() {
        XCTAssertEqual(WheelScroll.offset(current: 490, overflow: 500, deltaX: 0, deltaY: -30, precise: true), 500)
        XCTAssertEqual(WheelScroll.offset(current: 5, overflow: 500, deltaX: 0, deltaY: 30, precise: true), 0)
    }

    // A sideways swipe is the scroll view's own business.
    func testASidewaysSwipeIsLeftAlone() {
        XCTAssertNil(WheelScroll.offset(current: 0, overflow: 500, deltaX: 12, deltaY: 2, precise: true))
    }

    // Nothing to scroll: the event belongs to whoever is behind the list.
    func testAListThatFitsIsLeftAlone() {
        XCTAssertNil(WheelScroll.offset(current: 0, overflow: 0, deltaX: 0, deltaY: -3, precise: false))
        XCTAssertNil(WheelScroll.offset(current: 0, overflow: 0.5, deltaX: 0, deltaY: -3, precise: false))
    }
}

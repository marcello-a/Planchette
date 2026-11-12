import XCTest
@testable import Planchette

final class TodoBoardTests: XCTestCase {
    private func board(_ texts: String...) -> TodoBoard {
        var board = TodoBoard()
        for text in texts { board.add(text) }
        return board
    }

    private func texts(_ board: TodoBoard, _ lane: TodoLane) -> [String] {
        board.items(in: lane).map(\.text)
    }

    private func id(_ board: TodoBoard, _ text: String) -> UUID {
        board.items.first { $0.text == text }!.id
    }

    // MARK: Adding

    func testANewCardJoinsTheEndOfTheQueueOnOneLine() {
        var b = board("a")
        let card = b.add("  two\nlines ")
        XCTAssertEqual(card?.text, "two lines")
        XCTAssertEqual(card?.lane, .queued)
        XCTAssertEqual(texts(b, .queued), ["a", "two lines"])
    }

    func testNothingLeftMeansNoCard() {
        var b = TodoBoard()
        XCTAssertNil(b.add("  \n "))
        XCTAssertTrue(b.items.isEmpty)
    }

    // MARK: Moving

    func testAMoveToAnotherLaneLandsAtItsEnd() {
        var b = board("a", "b", "c")
        b.move(id(b, "a"), to: .running)
        b.move(id(b, "c"), to: .running)
        XCTAssertEqual(texts(b, .running), ["a", "c"])
        XCTAssertEqual(texts(b, .queued), ["b"])
    }

    func testAMoveBeforeACardLandsInFrontOfIt() {
        var b = board("a", "b", "c")
        b.move(id(b, "a"), to: .running)
        b.move(id(b, "b"), to: .running)
        b.move(id(b, "c"), to: .running, before: id(b, "a"))
        XCTAssertEqual(texts(b, .running), ["c", "a", "b"])
    }

    func testReorderingWithinALaneKeepsTheLane() {
        var b = board("a", "b", "c")
        b.move(id(b, "c"), to: .queued, before: id(b, "a"))
        XCTAssertEqual(texts(b, .queued), ["c", "a", "b"])
        b.move(id(b, "c"), to: .queued)
        XCTAssertEqual(texts(b, .queued), ["a", "b", "c"], "no before: the end of the lane")
    }

    func testABeforeFromAnotherLaneMeansTheEnd() {
        var b = board("a", "b", "c")
        b.move(id(b, "a"), to: .running)
        b.move(id(b, "b"), to: .waiting, before: id(b, "a"))
        XCTAssertEqual(texts(b, .waiting), ["b"])
        XCTAssertEqual(texts(b, .running), ["a"])
    }

    func testDroppedOnItselfNothingMoves() {
        var b = board("a", "b")
        let before = b
        b.move(id(b, "a"), to: .running, before: id(b, "a"))
        XCTAssertEqual(b, before)
    }

    func testDoneIsStampedOnEntryAndClearedOnLeaving() {
        var b = board("a")
        let now = Date(timeIntervalSince1970: 1000)
        b.move(id(b, "a"), to: .done, now: now)
        XCTAssertEqual(b.items[0].doneAt, now)
        b.move(id(b, "a"), to: .done, before: nil, now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(b.items[0].doneAt, now, "a reorder within done is no new entry")
        b.move(id(b, "a"), to: .queued)
        XCTAssertNil(b.items[0].doneAt)
    }

    func testClearingDoneKeepsTheRest() {
        var b = board("a", "b")
        b.move(id(b, "a"), to: .done)
        b.clearDone()
        XCTAssertEqual(b.items.map(\.text), ["b"])
    }

    func testTheButtonsNeverOfferTheQueue() {
        for lane in TodoLane.allCases {
            XCTAssertFalse(lane.forward.contains(.queued), "\(lane)")
            XCTAssertFalse(lane.forward.contains(lane), "\(lane)")
        }
        XCTAssertEqual(TodoLane.done.forward, [])
    }

    // MARK: Links to the workspace

    func testAGoneTerminalLeavesTheProjectAndAGoneProjectLeavesNothing() {
        let project = UUID(), other = UUID(), terminal = UUID()
        var b = board("a", "b")
        b.update(id(b, "a")) { $0.groupID = project; $0.sessionID = terminal }
        b.update(id(b, "b")) { $0.groupID = other; $0.sessionID = UUID() }
        b.forget(groupsExcept: [project], sessionsExcept: [])
        XCTAssertEqual(b.items[0].groupID, project)
        XCTAssertNil(b.items[0].sessionID)
        XCTAssertNil(b.items[1].groupID)
        XCTAssertNil(b.items[1].sessionID)
    }

    // MARK: Persistence

    func testTheBoardSurvivesARoundTrip() throws {
        var b = board("a", "b")
        b.move(id(b, "b"), to: .waiting)
        b.update(id(b, "a")) { $0.note = "n"; $0.link = "https://x.y"; $0.groupID = UUID() }
        let decoded = try JSONDecoder().decode(TodoBoard.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(decoded, b)
    }

    func testACardThatDoesNotDecodeIsLostAlone() throws {
        let json = """
        {"items": [
          {"id": "\(UUID().uuidString)", "text": "kept", "lane": "someNewLane"},
          {"text": "no id"},
          {"id": "\(UUID().uuidString)", "text": "too"}
        ]}
        """
        let b = try JSONDecoder().decode(TodoBoard.self, from: Data(json.utf8))
        XCTAssertEqual(b.items.map(\.text), ["kept", "too"])
        XCTAssertEqual(b.items[0].lane, .queued, "an unknown lane falls back to the queue")
    }

    func testAStateWithoutABoardDecodesAnEmptyOne() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.todos.items.isEmpty)
    }

    func testAWindowFromBeforeTheBoardDoesNotShowIt() throws {
        let json = #"{"id": "\#(UUID().uuidString)"}"#
        let window = try JSONDecoder().decode(WindowModel.self, from: Data(json.utf8))
        XCTAssertFalse(window.showsTodos)
    }

    func testPickingAProjectLeavesTheBoard() {
        var window = WindowModel()
        window.showsTodos = true
        window.selectGroup(UUID())
        XCTAssertFalse(window.showsTodos)
        window.showsTodos = true
        window.showProjectOverview(UUID())
        XCTAssertFalse(window.showsTodos)
    }

    // MARK: Drag and links

    func testADragCarriesTheCardAndNothingElseReadsAsOne() {
        let id = UUID()
        XCTAssertEqual(TodoDrag.decoded(TodoDrag.encoded(id)), id)
        XCTAssertNil(TodoDrag.decoded(TabDragItem.tab(id).encoded), "a tab is no card")
        XCTAssertNil(TodoDrag.decoded(Data("plain text".utf8)))
    }

    func testOnlyHttpLinksAreTakenAndABareHostGetsHttps() {
        XCTAssertEqual(TodoLink.normalized(" example.com/x "), "https://example.com/x")
        XCTAssertEqual(TodoLink.normalized("http://a.b"), "http://a.b")
        XCTAssertNil(TodoLink.normalized("file:///etc/passwd"))
        XCTAssertNil(TodoLink.normalized("javascript:alert(1)"))
        XCTAssertNil(TodoLink.normalized("two words"))
        XCTAssertNil(TodoLink.normalized("localhost"))
    }

    func testTheChipNamesTheServiceOrTheTicket() {
        XCTAssertEqual(TodoLink.label("https://acme.atlassian.net/browse/SHOP-123"), "SHOP-123")
        XCTAssertEqual(TodoLink.label("https://acme.atlassian.net/jira/software/projects"), "Jira")
        XCTAssertEqual(TodoLink.label("https://acme.atlassian.net/wiki/spaces/X/pages/1"), "Confluence")
        XCTAssertEqual(TodoLink.label("https://acme.slack.com/archives/C1/p2"), "Slack")
        XCTAssertEqual(TodoLink.label("https://github.com/o/repo/pull/12"), "repo#12")
        XCTAssertEqual(TodoLink.label("https://www.example.com/a"), "example.com")
    }
}

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

    func testTheBoardIsOffByDefaultAndItsSwitchIsSaved() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertFalse(old.todosEnabled)
        var state = old
        state.todosEnabled = true
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(back.todosEnabled)
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

    // MARK: Auto-done

    private func pr(_ n: Int, _ status: PullRequest.Status) -> PullRequest {
        PullRequest(number: n, status: status, review: nil,
                    url: URL(string: "https://github.com/o/r/pull/\(n)")!, title: "PR \(n)")
    }

    func testAutoDoneIsOffByDefaultAndSaved() throws {
        let old = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertEqual(old.todoAutoDone, .never)
        var state = old
        state.todoAutoDone = .prMerged
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.todoAutoDone, .prMerged)
    }

    func testACardOfAMergedTerminalPRMovesToDone() {
        let terminal = UUID()
        var board = TodoBoard()
        let card = board.add("Ship it")!
        board.update(card.id) { $0.sessionID = terminal }
        board.finishMerged(prs: [terminal: pr(7, .open)])
        XCTAssertEqual(board.items[0].lane, .queued, "an open PR moves nothing")
        board.finishMerged(prs: [terminal: pr(7, .merged)])
        XCTAssertEqual(board.items[0].lane, .done)
        XCTAssertNotNil(board.items[0].doneAt)
        XCTAssertEqual(board.items[0].autoDoneFor, "https://github.com/o/r/pull/7")
    }

    // The link may be any spelling of the PR's page: a tab, a slash, a query.
    func testACardLinkingAMergedPRMovesToDone() {
        var board = TodoBoard()
        let card = board.add("Review")!
        board.update(card.id) { $0.link = "https://GitHub.com/o/r/pull/9/files?w=1" }
        board.finishMerged(prs: [UUID(): pr(9, .merged)])
        XCTAssertEqual(board.items[0].lane, .done)
    }

    // Once per PR: a card you take back out of Done stays out.
    func testACardTakenBackStaysBack() {
        let terminal = UUID()
        var board = TodoBoard()
        let card = board.add("Ship it")!
        board.update(card.id) { $0.sessionID = terminal }
        board.finishMerged(prs: [terminal: pr(7, .open)])
        board.finishMerged(prs: [terminal: pr(7, .merged)])
        board.move(card.id, to: .running)
        board.finishMerged(prs: [terminal: pr(7, .merged)])
        XCTAssertEqual(board.items[0].lane, .running)
        // A new PR on the same terminal, seen open, counts again.
        board.finishMerged(prs: [terminal: pr(8, .open)])
        board.finishMerged(prs: [terminal: pr(8, .merged)])
        XCTAssertEqual(board.items[0].lane, .done)
    }

    // Review finding: the terminal switched to an old branch whose PR was merged long ago.
    func testAPRMergedBeforeTheCardWatchedItMovesNothing() {
        let terminal = UUID()
        var board = TodoBoard()
        let card = board.add("New work")!
        board.update(card.id) { $0.sessionID = terminal }
        board.finishMerged(prs: [terminal: pr(3, .merged)])
        XCTAssertEqual(board.items[0].lane, .queued, "never seen open while the card pointed here")
        XCTAssertNil(board.items[0].watchedPR)
    }

    // Review finding: a follow-up card written after the merge stays open.
    func testAFollowUpCardAfterTheMergeStaysOpen() {
        let terminal = UUID()
        var board = TodoBoard()
        let first = board.add("Ship it")!
        board.update(first.id) { $0.sessionID = terminal }
        board.finishMerged(prs: [terminal: pr(7, .open)])
        board.finishMerged(prs: [terminal: pr(7, .merged)])
        let followUp = board.add("Follow-up")!
        board.update(followUp.id) { $0.sessionID = terminal }
        board.finishMerged(prs: [terminal: pr(7, .merged)])
        XCTAssertEqual(board.items.first { $0.id == followUp.id }?.lane, .queued)
    }

    // A card that links a PR follows that PR, not its terminal's.
    func testTheLinkedPRWinsOverTheTerminals() {
        let terminal = UUID()
        var board = TodoBoard()
        let card = board.add("Review #9")!
        board.update(card.id) {
            $0.sessionID = terminal
            $0.link = "https://github.com/o/r/pull/9"
        }
        board.finishMerged(prs: [terminal: pr(7, .open)])
        board.finishMerged(prs: [terminal: pr(7, .merged)])
        XCTAssertEqual(board.items[0].lane, .queued, "PR 7 is not the card's PR")
        board.finishMerged(prs: [terminal: pr(7, .merged), UUID(): pr(9, .merged)])
        XCTAssertEqual(board.items[0].lane, .done)
    }

    func testAClosedPRMovesNothing() {
        let terminal = UUID()
        var board = TodoBoard()
        let card = board.add("Ship it")!
        board.update(card.id) { $0.sessionID = terminal }
        board.finishMerged(prs: [terminal: pr(7, .closed)])
        XCTAssertEqual(board.items[0].lane, .queued)
    }

    func testTheCardsOfAClosedTerminalMoveToDone() {
        let closed = UUID(), other = UUID()
        var board = TodoBoard()
        let a = board.add("A")!, b = board.add("B")!, c = board.add("C")!
        board.update(a.id) { $0.sessionID = closed }
        board.update(b.id) { $0.sessionID = other }
        board.update(c.id) { $0.sessionID = closed }
        board.move(c.id, to: .waiting)
        board.finishCards(ofClosedTerminal: closed)
        XCTAssertEqual(board.items.first { $0.id == a.id }?.lane, .done)
        XCTAssertEqual(board.items.first { $0.id == b.id }?.lane, .queued)
        XCTAssertEqual(board.items.first { $0.id == c.id }?.lane, .done)
    }

    func testACardFromBeforeAutoDoneDecodes() throws {
        let json = #"{"id": "\#(UUID().uuidString)", "text": "x"}"#
        let item = try JSONDecoder().decode(TodoItem.self, from: Data(json.utf8))
        XCTAssertNil(item.autoDoneFor)
    }
}

import XCTest
@testable import Planchette

final class MainTerminalTests: XCTestCase {
    private func terminal(main: Bool = false, state: AttentionState = .free, seen: Bool = true) -> TerminalSession {
        var session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        session.isMain = main
        session.state = state
        session.seen = seen
        return session
    }

    func testAMainTerminalAlwaysStandsUnderAFoldedProject() {
        let main = terminal(main: true)
        let plain = terminal()
        let shown = CollapsedProject.visible([plain, main], peekAttention: false, isMuted: { _ in true },
                                            dismissed: [main.id: main.stateSince])
        XCTAssertEqual(shown.map(\.id), [main.id], "the peek off, muted, collapsed-all: it stays")
    }

    func testAnUnreadQuestionPeeksOnlyWhileThePeekIsOn() {
        let asking = terminal(state: .waiting, seen: false)
        XCTAssertEqual(CollapsedProject.visible([asking], peekAttention: true, isMuted: { _ in false }, dismissed: [:]).count, 1)
        XCTAssertTrue(CollapsedProject.visible([asking], peekAttention: false, isMuted: { _ in false }, dismissed: [:]).isEmpty)
        XCTAssertTrue(CollapsedProject.visible([asking], peekAttention: true, isMuted: { _ in false },
                                               dismissed: [asking.id: asking.stateSince]).isEmpty,
                      "folded with 'collapse all': it stays away until it asks again")
    }

    func testTheOrderIsTheProjectsOwn() {
        let a = terminal(main: true), b = terminal(state: .error, seen: false), c = terminal(main: true)
        XCTAssertEqual(CollapsedProject.visible([a, b, c], peekAttention: true, isMuted: { _ in false }, dismissed: [:]).map(\.id),
                       [a.id, b.id, c.id])
    }

    func testTheMarkIsStoredAndOldStatesReadAsNotMain() throws {
        let marked = terminal(main: true)
        XCTAssertTrue(try JSONDecoder().decode(TerminalSession.self, from: JSONEncoder().encode(marked)).isMain)
        let json = #"{"id":"\#(UUID())","groupID":"\#(UUID())","workingDirectory":"/tmp"}"#
        XCTAssertFalse(try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8)).isMain)
    }
}

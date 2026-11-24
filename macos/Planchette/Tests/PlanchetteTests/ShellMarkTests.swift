import XCTest
@testable import Planchette

/// A tab of a plain shell shows `>_`, not the free dot: the dot says "Claude is idle here".
final class ShellMarkTests: XCTestCase {
    func testAFreeTerminalWithoutAnAgentIsAShell() {
        XCTAssertTrue(AttentionState.showsShellMark(state: .free, agentLive: false))
    }

    func testAnIdleAgentKeepsTheFreeDot() {
        XCTAssertFalse(AttentionState.showsShellMark(state: .free, agentLive: true))
    }

    // A finished command, an error, a question: each has its own sprite, agent or not.
    func testEveryOtherStateKeepsItsOwnSprite() {
        for state in [AttentionState.running, .waiting, .ready, .error] {
            XCTAssertFalse(AttentionState.showsShellMark(state: state, agentLive: false), "\(state)")
        }
    }

    func testTheShellSpriteIsEightByEightAndShowsAPromptAndACursor() {
        let sprite = StatePixels.shell
        XCTAssertEqual(sprite.count, StatePixels.size)
        XCTAssertTrue(sprite.allSatisfy { $0.count == StatePixels.size })
        // `>`: a point in the middle column of its rows; `_`: a bar on the row below.
        XCTAssertEqual(sprite[3], "...#....")
        XCTAssertEqual(sprite[6].filter { $0 == "#" }.count, 4)
    }
}

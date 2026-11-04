import XCTest
@testable import Planchette

final class KeyboardNavigationTests: XCTestCase {
    func testDigitPicksTabAndNineIsLast() {
        XCTAssertEqual(KeyboardNavigation.tabIndex(forDigit: 1, count: 3), 0)
        XCTAssertEqual(KeyboardNavigation.tabIndex(forDigit: 3, count: 3), 2)
        XCTAssertNil(KeyboardNavigation.tabIndex(forDigit: 4, count: 3))
        XCTAssertEqual(KeyboardNavigation.tabIndex(forDigit: 9, count: 3), 2)
        XCTAssertEqual(KeyboardNavigation.tabIndex(forDigit: 9, count: 12), 11)
        XCTAssertNil(KeyboardNavigation.tabIndex(forDigit: 1, count: 0))
    }

    func testStepWrapsBothWays() {
        XCTAssertEqual(KeyboardNavigation.step(from: 0, by: 1, count: 3), 1)
        XCTAssertEqual(KeyboardNavigation.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(KeyboardNavigation.step(from: 1, by: -1, count: 3), 0)
        XCTAssertEqual(KeyboardNavigation.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(KeyboardNavigation.step(from: nil, by: 1, count: 3), 0)
        XCTAssertEqual(KeyboardNavigation.step(from: nil, by: -1, count: 3), 2)
        XCTAssertNil(KeyboardNavigation.step(from: nil, by: 1, count: 0))
    }
}

final class ReopenTerminalTests: XCTestCase {
    func testReopenedKeepsPlaceAndSettingsButNotIdentityOrState() {
        var closed = TerminalSession(groupID: UUID(), workingDirectory: "/repo")
        closed.currentDirectory = "/repo/sub"
        closed.customTitle = "api"
        closed.tags = ["x"]
        closed.startupCommand = "npm run dev"
        closed.state = .running
        closed.claudeSessionID = "abc"
        let fresh = TerminalSession(groupID: UUID(), workingDirectory: "/elsewhere")
        let reopened = closed.reopened(into: fresh)
        XCTAssertEqual(reopened.id, fresh.id)
        XCTAssertEqual(reopened.groupID, fresh.groupID)
        XCTAssertEqual(reopened.workingDirectory, "/repo")
        XCTAssertEqual(reopened.currentDirectory, "/repo/sub")
        XCTAssertEqual(reopened.customTitle, "api")
        XCTAssertEqual(reopened.tags, ["x"])
        XCTAssertEqual(reopened.startupCommand, "npm run dev")
        XCTAssertEqual(reopened.state, .free)
        XCTAssertNil(reopened.claudeSessionID)
    }
}

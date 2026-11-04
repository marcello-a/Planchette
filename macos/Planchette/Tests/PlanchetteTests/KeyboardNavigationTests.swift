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

    func testNextWraps() {
        XCTAssertEqual(KeyboardNavigation.next(after: 0, count: 3), 1)
        XCTAssertEqual(KeyboardNavigation.next(after: 2, count: 3), 0)
        XCTAssertEqual(KeyboardNavigation.next(after: nil, count: 3), 0)
        XCTAssertNil(KeyboardNavigation.next(after: nil, count: 0))
    }
}

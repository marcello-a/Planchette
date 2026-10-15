import XCTest
@testable import Planchette

/// "Only active" in the notifications panel: what is going on, and the results that are still fresh.
final class OnlyActiveFilterTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_000_000)

    private func current(_ state: AttentionState, after seconds: TimeInterval, _ expiry: DoneExpiry = .oneDay) -> Bool {
        state.isCurrent(since: since, expiry: expiry, now: since.addingTimeInterval(seconds))
    }

    func testRunningWaitingAndFailedAreAlwaysCurrent() {
        for state in [AttentionState.running, .waiting, .error] {
            XCTAssertTrue(current(state, after: 0), "\(state)")
            XCTAssertTrue(current(state, after: 90 * 86_400), "\(state) a quarter ago is still going on")
        }
    }

    // The case the filter used to get wrong: a turn finished minutes ago is not idle yet.
    func testAFinishedTurnIsCurrentWhileItsDoneCheckIsFresh() {
        XCTAssertTrue(current(.ready, after: 0))
        XCTAssertTrue(current(.ready, after: 5 * 60))
        XCTAssertTrue(current(.ready, after: 86_399), "one second before the check clears")
    }

    func testAFinishedTurnIsStaleOnceItsDoneCheckHasExpired() {
        XCTAssertFalse(current(.ready, after: 86_400), "the check clears at the boundary, as DoneExpiry says")
        XCTAssertFalse(current(.ready, after: 3 * 86_400))
    }

    // The window is the user's choice (Settings → Project panel), not a constant of the filter.
    func testStaleMeansWhateverTheDoneCheckIsSetTo() {
        XCTAssertFalse(current(.ready, after: 3600, .oneHour))
        XCTAssertTrue(current(.ready, after: 3599, .oneHour))
        XCTAssertTrue(current(.ready, after: 3600, .oneDay))
        XCTAssertTrue(current(.ready, after: 30 * 86_400, .never), "a check that never clears is never stale")
    }

    // A terminal that is free again is the idle one: it is what the filter exists to hide.
    func testAFreeTerminalIsNeverCurrent() {
        XCTAssertFalse(current(.free, after: 0))
        XCTAssertFalse(current(.free, after: 60))
        XCTAssertFalse(current(.free, after: 60, .never))
    }
}

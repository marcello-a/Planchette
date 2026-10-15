import XCTest
@testable import Planchette

/// "Only active" in the notifications panel: what wants you, and the results that are still fresh.
final class OnlyActiveFilterTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_000_000)

    private func current(_ state: AttentionState, after seconds: TimeInterval, _ expiry: DoneExpiry = .oneDay,
                         includeRunning: Bool = false) -> Bool {
        state.isCurrent(since: since, expiry: expiry, now: since.addingTimeInterval(seconds),
                        includeRunning: includeRunning)
    }

    func testWaitingAndFailedAreAlwaysCurrent() {
        for state in [AttentionState.waiting, .error] {
            XCTAssertTrue(current(state, after: 0), "\(state)")
            XCTAssertTrue(current(state, after: 90 * 86_400), "\(state) a quarter ago still wants you")
        }
    }

    // A terminal that works does not need you: the list of what does leaves it out, until it is asked.
    func testARunningTerminalIsLeftOutUnlessAsked() {
        XCTAssertFalse(current(.running, after: 0))
        XCTAssertFalse(current(.running, after: 90 * 86_400))
        XCTAssertTrue(current(.running, after: 0, includeRunning: true))
        XCTAssertTrue(current(.running, after: 90 * 86_400, includeRunning: true))
    }

    // Asking for the running ones changes nothing about the others.
    func testIncludingRunningTouchesOnlyRunning() {
        for state in [AttentionState.waiting, .error, .free] {
            XCTAssertEqual(current(state, after: 60), current(state, after: 60, includeRunning: true), "\(state)")
        }
        XCTAssertEqual(current(.ready, after: 86_400), current(.ready, after: 86_400, includeRunning: true))
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

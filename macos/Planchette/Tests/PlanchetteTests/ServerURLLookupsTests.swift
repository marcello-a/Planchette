import XCTest
@testable import Planchette

final class ServerURLLookupsTests: XCTestCase {
    private let vite = URL(string: "https://vite.myposter.de:8082")!

    func testANewPortIsDue() {
        XCTAssertTrue(ServerURLLookups().isDue(8082))
    }

    func testAPortThatNeverAnnouncesAURLStopsAfterMaxTries() {
        var lookups = ServerURLLookups()
        for attempt in 1...ServerURLLookups.maxTries {
            XCTAssertTrue(lookups.isDue(3306), "try \(attempt) is still allowed")
            lookups.recordTry(3306)
        }
        XCTAssertFalse(lookups.isDue(3306), "no search after \(ServerURLLookups.maxTries) misses")
    }

    // Create React App and Storybook print their address only after the first build,
    // which can take a minute: a port that missed its first searches is searched again, slowly.
    func testAnUnresolvedPortIsSearchedAgainAfterTheRetryInterval() {
        var lookups = ServerURLLookups()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for attempt in 0..<ServerURLLookups.maxTries {
            lookups.recordTry(3000, now: start.addingTimeInterval(Double(attempt) * 5))
        }
        let last = start.addingTimeInterval(Double(ServerURLLookups.maxTries - 1) * 5)
        XCTAssertFalse(lookups.isDue(3000, now: last.addingTimeInterval(ServerURLLookups.retryInterval - 1)))
        XCTAssertTrue(lookups.isDue(3000, now: last.addingTimeInterval(ServerURLLookups.retryInterval)))
        lookups.recordTry(3000, now: last.addingTimeInterval(ServerURLLookups.retryInterval))
        XCTAssertFalse(lookups.isDue(3000, now: last.addingTimeInterval(ServerURLLookups.retryInterval + 5)),
                       "one search a minute, not one a tick")
    }

    // A port that never prints an address waits longer after every miss, up to a cap.
    func testTheRetryWaitDoublesUpToACap() {
        XCTAssertEqual(ServerURLLookups.retryDelay(afterTries: ServerURLLookups.maxTries), 60)
        XCTAssertEqual(ServerURLLookups.retryDelay(afterTries: ServerURLLookups.maxTries + 1), 120)
        XCTAssertEqual(ServerURLLookups.retryDelay(afterTries: ServerURLLookups.maxTries + 2), 240)
        XCTAssertEqual(ServerURLLookups.retryDelay(afterTries: 500), ServerURLLookups.maxRetryInterval)

        var lookups = ServerURLLookups()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for _ in 0...ServerURLLookups.maxTries { lookups.recordTry(3000, now: start) }
        XCTAssertFalse(lookups.isDue(3000, now: start.addingTimeInterval(119)))
        XCTAssertTrue(lookups.isDue(3000, now: start.addingTimeInterval(120)))
    }

    func testTriesAreCountedPerPort() {
        var lookups = ServerURLLookups()
        for _ in 1...ServerURLLookups.maxTries { lookups.recordTry(3306) }
        XCTAssertFalse(lookups.isDue(3306))
        XCTAssertTrue(lookups.isDue(8082))
    }

    func testALearnedURLIsKeptAndNotSearchedAgain() {
        var lookups = ServerURLLookups()
        lookups.recordTry(8082)
        lookups.learn([8082: vite], livePorts: [8082])
        XCTAssertEqual(lookups.urls[8082], vite)
        XCTAssertFalse(lookups.isDue(8082))
        XCTAssertNil(lookups.tries[8082])
    }

    func testAURLForAPortThatWentAwayMeanwhileIsDropped() {
        var lookups = ServerURLLookups()
        lookups.recordTry(8082)
        lookups.learn([8082: vite], livePorts: [])
        XCTAssertNil(lookups.urls[8082])
    }

    func testAReopenedPortStartsOver() {
        var lookups = ServerURLLookups()
        for _ in 1...ServerURLLookups.maxTries { lookups.recordTry(3306) }
        lookups.learn([8082: vite], livePorts: [8082])

        // Both ports close…
        lookups.keep(livePorts: [])
        XCTAssertEqual(lookups, ServerURLLookups())

        // …and a new process on either gets fresh tries.
        XCTAssertTrue(lookups.isDue(3306))
        XCTAssertTrue(lookups.isDue(8082))
    }

    func testKeepingLivePortsLeavesTheirStateAlone() {
        var lookups = ServerURLLookups()
        for _ in 1...ServerURLLookups.maxTries { lookups.recordTry(3306) }
        lookups.learn([8082: vite], livePorts: [8082])
        lookups.keep(livePorts: [3306, 8082])
        XCTAssertFalse(lookups.isDue(3306))
        XCTAssertEqual(lookups.urls[8082], vite)
    }
}

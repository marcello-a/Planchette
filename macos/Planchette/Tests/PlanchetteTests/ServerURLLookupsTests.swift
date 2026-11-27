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

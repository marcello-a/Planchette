import XCTest
@testable import Planchette

final class KeychainCacheTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        var fetches = 0
        var answer: KeychainCache.Fetched = .value("token")
    }

    private func cache(_ counter: Counter) -> KeychainCache {
        KeychainCache { _, _ in
            counter.fetches += 1
            return counter.answer
        }
    }

    func testSecondReadDoesNotAskTheKeychainAgain() {
        let counter = Counter()
        let keychain = cache(counter)
        XCTAssertEqual(keychain.read(service: "s", account: "a"), "token")
        XCTAssertEqual(keychain.read(service: "s", account: "a"), "token")
        XCTAssertEqual(counter.fetches, 1)
    }

    func testEachAccountIsAskedOnce() {
        let counter = Counter()
        let keychain = cache(counter)
        _ = keychain.read(service: "s", account: "a")
        _ = keychain.read(service: "s", account: "b")
        _ = keychain.read(service: "s", account: "b")
        XCTAssertEqual(counter.fetches, 2)
    }

    func testNoTokenOrDenyIsKeptToo() {
        let counter = Counter()
        counter.answer = .value(nil)
        let keychain = cache(counter)
        XCTAssertNil(keychain.read(service: "s", account: "a"))
        XCTAssertNil(keychain.read(service: "s", account: "a"))
        XCTAssertEqual(counter.fetches, 1)
    }

    func testNoAnswerAsksAgain() {
        let counter = Counter()
        counter.answer = .retry
        let keychain = cache(counter)
        XCTAssertNil(keychain.read(service: "s", account: "a"))
        counter.answer = .value("token")
        XCTAssertEqual(keychain.read(service: "s", account: "a"), "token")
        XCTAssertEqual(counter.fetches, 2)
    }

    func testAWriteReplacesWhatWasRead() {
        let counter = Counter()
        let keychain = cache(counter)
        _ = keychain.read(service: "s", account: "a")
        keychain.store("new", service: "s", account: "a")
        XCTAssertEqual(keychain.read(service: "s", account: "a"), "new")
        keychain.store(nil, service: "s", account: "a")
        XCTAssertNil(keychain.read(service: "s", account: "a"))
        XCTAssertEqual(counter.fetches, 1)
    }

    func testReadsAtTheSameTimeAskOnce() {
        let counter = Counter()
        let keychain = KeychainCache { _, _ in
            counter.fetches += 1
            Thread.sleep(forTimeInterval: 0.05)
            return .value("token")
        }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            XCTAssertEqual(keychain.read(service: "s", account: "a"), "token")
        }
        XCTAssertEqual(counter.fetches, 1)
    }
}

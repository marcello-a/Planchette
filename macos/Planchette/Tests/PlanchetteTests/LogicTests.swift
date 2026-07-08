import XCTest
@testable import Planchette

final class SemverTests: XCTestCase {
    func testNewerMajorMinorPatch() {
        XCTAssertTrue(Semver.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(Semver.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(Semver.isNewer("1.0.1", than: "1.0.0"))
    }

    func testNotNewerWhenEqualOrOlder() {
        XCTAssertFalse(Semver.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Semver.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertFalse(Semver.isNewer("1.2.0", than: "1.10.0"))
    }

    func testIgnoresLeadingVAndPrerelease() {
        XCTAssertTrue(Semver.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertFalse(Semver.isNewer("1.0.0-dev", than: "1.0.0"))
    }

    func testDifferentComponentCounts() {
        XCTAssertTrue(Semver.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(Semver.isNewer("1.0", than: "1.0.0"))
    }
}

final class TitlesTests: XCTestCase {
    func testShortPathTakesLastTwoComponents() {
        XCTAssertEqual(Titles.shortPath("/Users/x/development/sandbox/planchette"), "sandbox/planchette")
        XCTAssertEqual(Titles.shortPath("/one"), "one")
    }

    func testTicketExtractedFromGitBranch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planchette-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/marcello/feat/NIE-4213-cool-thing\n"
            .write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(Titles.ticket(forDirectory: dir.path), "NIE-4213")
    }

    func testNoTicketForPlainBranch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("planchette-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n"
            .write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(Titles.ticket(forDirectory: dir.path))
    }
}

final class UpdateSecurityTests: XCTestCase {
    func testTrustedGitHubDownloads() {
        XCTAssertTrue(UpdateService.isTrustedDownload(URL(string: "https://github.com/marcello-a/Planchette/releases/download/v1/Planchette.dmg")!))
        XCTAssertTrue(UpdateService.isTrustedDownload(URL(string: "https://objects.githubusercontent.com/x/y.dmg")!))
    }

    func testRejectsUntrustedOrInsecureDownloads() {
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "http://github.com/x.dmg")!))       // not https
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "https://evil.example.com/x.dmg")!))
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "https://github.com.evil.com/x")!)) // suffix spoof
        XCTAssertFalse(UpdateService.isTrustedDownload(URL(string: "file:///etc/passwd")!))
    }
}

final class AttentionStateTests: XCTestCase {
    func testNeedsAttention() {
        XCTAssertTrue(AttentionState.waiting.needsAttention)
        XCTAssertTrue(AttentionState.error.needsAttention)
        XCTAssertFalse(AttentionState.running.needsAttention)
        XCTAssertFalse(AttentionState.ready.needsAttention)
    }

    func testDecodesLegacyRawValues() throws {
        func decode(_ raw: String) throws -> AttentionState {
            try JSONDecoder().decode(AttentionState.self, from: Data("\"\(raw)\"".utf8))
        }
        // v0.1.x values migrate to the new color-system states.
        XCTAssertEqual(try decode("working"), .running)
        XCTAssertEqual(try decode("asking"), .waiting)
        XCTAssertEqual(try decode("done"), .ready)
        XCTAssertEqual(try decode("free"), .ready)
        // New values round-trip; unknown falls back to ready.
        XCTAssertEqual(try decode("error"), .error)
        XCTAssertEqual(try decode("bogus"), .ready)
    }
}

final class LocalizationTests: XCTestCase {
    func testEveryKeyHasEnglishBase() {
        // English is the fallback table; every key must resolve there.
        L10n.current = .en
        for key in LKey.allCases {
            XCTAssertFalse(L10n.t(key).isEmpty, "missing English string for \(key)")
        }
    }

    func testResolvedNeverReturnsSystem() {
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
    }
}

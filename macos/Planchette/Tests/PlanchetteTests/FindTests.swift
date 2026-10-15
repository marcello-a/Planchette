import XCTest
@testable import Planchette

final class DurableSearchTests: XCTestCase {
    private let id = UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000AB")!

    // A pane command asked for "=name" answers "can't find pane"; "=name:" is the session's pane.
    func testThePaneTargetNamesTheSessionExactlyAndItsWindow() {
        XCTAssertEqual(Durable.paneTarget(for: id), "=planchette-0a1b2c3d-0000-4000-8000-0000000000ab:")
    }

    func testASearchIsOneTmuxCallThatEntersCopyModeGoesToTheNewestLineAndAsksHowMany() {
        let args = Durable.searchArguments("needle", session: id)
        let target = Durable.paneTarget(for: id)
        XCTAssertEqual(Array(args.prefix(2)), ["-L", Durable.serverName])
        // Four commands in one call, split by tmux's own separator.
        XCTAssertEqual(args.filter { $0 == ";" }.count, 3)
        XCTAssertEqual(args.firstIndex(of: "copy-mode").map { args[$0 + 1] }, "-t")
        XCTAssertTrue(args.contains("history-bottom"))
        XCTAssertTrue(args.contains("search-backward-text"))
        XCTAssertEqual(args.last, "#{search_present}:#{search_count}")
        XCTAssertEqual(args.filter { $0 == target }.count, 4, "every command names the same pane")
    }

    // The needle is text, never a flag and never a command.
    func testTheNeedleComesAfterTheEndOfFlags() {
        let args = Durable.searchArguments("-dash", session: id)
        let at = args.firstIndex(of: "search-backward-text")!
        XCTAssertEqual(Array(args[at...].prefix(3)), ["search-backward-text", "--", "-dash"])
    }

    func testANeedleThatLooksLikeACommandIsOneArgument() {
        let args = Durable.searchArguments("x ; kill-server", session: id)
        XCTAssertTrue(args.contains("x ; kill-server"))
        XCTAssertEqual(args.filter { $0 == ";" }.count, 3, "no separator came from the needle")
    }

    // An argument that ends in ";" ends the command there; "\;" is the literal.
    func testATrailingSemicolonIsEscaped() {
        XCTAssertEqual(Durable.escapedNeedle("beta;"), "beta\\;")
        XCTAssertEqual(Durable.escapedNeedle("a;b"), "a;b")
        XCTAssertEqual(Durable.escapedNeedle("plain"), "plain")
        XCTAssertEqual(Durable.escapedNeedle(";"), "\\;")
    }

    func testSteppingGoesToTheOlderMatchOrBackToTheNewerOne() {
        XCTAssertEqual(Durable.stepArguments(older: true, session: id).suffix(1), ["search-again"])
        XCTAssertEqual(Durable.stepArguments(older: false, session: id).suffix(1), ["search-reverse"])
    }

    func testEndingTheSearchLeavesCopyMode() {
        XCTAssertEqual(Array(Durable.endSearchArguments(session: id).suffix(2)), [Durable.paneTarget(for: id), "cancel"])
    }

    func testTheReplyIsReadAsTheNumberOfMatches() {
        XCTAssertEqual(Durable.parseSearchReply("1:11\n"), 11)
        XCTAssertEqual(Durable.parseSearchReply("1:1"), 1)
        XCTAssertEqual(Durable.parseSearchReply("0:"), 0, "nothing found is an answer")
        XCTAssertEqual(Durable.parseSearchReply("0:0\n"), 0)
    }

    func testAReplyThatIsNotThatShapeIsNoAnswer() {
        XCTAssertNil(Durable.parseSearchReply(""))
        XCTAssertNil(Durable.parseSearchReply("1:"))
        XCTAssertNil(Durable.parseSearchReply("garbage"))
        XCTAssertNil(Durable.parseSearchReply("1:x"))
        XCTAssertNil(Durable.parseSearchReply("can't find pane: =planchette-x:"))
    }
}

final class TerminalFindTests: XCTestCase {
    private var language: AppLanguage = .system

    override func setUp() {
        language = L10n.current
        L10n.current = .en
    }

    override func tearDown() { L10n.current = language }

    func testNothingIsSaidBeforeSomethingWasSearched() {
        XCTAssertEqual(TerminalFind().countLabel(), "")
        XCTAssertEqual(TerminalFind(needle: "foo", total: nil).countLabel(), "")
        XCTAssertEqual(TerminalFind(needle: "", total: 5).countLabel(), "")
    }

    func testNoMatchSaysSoAndMarksTheBar() {
        let find = TerminalFind(needle: "zzz", total: 0)
        XCTAssertEqual(find.countLabel(), "No results")
        XCTAssertTrue(find.hasNoResults)
        XCTAssertFalse(TerminalFind(needle: "", total: 0).hasNoResults)
    }

    // libghostty says which one is selected; tmux only says how many there are.
    func testTheSelectedMatchIsNamedWhenTheEngineSaysWhich() {
        XCTAssertEqual(TerminalFind(needle: "foo", total: 12, selected: 3).countLabel(), "3 of 12")
        XCTAssertEqual(TerminalFind(needle: "foo", total: 12).countLabel(), "12 matches")
        XCTAssertEqual(TerminalFind(needle: "foo", total: 1).countLabel(), "1 match")
    }
}

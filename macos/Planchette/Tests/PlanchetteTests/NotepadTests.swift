import XCTest
@testable import Planchette

/// The notepad of a terminal: a prompt runs until the Returns that end it — two by default.
final class NotepadPromptsTests: XCTestCase {
    private func texts(_ text: String, returns: Int = 2) -> [String] {
        NotepadPrompts.prompts(in: text, returns: returns).map(\.text)
    }

    func testABlankLineEndsAPrompt() {
        XCTAssertEqual(texts("first\n\nsecond\n\nthird"), ["first", "second", "third"])
    }

    func testAPromptCanBeSeveralLines() {
        let text = "fix the failing test\nit is in cart.spec.ts\nkeep the fix small\n\nthen commit"
        XCTAssertEqual(texts(text), ["fix the failing test\nit is in cart.spec.ts\nkeep the fix small", "then commit"])
    }

    func testOneReturnIsNotEnough() {
        XCTAssertEqual(texts("a\nb"), ["a\nb"], "two Returns are the default: one stays inside a prompt")
    }

    func testMoreBlankLinesThanNeededAreOnlyAGap() {
        XCTAssertEqual(texts("a\n\n\n\n\nb"), ["a", "b"])
        XCTAssertEqual(texts("\n\n  \n\nonly\n\n\n"), ["only"])
    }

    func testALineOfSpacesIsABlankLine() {
        XCTAssertEqual(texts("a\n   \t \nb"), ["a", "b"])
    }

    func testTheSettingChangesWhatEndsAPrompt() {
        let text = "a\nb\n\nc\n\n\nd"
        XCTAssertEqual(texts(text, returns: 1), ["a", "b", "c", "d"], "every line is a prompt")
        XCTAssertEqual(texts(text, returns: 2), ["a\nb", "c", "d"])
        XCTAssertEqual(texts(text, returns: 3), ["a\nb\n\nc", "d"], "one blank line stays inside; two end it")
    }

    func testBlankLinesInsideAPromptStayInIt() {
        XCTAssertEqual(texts("a\n\nb\n\n\nc", returns: 3), ["a\n\nb", "c"])
    }

    func testNothingButSpaceIsNoPrompt() {
        XCTAssertEqual(texts(""), [])
        XCTAssertEqual(texts("\n\n   \n\t\n"), [])
        XCTAssertEqual(texts("\n", returns: 1), [])
    }

    func testSpaceAroundAPromptIsNotPartOfIt() {
        XCTAssertEqual(texts("  indented  \n\n"), ["indented"])
        XCTAssertEqual(texts("keep  inner   spaces"), ["keep  inner   spaces"])
        XCTAssertEqual(texts("  first line\n    second line  "), ["first line\n    second line"],
                       "inner indentation is typed text and stays")
    }

    func testEveryKindOfLineBreakCounts() {
        for separator in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"] {
            XCTAssertEqual(texts("one\(separator)\(separator)two"), ["one", "two"],
                           "two of \(separator.unicodeScalars.map(\.value))")
            XCTAssertEqual(texts("one\(separator)two"), ["one\ntwo"],
                           "one of them stays inside, as a newline")
        }
    }

    func testACarriageReturnAndLineFeedIsOneBreak() {
        XCTAssertEqual(texts("a\r\nb\r\n\r\nc"), ["a\nb", "c"], "\\r\\n\\r\\n is a blank line, not two")
        XCTAssertEqual(texts("a\r\nb", returns: 1), ["a", "b"])
    }

    func testTheRangesCoverEachPromptAndNothingElse() {
        let text = "alpha\nbeta\n\ngamma δelta 🙂\n\n\nlast"
        let ns = text as NSString
        let prompts = NotepadPrompts.prompts(in: text, returns: 2)
        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(ns.substring(with: prompts[0].range), "alpha\nbeta")
        XCTAssertEqual(ns.substring(with: prompts[1].range), "gamma δelta 🙂")
        XCTAssertEqual(ns.substring(with: prompts[2].range), "last", "the last line has no Return after it")
        var end = 0
        for prompt in prompts {
            XCTAssertGreaterThanOrEqual(prompt.range.location, end)
            end = NSMaxRange(prompt.range)
        }
    }

    func testThePromptAtTheInsertionPoint() {
        let text = "one\ntwo\n\nfour"          // one two = a prompt (0..<7), four (9..<13)
        XCTAssertEqual(NotepadPrompts.prompt(at: 0, in: text, returns: 2), "one\ntwo")
        XCTAssertEqual(NotepadPrompts.prompt(at: 5, in: text, returns: 2), "one\ntwo")
        XCTAssertEqual(NotepadPrompts.prompt(at: 7, in: text, returns: 2), "one\ntwo", "at the end of its last line")
        XCTAssertNil(NotepadPrompts.prompt(at: 8, in: text, returns: 2), "on the blank line between prompts")
        XCTAssertEqual(NotepadPrompts.prompt(at: 9, in: text, returns: 2), "four")
        XCTAssertEqual(NotepadPrompts.prompt(at: 13, in: text, returns: 2), "four", "at the very end")
        XCTAssertEqual(NotepadPrompts.prompt(at: 5, in: text, returns: 1), "two", "with one Return a line is a prompt")
    }

    func testAFinalReturnLeavesAnEmptyLineAtTheEnd() {
        XCTAssertNil(NotepadPrompts.prompt(at: 4, in: "one\n", returns: 2), "the caret after the last Return has nothing to load")
        XCTAssertEqual(NotepadPrompts.prompt(at: 3, in: "one\n", returns: 2), "one")
    }

    func testOutOfRangeAndEmptyAreSafe() {
        XCTAssertNil(NotepadPrompts.prompt(at: 0, in: "", returns: 2))
        XCTAssertEqual(NotepadPrompts.prompt(at: 999, in: "x", returns: 2), "x")
        XCTAssertEqual(NotepadPrompts.prompt(at: -5, in: "x", returns: 2), "x")
        XCTAssertEqual(texts("x", returns: 0), ["x"], "a setting out of range is made usable")
        XCTAssertEqual(texts("a\n\nb", returns: 99).count, 1, "…and 99 means the largest: two blank lines")
    }

    func testAPromptKeepsWhatItNeedsToBeTypedExactly() {
        // Quotes, dashes, slashes, tabs inside a line: nothing is "corrected" on the way.
        let text = "git commit -m \"fix: it's \\\"done\\\"\" -- a/b\ttab"
        XCTAssertEqual(texts(text), [text])
    }

    func testAManyLinePadIsFast() {
        let text = (0..<4000).map { "prompt \($0)\nsecond line\n" }.joined(separator: "\n")
        let start = Date()
        XCTAssertEqual(NotepadPrompts.prompts(in: text, returns: 2).count, 4000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}

final class NotepadLookTests: XCTestCase {
    func testItStartsClosedAndWideEnough() {
        let look = NotepadLook()
        XCTAssertFalse(look.isOpen)
        XCTAssertEqual(look.width, NotepadLook.defaultWidth)
        XCTAssertEqual(look.returnsPerPrompt, 2, "a prompt ends at a blank line unless Settings say otherwise")
    }

    func testTheReturnsThatEndAPromptStayInRange() {
        XCTAssertEqual(NotepadLook(returnsPerPrompt: 0).returnsPerPrompt, 1)
        XCTAssertEqual(NotepadLook(returnsPerPrompt: 3).returnsPerPrompt, 3)
        XCTAssertEqual(NotepadLook(returnsPerPrompt: 40).returnsPerPrompt, 3)
        XCTAssertEqual(NotepadLook(returnsPerPrompt: -2).returnsPerPrompt, 1)
    }

    func testTheWidthIsKeptBetweenTheMinimumAndTheRoomTheTerminalLeaves() {
        let window = 1200.0
        XCTAssertEqual(NotepadLook.clamped(width: 400, in: window), 400)
        XCTAssertEqual(NotepadLook.clamped(width: 20, in: window), NotepadLook.minimumWidth, "not thinner than the minimum")
        XCTAssertEqual(NotepadLook.clamped(width: 5000, in: window), window - NotepadLook.terminalMinimumWidth,
                       "the terminal keeps its room")
    }

    func testATinyWindowStillGetsAUsablePad() {
        XCTAssertEqual(NotepadLook.clamped(width: 400, in: 300), NotepadLook.minimumWidth)
        XCTAssertEqual(NotepadLook.clamped(width: 400, in: 0), NotepadLook.minimumWidth)
    }

    func testNothingStoredCanBeUnusable() {
        XCTAssertEqual(NotepadLook.sanitized(.nan), NotepadLook.defaultWidth)
        XCTAssertEqual(NotepadLook.sanitized(.infinity), NotepadLook.defaultWidth)
        XCTAssertEqual(NotepadLook.sanitized(-40), NotepadLook.minimumWidth)
        XCTAssertEqual(NotepadLook(isOpen: true, width: 3).width, NotepadLook.minimumWidth)
    }

    func testRoundTripAndOddFilesDecode() throws {
        let look = NotepadLook(isOpen: true, width: 333, returnsPerPrompt: 3)
        XCTAssertEqual(try JSONDecoder().decode(NotepadLook.self, from: JSONEncoder().encode(look)), look)
        let older = try JSONDecoder().decode(NotepadLook.self, from: Data(#"{"isOpen":true,"width":300}"#.utf8))
        XCTAssertEqual(older.returnsPerPrompt, 2, "a state from before the setting gets the default")
        let odd = try JSONDecoder().decode(NotepadLook.self, from: Data(#"{"isOpen":"yes","width":"wide","returnsPerPrompt":"two"}"#.utf8))
        XCTAssertEqual(odd, NotepadLook(), "a value a newer build wrote must not cost the workspace")
        XCTAssertEqual(try JSONDecoder().decode(NotepadLook.self, from: Data("{}".utf8)), NotepadLook())
    }
}

final class NotepadPersistenceTests: XCTestCase {
    func testTheTextRidesWithTheTerminal() throws {
        var session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        session.notepad = "first line\nsecond line\n\nthird 🙂"
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(TerminalSession.self, from: data).notepad, session.notepad)
    }

    func testAStateFromBeforeThePadStillOpens() throws {
        let id = UUID(), gid = UUID()
        let json = #"{"id":"\#(id)","groupID":"\#(gid)","workingDirectory":"/tmp"}"#
        let session = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
        XCTAssertNil(session.notepad)
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertEqual(state.notepad, NotepadLook())
    }

    func testTheLookRidesWithTheState() throws {
        var state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        state.notepad = NotepadLook(isOpen: true, width: 410)
        let again = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(again.notepad, NotepadLook(isOpen: true, width: 410))
    }
}

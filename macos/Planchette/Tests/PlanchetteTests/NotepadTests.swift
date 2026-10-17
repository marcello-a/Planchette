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

    func testABlankLineInsideACodeFenceDoesNotEndThePrompt() {
        let text = "explain this:\n```\n\nsaefewr\n\n```\n\nnext"
        XCTAssertEqual(texts(text), ["explain this:\n```\n\nsaefewr\n\n```", "next"])
    }

    func testAnUnclosedFenceRunsToTheEndOfThePad() {
        XCTAssertEqual(texts("```\na\n\nb"), ["```\na\n\nb"])
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


/// What happens to a prompt of the pad once it has been loaded into the terminal.
final class NotepadAfterLoadingTests: XCTestCase {
    /// Apply an edit the way the text view does.
    private func applied(_ edit: NotepadPrompts.Edit?, to text: String) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    /// Load prompt number `index` with the setting `action`; the text that is left.
    private func after(_ action: NotepadAfterLoading, prompt index: Int, in text: String, returns: Int = 2) -> String {
        let prompts = NotepadPrompts.prompts(in: text, returns: returns)
        return applied(NotepadPrompts.edit(afterLoading: action, prompts[index], in: text), to: text)
    }

    // MARK: remove

    func testRemovingTheFirstPromptLeavesTheOthersAsTheyWere() {
        XCTAssertEqual(after(.remove, prompt: 0, in: "one\n\ntwo\n\nthree"), "two\n\nthree")
    }

    func testRemovingAMiddlePromptLeavesNoGap() {
        XCTAssertEqual(after(.remove, prompt: 1, in: "one\n\ntwo\n\nthree"), "one\n\nthree")
    }

    func testRemovingTheLastPromptLeavesNoEmptyLinesAtTheEnd() {
        XCTAssertEqual(after(.remove, prompt: 2, in: "one\n\ntwo\n\nthree"), "one\n\ntwo")
        XCTAssertEqual(after(.remove, prompt: 1, in: "one\n\ntwo\n"), "one", "a final Return goes with it")
    }

    func testRemovingTheOnlyPromptEmptiesThePad() {
        XCTAssertEqual(after(.remove, prompt: 0, in: "only"), "")
        XCTAssertEqual(after(.remove, prompt: 0, in: "\n\nonly\n\n"), "")
    }

    func testAManyLinePromptGoesWholeAndTheBlankLinesAroundItCollapse() {
        let text = "keep\n\nfix the test\nin cart.spec.ts\n\n\n\nlater"
        XCTAssertEqual(after(.remove, prompt: 1, in: text), "keep\n\nlater")
    }

    func testWithOneReturnEachLineIsRemovedAlone() {
        XCTAssertEqual(after(.remove, prompt: 1, in: "a\nb\nc", returns: 1), "a\nc")
        XCTAssertEqual(after(.remove, prompt: 2, in: "a\nb\nc", returns: 1), "a\nb")
        XCTAssertEqual(after(.remove, prompt: 0, in: "a\nb\nc", returns: 1), "b\nc")
    }

    func testTheIndentationOfTheNextPromptSurvives() {
        XCTAssertEqual(after(.remove, prompt: 0, in: "one\n\n  two"), "  two")
    }

    func testEveryKindOfBreakIsRemovedWholeWithThePrompt() {
        XCTAssertEqual(after(.remove, prompt: 0, in: "one\r\n\r\ntwo"), "two")
        XCTAssertEqual(after(.remove, prompt: 0, in: "one\u{2029}\u{2029}two"), "two")
        XCTAssertEqual(after(.remove, prompt: 1, in: "one\r\n\r\ntwo"), "one")
    }

    func testRemovingEveryPromptOneByOneEmptiesThePadWhateverTheOrder() {
        for order in [[0, 0, 0], [2, 1, 0], [1, 0, 0], [0, 1, 0], [2, 0, 0]] {
            var text = "alpha\nsecond line\n\nbravo\n\n\ncharlie\n"
            for index in order {
                let count = NotepadPrompts.prompts(in: text, returns: 2).count
                text = after(.remove, prompt: min(index, count - 1), in: text)
            }
            XCTAssertTrue(NotepadPrompts.prompts(in: text, returns: 2).isEmpty, "order \(order): \(text.debugDescription)")
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "", "nothing but space is left, order \(order)")
        }
    }

    // MARK: strike

    func testStrikingWrapsThePromptInTheMark() {
        XCTAssertEqual(after(.strike, prompt: 0, in: "one\n\ntwo"), "~~one~~\n\ntwo")
        XCTAssertEqual(after(.strike, prompt: 1, in: "a\n\nfix it\nnow"), "a\n\n~~fix it\nnow~~")
    }

    func testAStruckPromptIsRecognisedAndLoadsWithoutTheMark() {
        let prompts = NotepadPrompts.prompts(in: "~~one~~\n\ntwo\n\n~~fix it\nnow~~", returns: 2)
        XCTAssertEqual(prompts.map(\.text), ["one", "two", "fix it\nnow"])
        XCTAssertEqual(prompts.map(\.isDone), [true, false, true])
    }

    func testStrikingTwiceDoesNothingTheSecondTime() {
        let once = after(.strike, prompt: 0, in: "one\n\ntwo")
        XCTAssertNil(NotepadPrompts.edit(afterLoading: .strike, NotepadPrompts.prompts(in: once, returns: 2)[0], in: once))
    }

    func testAMarkWithNothingBetweenItIsNotAStruckPrompt() {
        for text in ["~~", "~~~~", "~~ ~~", "~~one", "one~~"] {
            let prompts = NotepadPrompts.prompts(in: text, returns: 2)
            XCTAssertEqual(prompts.count, 1, text)
            XCTAssertFalse(prompts[0].isDone, text)
            XCTAssertEqual(prompts[0].text, text.trimmingCharacters(in: .whitespaces), "typed text stays as it is")
        }
    }

    func testRemovingAStruckPromptWorksLikeAnyOther() {
        XCTAssertEqual(after(.remove, prompt: 0, in: "~~one~~\n\ntwo"), "two")
    }

    // MARK: keep

    func testKeepingChangesNothing() {
        let text = "one\n\ntwo"
        XCTAssertNil(NotepadPrompts.edit(afterLoading: .keep, NotepadPrompts.prompts(in: text, returns: 2)[0], in: text))
    }

    // MARK: finding the prompt again

    func testThePromptIsFoundAgainWhereItMoved() {
        let before = "one\n\ntwo\n\nthree"
        let loaded = NotepadPrompts.prompts(in: before, returns: 2)[2]          // "three" at 10
        let now = "zero\n\none\n\ntwo\n\nthree"                              // something was added above
        let found = NotepadPrompts.locate(loaded.text, near: loaded.range.location, in: now, returns: 2)
        XCTAssertEqual((now as NSString).substring(with: found!.range), "three")
    }

    func testOfTwoIdenticalPromptsTheNearestOneIsTaken() {
        let text = "same\n\nother\n\nsame"
        let second = NotepadPrompts.prompts(in: text, returns: 2)[2]
        let found = NotepadPrompts.locate("same", near: second.range.location, in: text, returns: 2)
        XCTAssertEqual(found?.range, second.range)
        let first = NotepadPrompts.prompts(in: text, returns: 2)[0]
        XCTAssertEqual(NotepadPrompts.locate("same", near: 0, in: text, returns: 2)?.range, first.range)
    }

    func testAPromptThatIsGoneIsNotFoundAndNothingElseIsTouched() {
        XCTAssertNil(NotepadPrompts.locate("gone", near: 0, in: "one\n\ntwo", returns: 2))
        XCTAssertNil(NotepadPrompts.locate("one", near: 0, in: "", returns: 2))
    }

    // MARK: the setting

    func testTheDefaultIsToRemove() {
        XCTAssertEqual(NotepadAfterLoading.default, .remove)
        XCTAssertEqual(NotepadLook().afterLoading, .remove)
    }

    func testTheSettingRoundTripsAndOldOrOddFilesGetTheDefault() throws {
        for action in NotepadAfterLoading.allCases {
            let look = NotepadLook(isOpen: true, width: 300, returnsPerPrompt: 2, afterLoading: action)
            XCTAssertEqual(try JSONDecoder().decode(NotepadLook.self, from: JSONEncoder().encode(look)), look)
        }
        let older = try JSONDecoder().decode(NotepadLook.self, from: Data(#"{"isOpen":true,"width":300,"returnsPerPrompt":1}"#.utf8))
        XCTAssertEqual(older.afterLoading, .remove)
        let odd = try JSONDecoder().decode(NotepadLook.self, from: Data(#"{"afterLoading":"burn"}"#.utf8))
        XCTAssertEqual(odd.afterLoading, .remove, "a value a newer build wrote must not cost the workspace")
    }
}

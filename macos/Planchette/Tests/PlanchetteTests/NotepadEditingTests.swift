import XCTest
@testable import Planchette

/// Return and Tab in the notepad, the way a Markdown editor does them.
final class NotepadEditingTests: XCTestCase {
    /// The text after the change, with `|` where the insertion point is.
    private func applied(_ change: NotepadEditing.Change?, to text: String) -> String? {
        guard let change else { return nil }
        let result = (text as NSString).replacingCharacters(in: change.range, with: change.replacement) as NSString
        return result.replacingCharacters(in: NSRange(location: change.caret, length: 0), with: "|")
    }

    /// Return at the `|` of `marked`.
    private func newline(_ marked: String) -> String? {
        let location = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        return applied(NotepadEditing.newline(at: location, in: text), to: text)
    }

    private func tab(_ marked: String, outdent: Bool = false) -> String? {
        let location = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        return applied(NotepadEditing.indent(at: location, in: text, outdent: outdent), to: text)
    }

    func testABulletListGoesOn() {
        XCTAssertEqual(newline("- milk|"), "- milk\n- |")
        XCTAssertEqual(newline("* milk|"), "* milk\n* |")
        XCTAssertEqual(newline("  + milk|"), "  + milk\n  + |")
    }

    func testANumberedListCountsOn() {
        XCTAssertEqual(newline("1. one|"), "1. one\n2. |")
        XCTAssertEqual(newline("9) nine|"), "9) nine\n10) |")
    }

    func testTheItemsBelowAreNumberedAgain() {
        XCTAssertEqual(newline("1. one|\n2. two\n3. three"), "1. one\n2. |\n3. two\n4. three")
        // A nested item keeps its numbers; the list stops at the first line that is not an item.
        XCTAssertEqual(newline("1. one|\n2. two\n   1. sub\n3. three\nafter"),
                       "1. one\n2. |\n3. two\n   1. sub\n4. three\nafter")
    }

    func testReturnInTheMiddleOfAnItemTakesTheRestAlong() {
        XCTAssertEqual(newline("- milk| and eggs"), "- milk\n- | and eggs")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        XCTAssertEqual(newline("- milk\n- |"), "- milk\n|")
        XCTAssertEqual(newline("1. one\n2. |"), "1. one\n|")
    }

    func testATaskListGoesOnWithAnOpenBox() {
        XCTAssertEqual(newline("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(newline("- [ ] |"), "|")
    }

    func testAQuoteGoesOn() {
        XCTAssertEqual(newline("> said|"), "> said\n> |")
    }

    func testPlainTextAndTheMarkerItselfAreLeftAlone() {
        XCTAssertNil(newline("plain text|"))
        XCTAssertNil(newline("-|"))
        XCTAssertNil(newline("-| milk"))
    }

    func testAnOpeningFenceGetsItsClosingFence() {
        XCTAssertEqual(newline("```swift|"), "```swift\n|\n```")
        // A fence that closes a block, or one with a fence after it, gets nothing.
        XCTAssertNil(newline("```\ncode\n```|"))
        XCTAssertNil(newline("```|\ncode\n```"))
    }

    func testCodeKeepsTheIndentOfTheLineAbove() {
        XCTAssertEqual(newline("```\nif x {\n    call()|\n```"), "```\nif x {\n    call()\n    |\n```")
        XCTAssertNil(newline("```\nflat|\n```"))
        // A list marker inside code is code.
        XCTAssertNil(newline("```\n- not a list|\n```"))
    }

    func testTabMovesAnItemInAndShiftTabOut() {
        XCTAssertEqual(tab("- mi|lk"), "  - mi|lk")
        XCTAssertEqual(tab("1. one|"), "   1. one|")
        XCTAssertEqual(tab("  - mi|lk", outdent: true), "- mi|lk")
        XCTAssertNil(tab("- milk|", outdent: true))
        XCTAssertNil(tab("plain|"))
    }

    func testAClickOnTheBoxTicksTheTask() {
        let text = "- [ ] buy milk"
        let change = NotepadEditing.toggleTask(at: 3, in: text)
        XCTAssertEqual(change.map { (text as NSString).replacingCharacters(in: $0.range, with: $0.replacement) },
                       "- [x] buy milk")
        let ticked = "- [x] buy milk"
        XCTAssertEqual(NotepadEditing.toggleTask(at: 2, in: ticked)?.replacement, "[ ]")
        // Not on the box: nothing.
        XCTAssertNil(NotepadEditing.toggleTask(at: 10, in: text))
        XCTAssertNil(NotepadEditing.toggleTask(at: 2, in: "- buy milk"))
    }

    func testOutOfRangeIsHarmless() {
        XCTAssertNil(NotepadEditing.newline(at: 99, in: "- a"))
        XCTAssertNil(NotepadEditing.indent(at: -1, in: "- a", outdent: false))
        XCTAssertNil(NotepadEditing.newline(at: 0, in: ""))
    }
}

/// Code in the notepad: what looks like code, the blocks, the folds and the colours.
final class NotepadCodeTests: XCTestCase {
    private func suggestion(_ text: String) -> NotepadCode.Suggestion? {
        NotepadCode.suggestion(within: NSRange(location: 0, length: (text as NSString).length), of: text)
    }

    func testCodeIsFound() {
        let swift = "func load() {\n    let x = 1\n    return x\n}"
        XCTAssertEqual(suggestion(swift)?.range, NSRange(location: 0, length: (swift as NSString).length))
        XCTAssertEqual(suggestion(swift)?.language, "swift")
        XCTAssertEqual(suggestion("{\n  \"name\": \"a\",\n  \"size\": 2\n}")?.language, "json")
        XCTAssertEqual(suggestion("git fetch origin\ngit rebase origin/main")?.language, "bash")
    }

    func testWordsAreNotCode() {
        XCTAssertNil(suggestion("Please fix the login.\nThen run the tests and tell me what failed."))
        XCTAssertNil(suggestion("- milk\n- eggs\n- bread"))
        XCTAssertNil(suggestion("# Plan\nWrite the tests first."))
        // One line is a command to send, not code to show.
        XCTAssertNil(suggestion("git push"))
    }

    func testOnlyTheCodeOfAPromptIsOffered() {
        let text = "Why does this crash?\nlet x = items[3]\nprint(x)"
        let found = suggestion(text)
        XCTAssertEqual(found.map { (text as NSString).substring(with: $0.range) }, "let x = items[3]\nprint(x)")
    }

    func testCodeInAFenceIsNotOfferedAgain() {
        XCTAssertNil(suggestion("```\nlet x = 1\nlet y = 2\n```"))
    }

    func testFencingPutsTheStretchBetweenFences() {
        let text = "guard let x else { return }\nlet y = x"
        guard let found = suggestion(text) else { return XCTFail("no suggestion") }
        let change = NotepadCode.fence(found, in: text)
        let result = (text as NSString).replacingCharacters(in: change.range, with: change.replacement)
        XCTAssertEqual(result, "```swift\nguard let x else { return }\nlet y = x\n```")
        // `let` alone is Swift or JavaScript: the fence names no language then.
        XCTAssertNil(suggestion("let x = 1\nlet y = 2")?.language)
        XCTAssertEqual(change.caret, (result as NSString).length)
    }

    func testBlocks() {
        let text = "a\n```swift\none\ntwo\nthree\n```\nb\n```\nopen"
        let blocks = NotepadCode.blocks(in: text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].language, "swift")
        XCTAssertEqual(blocks[0].lines.map { (text as NSString).substring(with: $0) }, ["one", "two", "three"])
        XCTAssertNotNil(blocks[0].close)
        XCTAssertNil(blocks[1].close)
        XCTAssertNil(blocks[1].language)
    }

    func testAFoldHidesFromTheEndOfTheSecondLineToTheEndOfTheLast() {
        let text = "```\none\ntwo\nthree\nfour\n```"
        let block = NotepadCode.blocks(in: text)[0]
        let hidden = NotepadCode.foldedRange(of: block)
        XCTAssertEqual(hidden.map { (text as NSString).substring(with: $0) }, "\nthree\nfour")
        XCTAssertEqual(NotepadCode.hiddenLineCount(of: block), 2)
    }

    func testShortAndOpenBlocksDoNotFold() {
        XCTAssertNil(NotepadCode.foldedRange(of: NotepadCode.blocks(in: "```\none\ntwo\n```")[0]))
        XCTAssertNil(NotepadCode.foldedRange(of: NotepadCode.blocks(in: "```\none\ntwo\nthree")[0]))
    }

    private func tokens(_ line: String, _ language: String?) -> [String: NotepadCode.Token] {
        var result: [String: NotepadCode.Token] = [:]
        for token in NotepadCode.tokens(in: line, language: language) {
            result[(line as NSString).substring(with: token.range)] = token.token
        }
        return result
    }

    func testColours() {
        let found = tokens("let name = \"Ada\" // the 1st", "swift")
        XCTAssertEqual(found["let"], .keyword)
        XCTAssertEqual(found["\"Ada\""], .string)
        XCTAssertEqual(found["// the 1st"], .comment)
        XCTAssertNil(found["name"])
        let more = tokens("var count: Int = 42", "swift")
        XCTAssertEqual(more["Int"], .type)
        XCTAssertEqual(more["42"], .number)
    }

    func testHashIsACommentWhereTheLanguageSaysSo() {
        XCTAssertEqual(tokens("x = 1  # set", "python")["# set"], .comment)
        XCTAssertNil(tokens("#if DEBUG", "swift")["#if DEBUG"])
        XCTAssertEqual(tokens("select * from t -- all", "sql")["select"], .keyword)
        XCTAssertEqual(tokens("select * from t -- all", "sql")["-- all"], .comment)
    }

    func testAnApostropheInAWordIsNotAString() {
        XCTAssertTrue(tokens("// don't", "swift").values.allSatisfy { $0 == .comment })
        XCTAssertNil(tokens("print(don't)", "swift")["'t)"])
    }

    func testTokensStayInsideTheLine() {
        for line in ["\"open string", "'", "``` ", "a // b", "🎉 = \"x\""] {
            let length = (line as NSString).length
            for token in NotepadCode.tokens(in: line, language: nil) {
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), length, line)
            }
        }
    }

    func testLanguageNames() {
        XCTAssertEqual(NotepadCode.displayName(of: "ts"), "TypeScript")
        XCTAssertEqual(NotepadCode.displayName(of: "kotlin"), "Kotlin")
    }
}

/// What left the notepad, and what of a deletion is worth keeping.
final class NotepadHistoryTests: XCTestCase {
    func testNewestFirstAndAtMostTheLimit() {
        var list: [NotepadHistoryEntry] = []
        for n in 0..<(NotepadHistory.limit + 5) {
            list = NotepadHistory.adding(NotepadHistoryEntry(kind: .sent, text: "prompt \(n)"), to: list)
        }
        XCTAssertEqual(list.count, NotepadHistory.limit)
        XCTAssertEqual(list.first?.text, "prompt \(NotepadHistory.limit + 4)")
    }

    func testBlanksAndRepeatsAreNotAdded() {
        let one = NotepadHistory.adding(NotepadHistoryEntry(kind: .sent, text: "  run it \n"), to: [])
        XCTAssertEqual(one.map(\.text), ["run it"])
        XCTAssertEqual(NotepadHistory.adding(NotepadHistoryEntry(kind: .sent, text: "run it"), to: one).count, 1)
        XCTAssertEqual(NotepadHistory.adding(NotepadHistoryEntry(kind: .deleted, text: "run it"), to: one).count, 2)
        XCTAssertEqual(NotepadHistory.adding(NotepadHistoryEntry(kind: .sent, text: " \n "), to: one).count, 1)
    }

    func testALongTextIsCut() {
        let long = String(repeating: "a", count: NotepadHistory.maximumLength + 10)
        let list = NotepadHistory.adding(NotepadHistoryEntry(kind: .deleted, text: long), to: [])
        XCTAssertEqual(list.first?.text.count, NotepadHistory.maximumLength)
    }

    func testWhatADeletionIsWorth() {
        XCTAssertNil(NotepadHistory.worthKeeping("teh", lineIsLeftBlank: false))
        XCTAssertEqual(NotepadHistory.worthKeeping("short line", lineIsLeftBlank: true), "short line")
        XCTAssertEqual(NotepadHistory.worthKeeping("one\ntwo", lineIsLeftBlank: false), "one\ntwo")
        XCTAssertNotNil(NotepadHistory.worthKeeping(String(repeating: "x", count: 20), lineIsLeftBlank: false))
        XCTAssertNil(NotepadHistory.worthKeeping(" \n ", lineIsLeftBlank: true))
    }

    func testKeysDeletedOneByOneAreGathered() {
        // Backspace, Backspace: "ab|" loses b, then a.
        var run = NotepadHistory.Run(location: 1, text: "b")
        run = run.adding("a", at: NSRange(location: 0, length: 1)) ?? run
        XCTAssertEqual(run, NotepadHistory.Run(location: 0, text: "ab"))
        // Delete, Delete at the same place.
        var forward = NotepadHistory.Run(location: 0, text: "a")
        forward = forward.adding("b", at: NSRange(location: 0, length: 1)) ?? forward
        XCTAssertEqual(forward.text, "ab")
        // Somewhere else: a run of its own.
        XCTAssertNil(run.adding("z", at: NSRange(location: 7, length: 1)))
    }

    func testAnOldTerminalHasNoHistoryAndABadEntryCostsOnlyItself() throws {
        let id = UUID(), group = UUID()
        let old = #"{"id":"\#(id)","groupID":"\#(group)","workingDirectory":"/tmp"}"#
        XCTAssertNil(try JSONDecoder().decode(TerminalSession.self, from: Data(old.utf8)).notepadHistory)

        let mixed = #"""
        {"id":"\#(id)","groupID":"\#(group)","workingDirectory":"/tmp",
         "notepadHistory":[{"kind":"sent","text":"ok","date":0},{"kind":"teleported","text":"?"},{"text":"no kind"}]}
        """#
        let session = try JSONDecoder().decode(TerminalSession.self, from: Data(mixed.utf8))
        XCTAssertEqual(session.notepadHistory?.map(\.text), ["ok"])
    }

    func testTheHistoryGoesToDiskAndBack() throws {
        var session = TerminalSession(groupID: UUID(), workingDirectory: "/tmp")
        session.notepadHistory = [NotepadHistoryEntry(kind: .deleted, text: "gone line")]
        let back = try JSONDecoder().decode(TerminalSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(back.notepadHistory, session.notepadHistory)
    }
}

/// What "Format with AI" sends and takes back.
final class NotepadFormatTests: XCTestCase {
    func testThePromptCarriesTheTextAndTheSeparation() {
        let prompt = NotepadFormat.prompt(for: "fix it", returns: 2)
        XCTAssertTrue(prompt.contains("<<<NOTEPAD\nfix it\nNOTEPAD>>>"))
        XCTAssertTrue(prompt.contains("1 blank line."))
        XCTAssertTrue(NotepadFormat.prompt(for: "x", returns: 3).contains("2 blank lines"))
        XCTAssertTrue(NotepadFormat.prompt(for: "x", returns: 1).contains("Every line is one prompt"))
    }

    func testWhatIsAroundTheAnswerGoes() {
        XCTAssertEqual(NotepadFormat.cleaned("```markdown\n# Plan\n- a\n```"), "# Plan\n- a")
        XCTAssertEqual(NotepadFormat.cleaned("<<<NOTEPAD\ntext\nNOTEPAD>>>\n"), "text")
        // A pad that is one code block stays one.
        XCTAssertEqual(NotepadFormat.cleaned("```swift\nlet x = 1\n```"), "```swift\nlet x = 1\n```")
        XCTAssertNil(NotepadFormat.cleaned("  \n "))
    }

    func testAnAnswerThatLostOrAddedMuchIsTurnedDown() {
        let original = "please fix the login page and run the tests"
        XCTAssertTrue(NotepadFormat.isPlausible("Please fix the **login page** and run the tests.", from: original))
        XCTAssertFalse(NotepadFormat.isPlausible("Done!", from: original))
        XCTAssertFalse(NotepadFormat.isPlausible(original + " " + original, from: original))
    }
}

/// ⌘B, ⌘I, ⌘E and the backtick around a selection; a web address pasted over words.
final class NotepadMarksTests: XCTestCase {
    /// The text after the change, with the selection written as `[…]` or a caret as `|`.
    private func toggled(_ mark: String, _ marked: String) -> String? {
        let ns = marked as NSString
        let open = ns.range(of: "[")
        let selection: NSRange
        let text: String
        if open.location != NSNotFound {
            let close = ns.range(of: "]")
            selection = NSRange(location: open.location, length: close.location - open.location - 1)
            text = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        } else {
            selection = NSRange(location: ns.range(of: "|").location, length: 0)
            text = marked.replacingOccurrences(of: "|", with: "")
        }
        guard let change = NotepadEditing.toggleMarks(mark, around: selection, in: text) else { return nil }
        return (text as NSString).replacingCharacters(in: change.range, with: change.replacement)
    }

    func testMarksGoAroundTheSelection() {
        XCTAssertEqual(toggled("**", "make [this] bold"), "make **this** bold")
        XCTAssertEqual(toggled("*", "make [this] italic"), "make *this* italic")
        XCTAssertEqual(toggled("`", "run [git push] now"), "run `git push` now")
    }

    func testSpacesAtTheEdgesStayOutside() {
        XCTAssertEqual(toggled("**", "a[ word ]b"), "a **word** b")
        XCTAssertNil(toggled("**", "a[   ]b"))
    }

    func testMarksComeOffAgain() {
        XCTAssertEqual(toggled("**", "make [**this**] plain"), "make this plain")
        XCTAssertEqual(toggled("**", "make **[this]** plain"), "make this plain")
        XCTAssertEqual(toggled("`", "run `[git push]` now"), "run git push now")
    }

    func testItalicDoesNotTakeTheStarsOfBold() {
        XCTAssertEqual(toggled("*", "a **[b]** c"), "a ***b*** c")
        XCTAssertEqual(toggled("*", "a [**b**] c"), "a ***b*** c")
    }

    func testNothingSelectedPutsInAPair() {
        XCTAssertEqual(toggled("**", "a |b"), "a ****b")
        let change = NotepadEditing.toggleMarks("**", around: NSRange(location: 2, length: 0), in: "a b")
        XCTAssertEqual(change?.caret, 4)
    }

    func testAnAddressPastedOverWordsMakesALink() {
        let text = "see the docs here"
        let selection = NSRange(location: 4, length: 8)          // "the docs"
        let change = NotepadEditing.link(pasting: "https://example.com/a?b=1\n", over: selection, in: text)
        XCTAssertEqual(change.map { (text as NSString).replacingCharacters(in: $0.range, with: $0.replacement) },
                       "see [the docs](https://example.com/a?b=1) here")
    }

    func testOtherPastesAreLeftAlone() {
        let text = "see the docs"
        XCTAssertNil(NotepadEditing.link(pasting: "just words", over: NSRange(location: 4, length: 3), in: text))
        XCTAssertNil(NotepadEditing.link(pasting: "https://example.com", over: NSRange(location: 4, length: 0), in: text))
        XCTAssertNil(NotepadEditing.link(pasting: "https://a.b", over: NSRange(location: 0, length: 12),
                                         in: "https://x.yz"))
        XCTAssertNil(NotepadEditing.link(pasting: "https://example.com", over: NSRange(location: 0, length: 5),
                                         in: "a\nb c"))
        XCTAssertFalse(NotepadEditing.isURL("ftp://x.y"))
        XCTAssertFalse(NotepadEditing.isURL("https://a b"))
    }

    func testALinkIsStyledAndFoundUnderAClick() {
        let text = "read [the docs](https://example.com) first"
        let ns = text as NSString
        let links = NotepadMarkdown.spans(in: text).filter { $0.style == .link }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(links, ["the docs"])
        XCTAssertEqual(NotepadMarkdown.link(at: 8, in: text)?.absoluteString, "https://example.com")
        XCTAssertNil(NotepadMarkdown.link(at: 1, in: text))
    }

    func testTheCodeFormatterSendsTheCodeAndTakesBackOnlyCode() {
        let prompt = NotepadFormat.codePrompt(for: "let x=1", language: "swift")
        XCTAssertTrue(prompt.contains("Format this Swift code"))
        XCTAssertTrue(prompt.contains("<<<CODE\nlet x=1\nCODE>>>"))
        XCTAssertTrue(NotepadFormat.codePrompt(for: "x", language: nil).contains("Format this code"))
        XCTAssertEqual(NotepadFormat.cleanedCode("```swift\nif x {\n    y()\n}\n```\n"), "if x {\n    y()\n}")
        XCTAssertEqual(NotepadFormat.cleanedCode("\n    indented()\n"), "    indented()")
        XCTAssertNil(NotepadFormat.cleanedCode("```\n```"))
    }
}

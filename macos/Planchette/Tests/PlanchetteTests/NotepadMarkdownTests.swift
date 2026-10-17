import XCTest
@testable import Planchette

/// What the notepad shows as Markdown, and how large: the text itself is never touched.
final class NotepadMarkdownTests: XCTestCase {
    private func found(_ text: String, _ style: NotepadMarkdown.Style) -> [String] {
        let ns = text as NSString
        return NotepadMarkdown.spans(in: text).filter { $0.style == style }.map { ns.substring(with: $0.range) }
    }

    func testHeadlines() {
        let text = "# Title\n## Part\nplain\n#hashtag\n####### seven"
        XCTAssertEqual(found(text, .heading(1)), ["# Title"])
        XCTAssertEqual(found(text, .heading(2)), ["## Part"])
        XCTAssertTrue(NotepadMarkdown.spans(in: "#hashtag").isEmpty)
        XCTAssertTrue(NotepadMarkdown.spans(in: "####### seven").isEmpty)
    }

    func testTheHashesOfAHeadlineAreMarks() {
        XCTAssertEqual(found("## Part", .mark), ["##"])
    }

    func testFencedCodeIsCodeAndNothingInsideIsMarkdown() {
        let text = "before\n```swift\n# not a headline\n**not bold**\n```\nafter"
        XCTAssertEqual(found(text, .codeBlock), ["```swift", "# not a headline", "**not bold**", "```"])
        XCTAssertTrue(found(text, .bold).isEmpty)
        XCTAssertTrue(found(text, .heading(1)).isEmpty)
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(found("```\nline one\nline two", .codeBlock), ["```", "line one", "line two"])
    }

    func testInlineEmphasis() {
        let text = "use `git add -A` with **care** and *some* _doubt_"
        XCTAssertEqual(found(text, .inlineCode), ["`git add -A`"])
        XCTAssertEqual(found(text, .bold), ["**care**"])
        XCTAssertEqual(found(text, .italic), ["*some*", "_doubt_"])
    }

    func testCodeWinsOverEmphasis() {
        XCTAssertTrue(found("`**x**`", .bold).isEmpty)
        XCTAssertEqual(found("`**x**`", .inlineCode), ["`**x**`"])
    }

    func testSnakeCaseAndMathAreNotItalic() {
        XCTAssertTrue(found("a snake_case_name and 2 * 3 * 4", .italic).isEmpty)
    }

    func testListsAndQuotes() {
        let text = "- one\n  * two\n1. three\n2) four\n> said\n-no list"
        let items = NotepadMarkdown.spans(in: text).compactMap { span -> (String, Int)? in
            if case .listItem(let prefix) = span.style { return ((text as NSString).substring(with: span.range), prefix) }
            return nil
        }
        XCTAssertEqual(items.map(\.0), ["- one", "  * two", "1. three", "2) four"])
        XCTAssertEqual(items.map(\.1), [2, 4, 3, 3])
        XCTAssertEqual(found(text, .quote), ["> said"])
    }

    func testSpansStayInsideTheTextWithCRLFAndUnicode() {
        let text = "# Tïtle 🎉\r\n- **bold** `c`\r\n\r\n> q"
        let length = (text as NSString).length
        for span in NotepadMarkdown.spans(in: text) {
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), length)
            XCTAssertFalse((text as NSString).substring(with: span.range).contains("\n"))
        }
    }

    func testTheSizeFollowsTheWidthAndStaysInRange() {
        XCTAssertEqual(NotepadMarkdown.bodySize(forWidth: 100), 12)
        XCTAssertEqual(NotepadMarkdown.bodySize(forWidth: 5000), 14)
        let sizes = stride(from: 150.0, through: 600, by: 10).map(NotepadMarkdown.bodySize(forWidth:))
        XCTAssertEqual(sizes, sizes.sorted())
    }

    func testHeadlinesAreTamedInANarrowPad() {
        for level in 1...6 {
            let narrow = NotepadMarkdown.headingScale(level: level, forWidth: 180)
            let wide = NotepadMarkdown.headingScale(level: level, forWidth: 500)
            XCTAssertGreaterThanOrEqual(narrow, 1)
            XCTAssertLessThanOrEqual(narrow, wide)
        }
        XCTAssertGreaterThan(NotepadMarkdown.headingScale(level: 1, forWidth: 300),
                             NotepadMarkdown.headingScale(level: 3, forWidth: 300))
    }
}

final class ClaudeInputDraftTests: XCTestCase {
    private func screen(input: String) -> String {
        "> an earlier message\n\nAnswer.\n╭──────╮\n│ > \(input) │\n╰──────╯\n  ? for shortcuts"
    }

    func testTypedTextIsADraft() {
        XCTAssertTrue(ClaudeInputDraft.hasDraft(in: screen(input: "fix the test")))
    }

    func testAnEmptyBoxOrItsSuggestionIsNot() {
        XCTAssertFalse(ClaudeInputDraft.hasDraft(in: screen(input: "")))
        XCTAssertFalse(ClaudeInputDraft.hasDraft(in: screen(input: "Try \"how does it work\"")))
    }

    func testAPlainShellHasNoAnswer() {
        XCTAssertNil(ClaudeInputDraft.text(in: "marcello@mac ~ % ls\nfile"))
    }
}

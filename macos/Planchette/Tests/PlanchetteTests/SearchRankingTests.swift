import XCTest
@testable import Planchette

final class SearchRankingTests: XCTestCase {
    private func entry(
        _ title: String, project: String = "", branch: String = "", path: String = "",
        tags: [String] = [], note: String = "", task: String = "", summary: String = "",
        message: String = "", pr: Int? = nil, prTitle: String = "", background: [String] = [],
        urgency: Int = 0, since: TimeInterval = 0
    ) -> SearchEntry {
        SearchEntry(id: UUID(), title: title, project: project, branch: branch, path: path, tags: tags,
                    note: note, task: task, summary: summary, message: message, pullRequest: pr,
                    pullRequestTitle: prTitle, background: background, urgency: urgency,
                    stateSince: Date(timeIntervalSince1970: since))
    }

    private func titles(_ query: String, _ entries: [SearchEntry]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.title) })
        return SearchRanking.rank(query, in: entries).map { byID[$0.id]! }
    }

    private func find(_ word: String, in text: String) -> SearchRanking.Found? {
        SearchRanking.find(SearchRanking.fold(word), in: text)
    }

    // MARK: Folding and words

    func testFoldingIsOneCharacterForOneCharacter() {
        for text in ["Straße", "Café Crème", "ÄÖÜ", "NIE-2008", "日本語", "e\u{301}"] {
            XCTAssertEqual(SearchRanking.fold(text).count, Array(text).count, text)
        }
        XCTAssertEqual(String(SearchRanking.fold("Café")), "cafe")
        XCTAssertEqual(String(SearchRanking.fold("ÄÖÜ")), "aou")
    }

    func testAQueryIsFoldedWordsAndAHashIsDropped() {
        XCTAssertEqual(SearchRanking.words(of: "  Wall   MENU ").map { String($0) }, ["wall", "menu"])
        XCTAssertEqual(SearchRanking.words(of: "#5576").map { String($0) }, ["5576"])
        XCTAssertEqual(SearchRanking.words(of: "#").map { String($0) }, ["#"], "a lone # is a word")
        XCTAssertTrue(SearchRanking.words(of: "   ").isEmpty)
    }

    func testWordsSplitAtSeparatorsCaseAndDigits() {
        func words(_ text: String) -> [String] {
            let chars = Array(text)
            return SearchRanking.wordRanges(in: chars).map { String(chars[$0]) }
        }
        XCTAssertEqual(words("room-view-2"), ["room", "view", "2"])
        XCTAssertEqual(words("roomView2"), ["room", "View", "2"])
        XCTAssertEqual(words("plt-probe-1/work"), ["plt", "probe", "1", "work"])
        XCTAssertEqual(words("marcello/feat/NIE-2008-gallery"), ["marcello", "feat", "NIE", "2008", "gallery"])
        XCTAssertEqual(words("  "), [])
    }

    // MARK: Ways a word is found

    func testTheBetterTheWayTheMoreItIsWorth() {
        XCTAssertEqual(find("menu", in: "gallery wall menu")?.way, .whole)
        XCTAssertEqual(find("gal", in: "gallery wall menu")?.way, .start)
        XCTAssertEqual(find("allery", in: "gallery wall menu")?.way, .inside)
        XCTAssertEqual(find("gwm", in: "gallery wall menu")?.way, .acronym)
        XCTAssertEqual(find("gllry", in: "gallery wall menu")?.way, .subsequence)
        XCTAssertNil(find("xyz", in: "gallery wall menu"))
    }

    func testRangesPointAtWhatWasFound() {
        XCTAssertEqual(find("wall", in: "gallery wall menu")?.ranges, [8..<12])
        XCTAssertEqual(find("gal", in: "gallery wall menu")?.ranges, [0..<3])
        XCTAssertEqual(find("gwm", in: "gallery wall menu")?.ranges, [0..<1, 8..<9, 13..<14])
        XCTAssertEqual(find("wall-m", in: "gallery wall-menu")?.ranges, [8..<14], "across a separator")
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertEqual(find("cafe", in: "Café Planung")?.way, .whole)
        XCTAssertEqual(find("PLAN", in: "café planung")?.way, .start)
        XCTAssertEqual(find("ärger", in: "Aerger und Arger")?.way, .whole, "Ä folds to A")
    }

    func testCamelCaseAndDigitsAreWords() {
        XCTAssertEqual(find("view", in: "roomViewScene")?.way, .whole)
        XCTAssertEqual(find("2008", in: "NIE2008gallery")?.way, .whole)
        XCTAssertEqual(find("nie", in: "NIE2008gallery")?.way, .whole)
    }

    // The old search joined every field into one line and accepted letters from
    // anywhere in it. Letters must stay close, or form initials.
    func testScatteredLettersAreNotAMatch() {
        XCTAssertNil(find("abc", in: "a long text that holds a b and c far apart"))
        XCTAssertNil(find("bdg", in: "building"), "three letters spread over eight")
        XCTAssertNil(find("tps", in: "terminal"), "not in order")
        XCTAssertEqual(find("bldg", in: "building")?.way, .subsequence, "close enough")
    }

    func testInitialsNeedConsecutiveWords() {
        XCTAssertEqual(find("gwm", in: "gallery wall menu")?.way, .acronym)
        XCTAssertNil(find("gm", in: "gallery wall menu"), "wall is skipped")
        XCTAssertNil(find("xy", in: "gallery wall menu"))
    }

    // MARK: Ranking

    func testAWholeWordInTheNameOutranksTheSameWordInASummary() {
        let named = entry("billing", summary: "other")
        let summed = entry("other", summary: "about billing")
        XCTAssertEqual(titles("billing", [summed, named]), ["billing", "other"])
    }

    func testTheStartOfAWordOutranksTheInsideOfOne() {
        let start = entry("designer")
        let inside = entry("redesign")
        XCTAssertEqual(titles("des", [inside, start]), ["designer", "redesign"])
    }

    func testEveryWordOfTheQueryHasToBeFound() {
        let both = entry("gallery", branch: "feat/wall-menu")
        let one = entry("gallery wall")
        let neither = entry("billing")
        XCTAssertEqual(titles("gallery menu", [one, neither, both]), ["gallery"])
        XCTAssertEqual(Set(titles("gallery wall", [one, neither, both])), ["gallery", "gallery wall"])
    }

    func testWordsMayBeFoundInDifferentFields() {
        let e = entry("api", project: "myposter", tags: ["review"])
        XCTAssertEqual(titles("api review myposter", [e]), ["api"])
    }

    func testAnEmptyQueryIsTheCalmOrder() {
        let calm = entry("calm", since: 100)
        let newer = entry("newer", since: 200)
        let asking = entry("asking", urgency: 3, since: 1)
        XCTAssertEqual(titles("", [calm, newer, asking]), ["asking", "newer", "calm"])
        XCTAssertEqual(titles("   ", [calm, newer, asking]), ["asking", "newer", "calm"])
    }

    func testTheIdleListIsShort() {
        let many = (0..<30).map { entry("t\($0)", since: TimeInterval($0)) }
        XCTAssertEqual(SearchRanking.idle(many).count, 12)
        XCTAssertEqual(SearchRanking.idle(many).first.map { _ in "t29" }, "t29")
    }

    func testUrgencyBreaksACloseCallAndNeverBeatsABetterWord() {
        let calm = entry("deploy", since: 0)
        let asking = entry("deploy", urgency: 3, since: 0)
        XCTAssertEqual(SearchRanking.rank("deploy", in: [calm, asking]).first?.id, asking.id)
        // A whole word in the name beats a half word in the name, urgent or not.
        let exact = entry("log")
        let partial = entry("logbook", urgency: 6)
        XCTAssertEqual(titles("log", [partial, exact]), ["log", "logbook"])
    }

    func testTheNewerTerminalWinsATie() {
        let old = entry("same", since: 10)
        let new = entry("same", since: 20)
        XCTAssertEqual(SearchRanking.rank("same", in: [old, new]).first?.id, new.id)
    }

    // MARK: Pull requests, branches, tags

    func testAPullRequestIsFoundByItsNumber() {
        let e = entry("work", pr: 5576)
        XCTAssertEqual(titles("#5576", [e]), ["work"])
        XCTAssertEqual(titles("5576", [e]), ["work"])
        XCTAssertEqual(titles("55", [e]), ["work"], "from its start")
        XCTAssertTrue(titles("57", [e]).isEmpty, "not from the inside of the number")
    }

    func testATicketInABranchIsFound() {
        let e = entry("work", branch: "marcello/feat/NIE-2008-gallery-wall-menu")
        XCTAssertEqual(titles("nie-2008", [e]), ["work"])
        XCTAssertEqual(titles("2008", [e]), ["work"])
        XCTAssertEqual(titles("gwm", [e]), ["work"])
    }

    func testWhatRunsInTheBackgroundIsSearchable() {
        let e = entry("work", background: ["npm run dev", "Review the diff"])
        XCTAssertEqual(titles("dev", [e]), ["work"])
        XCTAssertEqual(titles("review", [e]), ["work"])
    }

    // MARK: What the row shows, and why a terminal is there

    func testHighlightsFollowTheMatch() {
        let e = entry("gallery wall menu", path: "/Users/me/dev/gallery")
        let hit = SearchRanking.rank("wall gal", in: [e]).first
        XCTAssertEqual(hit?.matches[.title], [0..<3, 8..<12])
        XCTAssertEqual(hit?.matches[.path], [14..<17])
    }

    func testAMatchOnTheRowNeedsNoSnippet() {
        let e = entry("gallery", branch: "feat/gallery")
        XCTAssertNil(SearchRanking.rank("gallery", in: [e]).first?.hint, "the name shows it")
    }

    func testAMatchOnlyWhereTheRowShowsNothingNamesItsPlace() {
        XCTAssertEqual(SearchRanking.rank("wall", in: [entry("a", branch: "feat/wall")]).first?.hint, .branch)
        XCTAssertEqual(SearchRanking.rank("blocked", in: [entry("a", note: "blocked by QA")]).first?.hint, .note)
        XCTAssertEqual(SearchRanking.rank("fix", in: [entry("a", task: "fix the build")]).first?.hint, .task)
        XCTAssertEqual(SearchRanking.rank("5576", in: [entry("a", pr: 5576)]).first?.hint, .pullRequest)
        XCTAssertEqual(SearchRanking.rank("dev", in: [entry("a", background: ["npm run dev"])]).first?.hint, .background)
    }

    func testTheHintIsForTheWordTheRowDoesNotShow() {
        // `gallery` is in the name; `qa` is only in the note — that is what needs saying.
        let e = entry("gallery", note: "waits for QA")
        XCTAssertEqual(SearchRanking.rank("gallery qa", in: [e]).first?.hint, .note)
    }

    func testRangesAreMergedAndOrdered() {
        XCTAssertEqual(SearchRanking.merged([5..<7, 0..<2, 1..<3, 7..<9]), [0..<3, 5..<9])
        XCTAssertEqual(SearchRanking.merged([]), [])
    }

    // The row shows the last two folders; highlights are into the whole path.
    func testRangesFollowTheShownPartOfAPath() {
        // "/Users/me/dev/gallery": the last 14 characters, "dev/gallery" is 11 — "gallery" is 14..<21.
        XCTAssertEqual(SearchRanking.shifted([14..<17], by: 11 - 21, within: 11), [4..<7])
        // A match in the part that is not shown is dropped, one that crosses the edge is cut.
        XCTAssertEqual(SearchRanking.shifted([1..<5, 8..<13], by: -10, within: 11), [0..<3])
        XCTAssertEqual(SearchRanking.shifted([], by: 3, within: 5), [])
    }

    func testHighlightMarksExactlyTheFoundCharacters() {
        let marked = Highlight.attributed("gallery wall", [0..<3, 8..<12])
        var strong = ""
        for run in marked.runs where run.inlinePresentationIntent == .stronglyEmphasized {
            strong += String(marked[run.range].characters)
        }
        XCTAssertEqual(strong, "galwall")
        // Ranges that reach past the text, or are empty, change nothing and do not crash.
        XCTAssertEqual(String(Highlight.attributed("abc", [2..<9, 5..<6, 1..<1]).characters), "abc")
    }

    func testNothingFoundIsNothing() {
        XCTAssertTrue(titles("zzzz", [entry("a"), entry("b", branch: "c")]).isEmpty)
    }
}

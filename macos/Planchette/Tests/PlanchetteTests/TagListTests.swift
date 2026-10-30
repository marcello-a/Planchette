import XCTest
@testable import Planchette

final class TagListTests: XCTestCase {
    // MARK: A name, as stored

    func testANameIsStoredTrimmedLowercaseOnOneLine() {
        XCTAssertEqual(TagList.normalized("  Review  "), "review")
        XCTAssertEqual(TagList.normalized("To   Test"), "to test")
        XCTAssertEqual(TagList.normalized("two\nlines"), "two lines")
        XCTAssertEqual(TagList.normalized("ÄÖÜ"), "äöü")
    }

    func testNothingLeftMeansNoTag() {
        XCTAssertNil(TagList.normalized(""))
        XCTAssertNil(TagList.normalized("   \n\t "))
    }

    func testALongNameIsCutWithoutATrailingSpace() throws {
        let long = String(repeating: "a", count: 23) + " " + String(repeating: "b", count: 10)
        let tag = try XCTUnwrap(TagList.normalized(long))
        XCTAssertLessThanOrEqual(tag.count, TagList.maxLength)
        XCTAssertEqual(tag, String(repeating: "a", count: 23), "the space the cut ends on goes too")
    }

    func testAListFromDiskKeepsOrderAndLosesDuplicatesAndEmptyNames() {
        XCTAssertEqual(TagList.sanitized(["b", "A", "", " a ", "c", "B"]), ["b", "a", "c"])
        XCTAssertEqual(TagList.sanitized([]), [])
    }

    // MARK: Editing the list

    func testAddingAppendsOnceAndIgnoresEmptyNames() {
        XCTAssertEqual(TagList.adding(" New ", to: ["a"]), ["a", "new"])
        XCTAssertEqual(TagList.adding("A", to: ["a"]), ["a"], "already there, whatever the case")
        XCTAssertEqual(TagList.adding("   ", to: ["a"]), ["a"])
    }

    func testRenamingKeepsThePlaceInTheList() {
        XCTAssertEqual(TagList.renaming("b", to: "Doing", in: ["a", "b", "c"]), ["a", "doing", "c"])
    }

    func testRenamingIntoAnExistingTagMergesThem() {
        XCTAssertEqual(TagList.renaming("c", to: "a", in: ["a", "b", "c"]), ["a", "b"])
    }

    func testRenamingWhatIsNotThereOrToNothingChangesNothing() {
        XCTAssertEqual(TagList.renaming("zzz", to: "x", in: ["a"]), ["a"])
        XCTAssertEqual(TagList.renaming("a", to: "  ", in: ["a"]), ["a"])
        XCTAssertEqual(TagList.renaming("a", to: "A", in: ["a"]), ["a"])
    }

    func testRemovingTakesOutOnlyThatTag() {
        XCTAssertEqual(TagList.removing("b", from: ["a", "b", "c"]), ["a", "c"])
        XCTAssertEqual(TagList.removing("x", from: ["a"]), ["a"])
    }

    // MARK: What it does to a terminal

    func testATerminalsTagIsRenamedInPlace() {
        XCTAssertEqual(TagList.renamed(["wip", "review"], from: "wip", to: "doing"), ["doing", "review"])
    }

    func testATerminalThatCarriedBothEndsWithOne() {
        XCTAssertEqual(TagList.renamed(["wip", "doing", "review"], from: "wip", to: "doing"), ["doing", "review"])
        XCTAssertEqual(TagList.renamed(["doing", "wip"], from: "wip", to: "doing"), ["doing"])
    }

    func testARenameLeavesOtherTerminalsAlone() {
        XCTAssertEqual(TagList.renamed(["review"], from: "wip", to: "doing"), ["review"])
        XCTAssertEqual(TagList.renamed([], from: "wip", to: "doing"), [])
    }

    func testADeleteTakesTheTagOffATerminal() {
        XCTAssertEqual(TagList.removed(["wip", "review"], "wip"), ["review"])
        XCTAssertEqual(TagList.removed(["review"], "wip"), ["review"])
    }

    // MARK: What the menu offers

    func testStraysAreTheTagsOnTerminalsThatTheListLacks() {
        let terminals = [["wip", "zebra"], ["apple", "wip"], []]
        XCTAssertEqual(TagList.strays(list: ["wip"], inUse: terminals), ["apple", "zebra"])
        XCTAssertEqual(TagList.strays(list: ["wip", "apple", "zebra"], inUse: terminals), [])
    }

    func testTheMenuIsTheListThenTheStrays() {
        XCTAssertEqual(TagList.known(list: ["z", "a"], inUse: [["m", "a"], ["b"]]), ["z", "a", "b", "m"])
    }

    func testUsageCountsTerminalsNotTags() {
        XCTAssertEqual(TagList.usage(of: "wip", in: [["wip"], ["wip", "review"], ["review"], []]), 2)
        XCTAssertEqual(TagList.usage(of: "none", in: [["wip"]]), 0)
    }

    func testTheDefaultsAreTheFormerSuggestions() {
        XCTAssertEqual(TagList.defaults, ["to test", "review", "blocked", "wip"])
        XCTAssertEqual(TagList.sanitized(TagList.defaults), TagList.defaults, "the defaults are stored form")
    }

    // MARK: Saved arrangements follow a rename

    func testAnArrangementIsRetaggedInEveryTerminalOfEveryProject() {
        var first = PresetProject(name: "one")
        var a = PresetTerminal(workingDirectory: "/a"); a.tags = ["wip", "review"]
        var b = PresetTerminal(workingDirectory: "/b"); b.tags = ["wip"]
        first.terminals = [a, b]
        var second = PresetProject(name: "two")
        var c = PresetTerminal(workingDirectory: "/c"); c.tags = ["blocked"]
        second.terminals = [c]
        let preset = Preset(name: "work", projects: [first, second])

        let renamed = preset.retagged { TagList.renamed($0, from: "wip", to: "doing") }
        XCTAssertEqual(renamed.projects[0].terminals.map(\.tags), [["doing", "review"], ["doing"]])
        XCTAssertEqual(renamed.projects[1].terminals.map(\.tags), [["blocked"]])
        XCTAssertEqual(renamed.id, preset.id)
        XCTAssertEqual(renamed.name, "work")
        XCTAssertEqual(renamed.projects[0].terminals.map(\.workingDirectory), ["/a", "/b"])
        XCTAssertEqual(preset.retagged { $0 }, preset, "no change is no change")
    }
}

final class TagBookTests: XCTestCase {
    private let one = UUID(), two = UUID(), three = UUID()

    private func book() -> TagBook {
        var project = PresetProject(name: "p")
        var terminal = PresetTerminal(workingDirectory: "/a")
        terminal.tags = ["wip", "review"]
        project.terminals = [terminal]
        return TagBook(
            list: ["to test", "review", "wip"],
            terminals: [one: ["wip", "review"], two: ["wip", "urgent"], three: []],
            presets: [Preset(name: "work", projects: [project])])
    }

    func testARenameReachesTheListEveryTerminalAndEveryArrangement() {
        let renamed = book().renaming("wip", to: " Doing ")
        XCTAssertEqual(renamed.list, ["to test", "review", "doing"])
        XCTAssertEqual(renamed.terminals[one], ["doing", "review"])
        XCTAssertEqual(renamed.terminals[two], ["doing", "urgent"])
        XCTAssertEqual(renamed.terminals[three], [])
        XCTAssertEqual(renamed.presets[0].projects[0].terminals[0].tags, ["doing", "review"])
    }

    func testRenamingIntoAnExistingTagMergesOnEveryTerminal() {
        let merged = book().renaming("wip", to: "review")
        XCTAssertEqual(merged.list, ["to test", "review"])
        XCTAssertEqual(merged.terminals[one], ["review"], "it carried both; it keeps one")
        XCTAssertEqual(merged.terminals[two], ["review", "urgent"])
    }

    func testARenameToNothingOrToTheSameNameChangesNothing() {
        let base = book()   // one book: every call makes a new arrangement id
        XCTAssertEqual(base.renaming("wip", to: "   "), base)
        XCTAssertEqual(base.renaming("wip", to: "WIP"), base)
    }

    func testATagThatIsNotThereLeavesTheListAlone() {
        // A stray (on a terminal, not on the list) can still be renamed on the terminals.
        let renamed = book().renaming("urgent", to: "soon")
        XCTAssertEqual(renamed.list, book().list)
        XCTAssertEqual(renamed.terminals[two], ["wip", "soon"])
    }

    func testADeleteComesOffEveryTerminalAndArrangement() {
        let deleted = book().deleting("wip")
        XCTAssertEqual(deleted.list, ["to test", "review"])
        XCTAssertEqual(deleted.terminals[one], ["review"])
        XCTAssertEqual(deleted.terminals[two], ["urgent"])
        XCTAssertEqual(deleted.presets[0].projects[0].terminals[0].tags, ["review"])
    }

    func testDeletingWhatNobodyHasChangesNothing() {
        let base = book()
        XCTAssertEqual(base.deleting("nope"), base)
    }
}

final class TagListPersistenceTests: XCTestCase {
    private func decode(_ json: String) throws -> PersistedState {
        try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
    }

    func testAStateThatNeverHadTheKeyGetsTheSuggestions() throws {
        XCTAssertEqual(try decode("{}").tagList, TagList.defaults)
    }

    func testAnEditedListSurvivesASaveAndALoad() throws {
        var state = try decode("{}")
        state.tagList = ["urgent", "later"]
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.tagList, ["urgent", "later"])
    }

    func testAnEmptyListIsAChoiceAndStaysEmpty() throws {
        XCTAssertEqual(try decode(#"{"tagList":[]}"#).tagList, [])
    }

    func testADamagedListIsCleanedWhenItIsRead() throws {
        XCTAssertEqual(try decode(#"{"tagList":["a","","A","b "]}"#).tagList, ["a", "b"])
    }
}

final class SidebarDetailGroupTests: XCTestCase {
    func testEveryDetailIsInAGroupAndEveryGroupHasDetails() {
        for group in SidebarDetailGroup.allCases {
            XCTAssertFalse(SidebarDetail.allCases.filter { $0.group == group }.isEmpty, "\(group)")
        }
        let grouped = SidebarDetailGroup.allCases.flatMap { group in
            SidebarDetail.allCases.filter { $0.group == group }
        }
        XCTAssertEqual(Set(grouped), Set(SidebarDetail.allCases))
        XCTAssertEqual(grouped.count, SidebarDetail.allCases.count, "no detail in two groups")
    }

    func testOnlyTheAttentionCountsBelongToTheProjectRow() {
        let project = SidebarDetail.allCases.filter { !$0.group.isTerminal }
        XCTAssertEqual(project, [.attentionCounts])
    }

    func testTheTerminalPageHasFourGroups() {
        XCTAssertEqual(SidebarDetailGroup.terminalGroups, [.location, .activity, .marks, .claude])
    }

    func testTheOptInDetailsAreTheClaudeGroup() {
        // The footer under that group explains why they start off. The one other: "also main
        // and master" refines the branch — the trunk says nothing about a checkout.
        for detail in SidebarDetail.allCases where detail != .trunkBranch {
            XCTAssertEqual(!detail.defaultOn, detail.group == .claude, "\(detail)")
        }
        XCTAssertFalse(SidebarDetail.trunkBranch.defaultOn)
    }

    func testEveryTextOfTheNewPagesIsTranslated() {
        let keys: [LKey] = [
            .projectPanelPageTerminals, .projectPanelBehavior, .projectPanelIntro, .projectPanelOptionalHelp,
            .sidebarGroupLocation, .sidebarGroupActivity, .sidebarGroupMarks, .sidebarGroupClaude, .sidebarGroupProjectRow,
            .tagEditorTitle, .tagEditorHelp, .tagEditorEmpty, .tagEditorNewPlaceholder, .tagEditorAdd, .tagUsage,
            .tagUnused, .tagDeleteHelp, .tagDeleteTitle, .tagDeleteBody, .tagDeleteConfirm, .tagStraysTitle,
            .tagStraysHelp, .tagKeep, .tagRestoreDefaults, .tagRestoreDefaultsHelp,
        ]
        for language in AppLanguage.allCases {
            L10n.current = language
            for key in keys {
                XCTAssertNotEqual(L10n.t(key), key.rawValue, "\(language) \(key)")
            }
            for group in SidebarDetailGroup.allCases {
                XCTAssertNotEqual(L10n.t(group.titleKey), group.titleKey.rawValue, "\(language) \(group)")
            }
        }
        L10n.current = .en
    }

    func testTheFormatsTakeTheirArguments() {
        // %d and %@ must survive translation, in every language, or the line prints a raw specifier.
        for language in AppLanguage.allCases {
            L10n.current = language
            XCTAssertFalse(L10n.t(.tagUsage, 3).contains("%"), "\(language)")
            XCTAssertTrue(L10n.t(.tagUsage, 3).contains("3"), "\(language)")
            XCTAssertFalse(L10n.t(.tagDeleteTitle, "wip").contains("%"), "\(language)")
            XCTAssertTrue(L10n.t(.tagDeleteTitle, "wip").contains("wip"), "\(language)")
            XCTAssertTrue(L10n.t(.tagDeleteBody, 4).contains("4"), "\(language)")
            XCTAssertTrue(L10n.t(.tagRestoreDefaultsHelp, "to test, review").contains("to test, review"), "\(language)")
        }
        L10n.current = .en
    }
}

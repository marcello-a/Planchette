import XCTest
@testable import Planchette

final class CompactProjectRowTests: XCTestCase {
    func testOnlyAProjectOfOneTerminalIsMerged() {
        var details = SidebarDetails()
        XCTAssertTrue(details.merges(terminalCount: 1), "on by default")
        XCTAssertFalse(details.merges(terminalCount: 2), "a second terminal makes it a list again")
        XCTAssertFalse(details.merges(terminalCount: 0))
        details.mergesSingleTerminal = false
        XCTAssertFalse(details.merges(terminalCount: 1))
    }

    func testATrunkBranchShowsOnlyWhenAskedFor() {
        var details = SidebarDetails()
        XCTAssertTrue(details.showsBranch("marcello/feat/NIE-2008-gallery"))
        for trunk in ["main", "master", "develop", "trunk"] {
            XCTAssertFalse(details.showsBranch(trunk), trunk)
        }
        details.set(.trunkBranch, true)
        XCTAssertTrue(details.showsBranch("main"))
        details.set(.branch, false)
        XCTAssertFalse(details.showsBranch("main"), "the branch switch is the master switch")
        XCTAssertFalse(details.showsBranch("feat/x"))
    }

    func testThePathShowsOnlyWhenItSaysSomethingTheNameDoesNot() {
        let details = SidebarDetails()
        XCTAssertFalse(details.showsPath(directory: "/dev/mp/designer-library", projectName: "designer-library"))
        XCTAssertFalse(details.showsPath(directory: "/dev/mp/Designer-Library", projectName: "designer-library"),
                       "case does not make it news")
        XCTAssertTrue(details.showsPath(directory: "/dev/mp/designer-library.worktrees/NIE-2008",
                                        projectName: "designer-library"))
        var off = details
        off.set(.path, false)
        XCTAssertFalse(off.showsPath(directory: "/dev/elsewhere", projectName: "designer-library"))
    }

    func testStandardIsTheDefaultsSoExistingUsersLandOnIt() {
        XCTAssertEqual(SidebarDetails().level, .standard)
        var details = SidebarDetails()
        details.set(.tags, false)
        XCTAssertNil(details.level, "a switch of one's own is Custom")
    }

    func testEachPresetSetsTheSwitchesAndIsRecognisedAgain() {
        for level in SidebarDetailLevel.allCases {
            var details = SidebarDetails()
            details.branchTrim = .front
            details.apply(level)
            XCTAssertEqual(details.level, level)
            XCTAssertEqual(details.branchTrim, .front, "a preset leaves the choices that are not switches")
        }
        var minimal = SidebarDetails()
        minimal.apply(.minimal)
        XCTAssertFalse(minimal.shows(.task))
        XCTAssertFalse(minimal.shows(.branch))
        XCTAssertTrue(minimal.shows(.pullRequest))
        XCTAssertTrue(minimal.shows(.age))
        var all = SidebarDetails()
        all.apply(.everything)
        XCTAssertTrue(SidebarDetail.allCases.allSatisfy(all.shows))
        all.apply(.standard)
        XCTAssertEqual(all, SidebarDetails(), "back to Standard stores nothing")
    }

    func testTheLayoutSwitchSurvivesASaveAndOldStatesGetItOn() throws {
        var details = SidebarDetails()
        details.mergesSingleTerminal = false
        let decoded = try JSONDecoder().decode(SidebarDetails.self, from: JSONEncoder().encode(details))
        XCTAssertFalse(decoded.mergesSingleTerminal)
        let old = try JSONDecoder().decode(SidebarDetails.self, from: Data(#"{"overrides":{"tags":false}}"#.utf8))
        XCTAssertTrue(old.mergesSingleTerminal, "a state from before the switch gets the merged row")
        XCTAssertFalse(old.shows(.tags), "and keeps its own switches")
    }

    func testEveryDetailHasItsStrings() {
        L10n.current = .en
        for detail in SidebarDetail.allCases {
            XCTAssertNotEqual(L10n.t(detail.titleKey), detail.titleKey.rawValue)
            XCTAssertNotEqual(L10n.t(detail.helpKey), detail.helpKey.rawValue)
        }
        for level in SidebarDetailLevel.allCases {
            XCTAssertNotEqual(L10n.t(level.titleKey), level.titleKey.rawValue)
        }
    }
}

final class TreeLinesTests: XCTestCase {
    func testAFolderLineTeesToEachProjectAndBendsAtTheLast() {
        XCTAssertEqual(TreeLines.folderLine(index: 0, of: 3, isProjectRow: true), .tee)
        XCTAssertEqual(TreeLines.folderLine(index: 2, of: 3, isProjectRow: true), .corner)
        XCTAssertEqual(TreeLines.folderLine(index: 0, of: 1, isProjectRow: true), .corner)
    }

    func testTheFolderLinePassesTheTerminalsOfAllButTheLastProject() {
        XCTAssertEqual(TreeLines.folderLine(index: 0, of: 3, isProjectRow: false), .through)
        XCTAssertNil(TreeLines.folderLine(index: 2, of: 3, isProjectRow: false),
                     "below the last project the folder line has ended")
    }

    func testAProjectLineReachesEveryTerminal() {
        XCTAssertEqual(TreeLines.projectLine(index: 0, of: 3), .tee)
        XCTAssertEqual(TreeLines.projectLine(index: 1, of: 3), .tee)
        XCTAssertEqual(TreeLines.projectLine(index: 2, of: 3), .corner)
    }

    func testTheProjectLineHangsRightOfTheFolderLine() {
        XCTAssertLessThan(TreeLines.x(.folder), TreeLines.x(.project))
        XCTAssertLessThan(TreeLines.stubEnd(.folder), TreeLines.x(.project))
    }
}

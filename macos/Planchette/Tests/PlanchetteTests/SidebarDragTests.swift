import XCTest
@testable import Planchette

final class SidebarDragItemTests: XCTestCase {
    func testEveryKindSurvivesTheTrip() {
        let a = UUID(), b = UUID()
        for item in [SidebarDragItem.projects([a, b]), .terminal(a), .folder(b)] {
            XCTAssertEqual(SidebarDragItem(encoded: item.encoded), item)
        }
    }

    func testATerminalTravelsAsAPaneSoTheTabBarTakesIt() {
        let id = UUID()
        XCTAssertEqual(TabDragItem(encoded: SidebarDragItem.terminal(id).encoded), .pane(id))
        XCTAssertEqual(SidebarDragItem(encoded: TabDragItem.tab(id).encoded), .terminal(id),
                       "a tab dragged into the panel is its first terminal")
    }

    func testItIsJSONNeverText() {
        let data = SidebarDragItem.projects([UUID()]).encoded
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data), "a terminal types text, not JSON")
        XCTAssertNil(TabDragItem(encoded: data), "the tab bar lets a project drag go")
        XCTAssertNil(SidebarDragItem(encoded: Data(UUID().uuidString.utf8)), "plain text is not a drag of ours")
        XCTAssertNil(SidebarDragItem(encoded: Data(#"{"planchetteProjects":"nonsense"}"#.utf8)))
    }
}

final class FolderOrderTests: XCTestCase {
    private func window(_ names: [String]) -> (WindowModel, [UUID]) {
        var window = WindowModel()
        var ids: [UUID] = []
        for name in names {
            var folder = ProjectFolder(name: name)
            let project = UUID()
            folder.groupIDs = [project]
            window.folders.append(folder)
            window.groupIDs.append(project)
            ids.append(folder.id)
        }
        return (window, ids)
    }

    func testAFolderMovesBeforeAnotherAndToTheEnd() {
        var (w, ids) = window(["a", "b", "c"])
        w.moveFolder(ids[2], before: ids[0])
        XCTAssertEqual(w.folders.map(\.name), ["c", "a", "b"])
        w.moveFolder(ids[2], before: nil)
        XCTAssertEqual(w.folders.map(\.name), ["a", "b", "c"])
    }

    func testTheProjectsFollowTheirFolders() {
        var (w, ids) = window(["a", "b"])
        let projectsOfB = w.folders[1].groupIDs
        w.moveFolder(ids[1], before: ids[0])
        XCTAssertEqual(Array(w.groupIDs.prefix(1)), projectsOfB, "filed projects stand in folder order")
    }

    func testOntoItselfChangesNothing() {
        var (w, ids) = window(["a", "b"])
        let before = w
        w.moveFolder(ids[0], before: ids[0])
        w.moveFolder(ids[0], before: ids[1])
        XCTAssertEqual(w.folders.map(\.id), before.folders.map(\.id))
    }
}

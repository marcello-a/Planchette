import XCTest
@testable import Planchette

/// The tab strip as a pure model: split trees under tabs, and every way of rearranging them.
final class TabSplitTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func leaf(_ id: UUID) -> SplitLayout { .leaf(id) }

    /// What must hold after every operation, whatever it was.
    private func assertWellFormed(
        _ tabs: [SplitLayout], ids: [UUID], _ note: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            TabStrip.order(tabs).sorted { $0.uuidString < $1.uuidString },
            ids.sorted { $0.uuidString < $1.uuidString },
            "every terminal is in exactly one place \(note)", file: file, line: line)
        for tab in tabs {
            XCTAssertEqual(tab, tab.normalized(), "a tab is normalised \(note)", file: file, line: line)
            XCTAssertFalse(tab.leaves.isEmpty, "no empty tab \(note)", file: file, line: line)
        }
    }

    // MARK: synced

    func testNoStoredStripIsOneTabPerTerminal() {
        XCTAssertEqual(TabStrip.synced(nil, to: [a, b, c]), [leaf(a), leaf(b), leaf(c)])
        XCTAssertEqual(TabStrip.synced(nil, to: []), [])
    }

    func testANewTerminalGetsATabAtTheEnd() {
        let stored: [SplitLayout] = [.row([leaf(a), leaf(b)])]
        XCTAssertEqual(
            TabStrip.synced(stored, to: [a, b, c]), [.row([leaf(a), leaf(b)]), leaf(c)])
    }

    func testAClosedTerminalLeavesItsTabAndAnEmptyTabGoes() {
        let stored: [SplitLayout] = [.row([leaf(a), leaf(b)]), leaf(c)]
        XCTAssertEqual(TabStrip.synced(stored, to: [a, c]), [leaf(a), leaf(c)])
        XCTAssertEqual(TabStrip.synced(stored, to: [a, b]), [.row([leaf(a), leaf(b)])])
    }

    func testATerminalInTwoPlacesStaysInTheFirst() {
        let stored: [SplitLayout] = [.row([leaf(a), leaf(b)]), .row([leaf(b), leaf(c)])]
        let synced = TabStrip.synced(stored, to: [a, b, c])
        XCTAssertEqual(synced, [.row([leaf(a), leaf(b)]), leaf(c)])
        assertWellFormed(synced, ids: [a, b, c])
        // …and inside one tab.
        let twice = TabStrip.synced([.row([leaf(a), leaf(a), leaf(b)])], to: [a, b])
        XCTAssertEqual(twice, [.row([leaf(a), leaf(b)])])
    }

    func testSyncingRepairsAnUnnormalisedTree() {
        let stored: [SplitLayout] = [.row([.row([leaf(a), leaf(b)]), .column([leaf(c)])])]
        let synced = TabStrip.synced(stored, to: [a, b, c])
        XCTAssertEqual(synced, [.row([leaf(a), leaf(b), leaf(c)])])
    }

    // MARK: moveTab

    func testMovingATabBeforeAnother() {
        let tabs = [leaf(a), leaf(b), leaf(c), leaf(d)]
        XCTAssertEqual(TabStrip.moveTab(from: 3, before: 1, in: tabs), [leaf(a), leaf(d), leaf(b), leaf(c)])
        XCTAssertEqual(TabStrip.moveTab(from: 0, before: 3, in: tabs), [leaf(b), leaf(c), leaf(a), leaf(d)])
        XCTAssertEqual(TabStrip.moveTab(from: 0, before: 4, in: tabs), [leaf(b), leaf(c), leaf(d), leaf(a)],
                       "the end of the strip")
    }

    func testMovingATabToWhereItStandsIsNothing() {
        let tabs = [leaf(a), leaf(b), leaf(c)]
        XCTAssertNil(TabStrip.moveTab(from: 1, before: 1, in: tabs))
        XCTAssertNil(TabStrip.moveTab(from: 1, before: 2, in: tabs), "just after itself is the same place")
        XCTAssertNil(TabStrip.moveTab(from: 2, before: 3, in: tabs))
        XCTAssertNil(TabStrip.moveTab(from: 5, before: 0, in: tabs))
        XCTAssertNil(TabStrip.moveTab(from: 0, before: 9, in: tabs))
        XCTAssertNil(TabStrip.moveTab(from: -1, before: 0, in: tabs))
    }

    func testMovingASplitTabKeepsItsPanes() {
        let split: SplitLayout = .row([leaf(b), leaf(c)])
        let moved = TabStrip.moveTab(from: 1, before: 0, in: [leaf(a), split])
        XCTAssertEqual(moved, [split, leaf(a)])
    }

    // MARK: dropTab — a tab onto the content of another

    func testDroppingATabOnTheRightEdgeSplitsBesideThePane() {
        let tabs = [leaf(a), leaf(b), leaf(c)]
        let result = TabStrip.dropTab(at: 2, onto: a, edge: .right, in: tabs)
        XCTAssertEqual(result, [.row([leaf(a), leaf(c)]), leaf(b)])
        assertWellFormed(result!, ids: [a, b, c])
    }

    func testDroppingATabOnEveryEdge() {
        let tabs = [leaf(a), leaf(b)]
        XCTAssertEqual(TabStrip.dropTab(at: 1, onto: a, edge: .left, in: tabs), [.row([leaf(b), leaf(a)])])
        XCTAssertEqual(TabStrip.dropTab(at: 1, onto: a, edge: .right, in: tabs), [.row([leaf(a), leaf(b)])])
        XCTAssertEqual(TabStrip.dropTab(at: 1, onto: a, edge: .top, in: tabs), [.column([leaf(b), leaf(a)])])
        XCTAssertEqual(TabStrip.dropTab(at: 1, onto: a, edge: .bottom, in: tabs), [.column([leaf(a), leaf(b)])])
    }

    func testDroppingASplitTabBringsAllItsPanesWithTheirArrangement() {
        let tabs: [SplitLayout] = [leaf(a), .column([leaf(b), leaf(c)])]
        let result = TabStrip.dropTab(at: 1, onto: a, edge: .right, in: tabs)
        XCTAssertEqual(result, [.row([leaf(a), .column([leaf(b), leaf(c)])])])
        assertWellFormed(result!, ids: [a, b, c])
    }

    func testDroppingARowTabOnARowEdgeFlattens() {
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b)]), .row([leaf(c), leaf(d)])]
        let result = TabStrip.dropTab(at: 1, onto: b, edge: .right, in: tabs)
        XCTAssertEqual(result, [.row([leaf(a), leaf(b), leaf(c), leaf(d)])])
    }

    func testDroppingATabOnItselfOrNowhereIsNothing() {
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b)]), leaf(c)]
        XCTAssertNil(TabStrip.dropTab(at: 0, onto: a, edge: .right, in: tabs), "onto its own pane")
        XCTAssertNil(TabStrip.dropTab(at: 0, onto: b, edge: .left, in: tabs), "onto its own pane")
        XCTAssertNil(TabStrip.dropTab(at: 1, onto: UUID(), edge: .left, in: tabs), "onto a stranger")
        XCTAssertNil(TabStrip.dropTab(at: 7, onto: a, edge: .left, in: tabs))
    }

    func testDroppingABackTabOnAnEarlierTabAndTheReverse() {
        let tabs = [leaf(a), leaf(b), leaf(c), leaf(d)]
        // the dragged tab is before the target
        let forward = TabStrip.dropTab(at: 0, onto: d, edge: .bottom, in: tabs)
        XCTAssertEqual(forward, [leaf(b), leaf(c), .column([leaf(d), leaf(a)])])
        // the dragged tab is after the target
        let backward = TabStrip.dropTab(at: 3, onto: b, edge: .top, in: tabs)
        XCTAssertEqual(backward, [leaf(a), .column([leaf(d), leaf(b)]), leaf(c)])
    }

    // MARK: dropPane

    func testAPaneJoinsAnotherTabAndItsOldTabGoesWhenEmpty() {
        let tabs = [leaf(a), leaf(b), leaf(c)]
        let result = TabStrip.dropPane(c, onto: a, edge: .right, in: tabs)
        XCTAssertEqual(result, [.row([leaf(a), leaf(c)]), leaf(b)])
        assertWellFormed(result!, ids: [a, b, c])
    }

    func testAPaneLeavingASplitTabLeavesTheOthersTogether() {
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b), leaf(c)]), leaf(d)]
        let result = TabStrip.dropPane(b, onto: d, edge: .bottom, in: tabs)
        XCTAssertEqual(result, [.row([leaf(a), leaf(c)]), .column([leaf(d), leaf(b)])])
        assertWellFormed(result!, ids: [a, b, c, d])
    }

    func testRearrangingPanesInsideOneTab() {
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b)])]
        XCTAssertEqual(
            TabStrip.dropPane(a, onto: b, edge: .bottom, in: tabs), [.column([leaf(b), leaf(a)])])
        XCTAssertEqual(
            TabStrip.dropPane(b, onto: a, edge: .left, in: tabs), [.row([leaf(b), leaf(a)])])
    }

    func testADropThatChangesNothingIsRefused() {
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b)])]
        XCTAssertNil(TabStrip.dropPane(b, onto: a, edge: .right, in: tabs), "b is right of a already")
        XCTAssertNil(TabStrip.dropPane(a, onto: b, edge: .left, in: tabs), "a is left of b already")
        XCTAssertNil(TabStrip.dropPane(a, onto: a, edge: .left, in: tabs), "onto itself")
        XCTAssertNil(TabStrip.dropPane(a, onto: UUID(), edge: .left, in: tabs))
        XCTAssertNil(TabStrip.dropPane(UUID(), onto: a, edge: .left, in: tabs))
    }

    func testAPaneDroppedOnAnotherTabsPaneInANestedTree() {
        let tabs: [SplitLayout] = [.row([leaf(a), .column([leaf(b), leaf(c)])]), leaf(d)]
        let result = TabStrip.dropPane(d, onto: c, edge: .right, in: tabs)
        XCTAssertEqual(result, [.row([leaf(a), .column([leaf(b), .row([leaf(c), leaf(d)])])])])
        assertWellFormed(result!, ids: [a, b, c, d])
    }

    // MARK: extractPane — a pane back out to a tab of its own

    func testExtractingAPaneMakesATabAtTheGivenPlace() {
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b)]), leaf(c)]
        XCTAssertEqual(TabStrip.extractPane(b, before: 2, in: tabs), [leaf(a), leaf(c), leaf(b)])
        XCTAssertEqual(TabStrip.extractPane(b, before: 0, in: tabs), [leaf(b), leaf(a), leaf(c)])
        XCTAssertEqual(TabStrip.extractPane(b, before: 1, in: tabs), [leaf(a), leaf(b), leaf(c)])
    }

    func testExtractingFromAThreeWaySplitKeepsTheRest() {
        let tabs: [SplitLayout] = [.row([leaf(a), .column([leaf(b), leaf(c)])])]
        let result = TabStrip.extractPane(b, before: 1, in: tabs)
        XCTAssertEqual(result, [.row([leaf(a), leaf(c)]), leaf(b)])
        assertWellFormed(result!, ids: [a, b, c])
    }

    func testExtractingAPaneThatIsAloneJustMovesItsTab() {
        let tabs = [leaf(a), leaf(b), leaf(c)]
        XCTAssertEqual(TabStrip.extractPane(c, before: 0, in: tabs), [leaf(c), leaf(a), leaf(b)])
        XCTAssertNil(TabStrip.extractPane(b, before: 1, in: tabs), "where it stands")
        XCTAssertNil(TabStrip.extractPane(b, before: 9, in: tabs))
        XCTAssertNil(TabStrip.extractPane(UUID(), before: 0, in: tabs))
    }

    // MARK: combined / separated

    func testCombiningTabsIntoOneView() {
        XCTAssertNil(TabStrip.combined([leaf(a)]))
        XCTAssertNil(TabStrip.combined([]))
        XCTAssertEqual(TabStrip.combined([leaf(a), leaf(b)]), [.row([leaf(a), leaf(b)])])
        XCTAssertEqual(
            TabStrip.combined([leaf(a), leaf(b), leaf(c), leaf(d)]),
            [.column([.row([leaf(a), leaf(b)]), .row([leaf(c), leaf(d)])])], "four read as two over two")
        XCTAssertEqual(
            TabStrip.combined([leaf(a), leaf(b), leaf(c)]),
            [.column([.row([leaf(a), leaf(b)]), leaf(c)])])
    }

    func testCombiningKeepsEachTabsArrangement() {
        let tabs: [SplitLayout] = [.column([leaf(a), leaf(b)]), leaf(c)]
        let result = TabStrip.combined(tabs)
        XCTAssertEqual(result, [.row([.column([leaf(a), leaf(b)]), leaf(c)])])
        assertWellFormed(result!, ids: [a, b, c])
    }

    func testCombiningManyTabsKeepsEveryTerminal() {
        for n in 2...12 {
            let ids = (0..<n).map { _ in UUID() }
            let result = TabStrip.combined(ids.map { .leaf($0) })
            XCTAssertEqual(result?.count, 1, "\(n)")
            assertWellFormed(result ?? [], ids: ids, "\(n) tabs")
            XCTAssertEqual(result?.first?.leaves, ids, "the order is kept, \(n) tabs")
        }
    }

    func testSeparatingEveryPaneIntoATab() {
        XCTAssertNil(TabStrip.separated([leaf(a), leaf(b)]), "nothing is split")
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b)]), .column([leaf(c), leaf(d)])]
        XCTAssertEqual(TabStrip.separated(tabs), [leaf(a), leaf(b), leaf(c), leaf(d)])
    }

    // MARK: removing / successor

    func testRemovingATerminal() {
        let tabs: [SplitLayout] = [.row([leaf(a), leaf(b)]), leaf(c)]
        XCTAssertEqual(TabStrip.removing(a, from: tabs), [leaf(b), leaf(c)])
        XCTAssertEqual(TabStrip.removing(c, from: tabs), [.row([leaf(a), leaf(b)])])
        XCTAssertEqual(TabStrip.removing(UUID(), from: tabs), tabs)
        XCTAssertEqual(TabStrip.removing(c, from: [leaf(c)]), [])
    }

    func testTheSuccessorOfAClosedTerminal() {
        let tabs: [SplitLayout] = [leaf(a), .row([leaf(b), leaf(c)]), leaf(d)]
        XCTAssertEqual(TabStrip.successor(of: b, in: tabs), c, "the next pane in its tab")
        XCTAssertEqual(TabStrip.successor(of: c, in: tabs), b, "the last pane takes the one before")
        XCTAssertEqual(TabStrip.successor(of: a, in: tabs), b, "a lone tab hands over to the right")
        XCTAssertEqual(TabStrip.successor(of: d, in: tabs), b, "the last tab hands over to the left")
        XCTAssertNil(TabStrip.successor(of: a, in: [leaf(a)]))
        XCTAssertNil(TabStrip.successor(of: UUID(), in: tabs))
    }

    func testClosingAWholeTabOnePaneAtATimeEndsInTheNeighbourTab() {
        var tabs: [SplitLayout] = [leaf(a), .row([leaf(b), leaf(c)]), leaf(d)]
        var current = b
        for id in [b, c] {
            let next = TabStrip.successor(of: id, in: tabs)
            tabs = TabStrip.removing(id, from: tabs)
            if let next { current = next }
        }
        XCTAssertEqual(tabs, [leaf(a), leaf(d)])
        XCTAssertEqual(current, d)
    }

    // MARK: Many operations at random — the invariants hold after every single one

    /// A tiny deterministic generator, so a failure names the seed that reproduces it.
    private struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
    }

    func testRandomOperationsKeepTheStripWellFormed() {
        let edges: [LayoutEdge] = [.top, .bottom, .left, .right]
        var applied = 0, withSplits = 0
        for seed in 1...200 {
            var rng = Lcg(state: UInt64(seed))
            let count = 1 + rng.next(7)
            let ids = (0..<count).map { _ in UUID() }
            var tabs = TabStrip.synced(nil, to: ids)
            for step in 0..<60 {
                let note = "seed \(seed) step \(step)"
                let leaves = TabStrip.order(tabs)
                let edge = edges[rng.next(4)]
                var result: [SplitLayout]?
                switch rng.next(7) {
                case 0: result = TabStrip.moveTab(from: rng.next(tabs.count), before: rng.next(tabs.count + 1), in: tabs)
                case 1: result = TabStrip.dropTab(at: rng.next(tabs.count), onto: leaves[rng.next(leaves.count)], edge: edge, in: tabs)
                case 2, 3: result = TabStrip.dropPane(leaves[rng.next(leaves.count)], onto: leaves[rng.next(leaves.count)], edge: edge, in: tabs)
                case 4: result = TabStrip.extractPane(leaves[rng.next(leaves.count)], before: rng.next(tabs.count + 1), in: tabs)
                case 5: result = TabStrip.combined(tabs)
                default: result = TabStrip.separated(tabs)
                }
                if let result {
                    XCTAssertNotEqual(result, tabs, "an operation that answers must have changed something, \(note)")
                    assertWellFormed(result, ids: ids, note)
                    tabs = result
                    applied += 1
                    if tabs.contains(where: { $0.leaves.count > 1 }) { withSplits += 1 }
                }
                // syncing a well-formed strip changes nothing
                XCTAssertEqual(TabStrip.synced(tabs, to: TabStrip.order(tabs)), tabs, note)
            }
            // …and closing everything one by one ends empty, with a successor each time.
            while !tabs.isEmpty {
                let all = TabStrip.order(tabs)
                let victim = all[rng.next(all.count)]
                let rest = TabStrip.removing(victim, from: tabs)
                if let next = TabStrip.successor(of: victim, in: tabs) {
                    XCTAssertTrue(TabStrip.order(rest).contains(next), "the successor survives, seed \(seed)")
                } else {
                    XCTAssertTrue(rest.isEmpty, "no successor means nothing is left, seed \(seed)")
                }
                assertWellFormed(rest, ids: TabStrip.order(tabs).filter { $0 != victim }, "closing, seed \(seed)")
                tabs = rest
            }
        }
        XCTAssertGreaterThan(applied, 2000, "the random walk must really change the strip")
        XCTAssertGreaterThan(withSplits, 1000, "…and spend its time in split tabs")
    }
}

final class TabDragItemTests: XCTestCase {
    func testRoundTrip() {
        let id = UUID()
        XCTAssertEqual(TabDragItem(encoded: TabDragItem.tab(id).encoded), .tab(id))
        XCTAssertEqual(TabDragItem(encoded: TabDragItem.pane(id).encoded), .pane(id))
    }

    func testItIsJSONAndNeverText() {
        // The terminal types dropped text at the prompt: the payload must not be what it takes.
        XCTAssertEqual(TabDragItem.typeIdentifier, "public.json")
        let text = String(decoding: TabDragItem.tab(UUID()).encoded, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: TabDragItem.pane(UUID()).encoded))
    }

    func testAnythingElseIsNotAnItem() {
        let id = UUID().uuidString
        XCTAssertNil(TabDragItem(encoded: Data("hello".utf8)))
        XCTAssertNil(TabDragItem(encoded: Data(#"{"planchetteTab":"not-a-uuid"}"#.utf8)))
        XCTAssertNil(TabDragItem(encoded: Data(#"{"window":"\#(id)"}"#.utf8)))
        XCTAssertNil(TabDragItem(encoded: Data(#"{"planchetteTab":"\#(id)","planchettePane":"\#(id)"}"#.utf8)),
                     "two claims at once is nobody's drag")
        XCTAssertNil(TabDragItem(encoded: Data(#"{"planchetteTab":42}"#.utf8)))
        XCTAssertNil(TabDragItem(encoded: Data(id.utf8)), "a bare id is what a terminal would type")
        XCTAssertNil(TabDragItem(encoded: Data([0xff, 0xfe])))
        XCTAssertNil(TabDragItem(encoded: Data("[]".utf8)))
    }
}

/// State written before tabs held splits still opens — and a project saved in cluster mode
/// comes back as one tab with everything in it.
final class TabMigrationTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), gid = UUID()

    private func decode(_ json: String) throws -> SessionGroup {
        try JSONDecoder().decode(SessionGroup.self, from: Data(json.utf8))
    }

    func testAProjectThatNeverSplitHasNoStripAndShowsOneTabPerTerminal() throws {
        let group = try decode("""
            {"id":"\(gid)","name":"p","sessionIDs":["\(a)","\(b)"]}
            """)
        XCTAssertNil(group.tabs)
        XCTAssertEqual(TabStrip.synced(group.tabs, to: group.sessionIDs), [.leaf(a), .leaf(b)])
    }

    func testATabsModeProjectOfOldStaysPlainTabs() throws {
        let group = try decode("""
            {"id":"\(gid)","name":"p","viewMode":"tabs","sessionIDs":["\(a)","\(b)"]}
            """)
        XCTAssertNil(group.tabs)
    }

    func testAClusterProjectBecomesOneTabWithItsLayout() throws {
        let layout = SplitLayout.row([.leaf(a), .column([.leaf(b), .leaf(c)])])
        let encoded = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        let group = try decode("""
            {"id":"\(gid)","name":"p","viewMode":"cluster","sessionIDs":["\(a)","\(b)","\(c)"],
             "clusterLayout":\(encoded)}
            """)
        XCTAssertEqual(group.tabs, [layout])
    }

    func testAClusterProjectWithoutALayoutBecomesOneRowTab() throws {
        let group = try decode("""
            {"id":"\(gid)","name":"p","viewMode":"cluster","sessionIDs":["\(a)","\(b)"]}
            """)
        XCTAssertEqual(group.tabs, [.row([.leaf(a), .leaf(b)])])
    }

    func testAClusterLayoutThatLostATerminalIsRepairedOnTheWay() throws {
        let stale = SplitLayout.row([.leaf(a), .leaf(b), .leaf(c)])
        let encoded = String(decoding: try JSONEncoder().encode(stale), as: UTF8.self)
        let group = try decode("""
            {"id":"\(gid)","name":"p","viewMode":"cluster","sessionIDs":["\(a)","\(c)"],
             "clusterLayout":\(encoded)}
            """)
        XCTAssertEqual(group.tabs, [.row([.leaf(a), .leaf(c)])])
    }

    func testAClusterProjectWithNoTerminalsStaysEmpty() throws {
        let group = try decode("""
            {"id":"\(gid)","name":"p","viewMode":"cluster","sessionIDs":[]}
            """)
        XCTAssertNil(group.tabs)
    }

    func testAGarbledLegacyFieldDoesNotLoseTheProject() throws {
        let group = try decode("""
            {"id":"\(gid)","name":"p","viewMode":"sideways","sessionIDs":["\(a)"],"clusterLayout":42}
            """)
        XCTAssertEqual(group.sessionIDs, [a])
        XCTAssertNil(group.tabs)
    }

    func testTheStripRoundTripsAndTheLegacyKeysAreNotWritten() throws {
        var group = SessionGroup(id: gid, name: "p")
        group.sessionIDs = [a, b, c]
        group.tabs = [.row([.leaf(a), .leaf(b)]), .leaf(c)]
        let data = try JSONEncoder().encode(group)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("viewMode"))
        XCTAssertFalse(json.contains("clusterLayout"))
        XCTAssertEqual(try JSONDecoder().decode(SessionGroup.self, from: data), group)
    }

    func testAStoredStripWinsOverLegacyKeys() throws {
        let stored = SplitLayout.row([.leaf(a), .leaf(b)])
        let encoded = String(decoding: try JSONEncoder().encode([stored]), as: UTF8.self)
        let group = try decode("""
            {"id":"\(gid)","name":"p","viewMode":"cluster","sessionIDs":["\(a)","\(b)"],"tabs":\(encoded)}
            """)
        XCTAssertEqual(group.tabs, [stored])
    }
}

/// Saved arrangements follow the tabs: a split is stored by terminal index, and an arrangement
/// from before splits lived in tabs still opens.
final class TabPresetTests: XCTestCase {
    private func project(terminals: Int) -> PresetProject {
        var project = PresetProject(name: "p")
        project.terminals = (0..<terminals).map { PresetTerminal(workingDirectory: "/tmp/\($0)") }
        return project
    }

    func testAnArrangementWithoutSplitsOpensAsPlainTabs() {
        XCTAssertEqual(project(terminals: 3).resolvedTabs(with: [UUID(), UUID(), UUID()]), [])
    }

    func testTheTabLayoutsAreRebuiltOnFreshTerminals() {
        var p = project(terminals: 4)
        p.tabLayouts = [.row([.leaf(0), .leaf(1)]), .leaf(2), .leaf(3)]
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(
            p.resolvedTabs(with: ids), [.row([.leaf(ids[0]), .leaf(ids[1])]), .leaf(ids[2]), .leaf(ids[3])])
    }

    func testATerminalNoTabNamesGetsATabAtTheEnd() {
        var p = project(terminals: 3)
        p.tabLayouts = [.row([.leaf(0), .leaf(1)])]
        let ids = (0..<3).map { _ in UUID() }
        XCTAssertEqual(
            p.resolvedTabs(with: ids), [.row([.leaf(ids[0]), .leaf(ids[1])]), .leaf(ids[2])])
    }

    func testAnArrangementSavedInClusterModeIsOneTab() {
        var p = project(terminals: 3)
        p.viewMode = .cluster
        p.clusterLayout = .row([.leaf(0), .column([.leaf(1), .leaf(2)])])
        let ids = (0..<3).map { _ in UUID() }
        XCTAssertEqual(
            p.resolvedTabs(with: ids), [.row([.leaf(ids[0]), .column([.leaf(ids[1]), .leaf(ids[2])])])])
    }

    func testTabLayoutsRoundTripAndOldFilesDecode() throws {
        var p = project(terminals: 2)
        p.tabLayouts = [.row([.leaf(0), .leaf(1)])]
        let decoded = try JSONDecoder().decode(
            PresetProject.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
        let old = try JSONDecoder().decode(
            PresetProject.self,
            from: Data(#"{"name":"p","viewMode":"cluster","clusterLayout":{"row":{"_0":[{"leaf":{"_0":0}},{"leaf":{"_0":1}}]}},"terminals":[{"workingDirectory":"/a"},{"workingDirectory":"/b"}]}"#.utf8))
        XCTAssertNil(old.tabLayouts)
        XCTAssertEqual(old.clusterLayout, .row([.leaf(0), .leaf(1)]))
    }
}

/// What a tab is called: the terminal it was made for, whatever is moved into it or has the keyboard.
final class TabTitleTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    private func leaf(_ id: UUID) -> SplitLayout { .leaf(id) }

    private func carry(_ old: [SplitLayout], _ anchors: [UUID], _ new: [SplitLayout]?, target: UUID? = nil) -> [UUID] {
        TabStrip.carriedAnchors(old: old, oldAnchors: anchors, new: new ?? old, preferring: target)
    }

    func testATabWithoutAStoredTitleIsCalledAfterItsFirstTerminal() {
        XCTAssertEqual(TabStrip.speaker(of: .row([leaf(a), leaf(b)]), anchors: []), a)
        XCTAssertEqual(TabStrip.speaker(of: leaf(c), anchors: []), c)
    }

    func testAStoredTitleWinsWhereverItSits() {
        XCTAssertEqual(TabStrip.speaker(of: .row([leaf(a), leaf(b)]), anchors: [b]), b)
        XCTAssertEqual(TabStrip.speaker(of: .row([leaf(a), leaf(b)]), anchors: [e, b]), b, "a title of another tab is ignored")
        XCTAssertEqual(TabStrip.speaker(of: .row([leaf(a), leaf(b)]), anchors: [e]), a, "one that is not here is ignored")
    }

    func testAMovedTabDoesNotRenameTheTabItMovesInto() {
        let tabs = [leaf(a), leaf(b), leaf(c)]
        for edge in [LayoutEdge.left, .right, .top, .bottom] {
            let new = TabStrip.dropTab(at: 2, onto: a, edge: edge, in: tabs)!
            let anchors = carry(tabs, [], new, target: a)
            XCTAssertEqual(TabStrip.speaker(of: new[0], anchors: anchors), a, "dropped on the \(edge) edge: still a")
            XCTAssertEqual(TabStrip.speaker(of: new[1], anchors: anchors), b)
        }
    }

    func testAMovedPaneDoesNotRenameTheTabItMovesInto() {
        let tabs = [SplitLayout.row([leaf(a), leaf(b)]), leaf(c)]
        let new = TabStrip.dropPane(c, onto: b, edge: .left, in: tabs)!
        let anchors = carry(tabs, [], new, target: b)
        XCTAssertEqual(TabStrip.speaker(of: new[0], anchors: anchors), a, "the tab was called a before")
    }

    func testAPaneThatWasATabsTitleLeavesItAndTheTabTakesItsFirstTerminal() {
        let tabs = [SplitLayout.row([leaf(a), leaf(b)]), leaf(c)]
        let new = TabStrip.dropPane(a, onto: c, edge: .right, in: tabs)!        // a was the title of tab 0
        let anchors = carry(tabs, [a], new, target: c)
        XCTAssertEqual(TabStrip.speaker(of: new[0], anchors: anchors), b, "the tab it left is called b now")
        XCTAssertEqual(TabStrip.speaker(of: new[1], anchors: anchors), c, "the tab it joined keeps c")
    }

    func testAPaneTakenOutBecomesATabCalledAfterItself() {
        let tabs = [SplitLayout.row([leaf(a), leaf(b)])]
        let new = TabStrip.extractPane(b, before: 1, in: tabs)!
        let anchors = carry(tabs, [], new)
        XCTAssertEqual(new.map { TabStrip.speaker(of: $0, anchors: anchors) }, [a, b])
    }

    func testCombiningKeepsTheFirstTabsName() {
        let tabs = [leaf(a), leaf(b), leaf(c), leaf(d)]
        let anchors = carry(tabs, [], TabStrip.combined(tabs))
        XCTAssertEqual(TabStrip.speaker(of: TabStrip.combined(tabs)![0], anchors: anchors), a)
    }

    func testSeparatingGivesEveryPaneItsOwnName() {
        let tabs = [SplitLayout.row([leaf(a), leaf(b)]), leaf(c)]
        let new = TabStrip.separated(tabs)!
        let anchors = carry(tabs, [b], new)
        XCTAssertEqual(new.map { TabStrip.speaker(of: $0, anchors: anchors) }, [a, b, c])
    }

    func testClosingTheTitleTerminalPassesTheNameOn() {
        let tabs = [SplitLayout.row([leaf(a), leaf(b)]), leaf(c)]
        let new = TabStrip.removing(a, from: tabs)
        let anchors = carry(tabs, [a], new)
        XCTAssertEqual(new.map { TabStrip.speaker(of: $0, anchors: anchors) }, [b, c])
    }

    func testMovingATabChangesNoName() {
        let tabs = [leaf(a), SplitLayout.row([leaf(b), leaf(c)]), leaf(d)]
        let new = TabStrip.moveTab(from: 1, before: 0, in: tabs)!
        let anchors = carry(tabs, [c], new)
        XCTAssertEqual(new.map { TabStrip.speaker(of: $0, anchors: anchors) }, [c, a, d])
    }

    /// Whatever is dragged onto a pane, the tab it lands in keeps its name — and every tab has one.
    func testRandomDropsNeverRenameTheTabTheyLandIn() {
        let edges: [LayoutEdge] = [.top, .bottom, .left, .right]
        var landed = 0
        for seed in 1...150 {
            var state = UInt64(seed) &* 2862933555777941757 &+ 3037000493
            func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(max(n, 1))) }
            let ids = (0..<(2 + next(6))).map { _ in UUID() }
            var tabs = TabStrip.synced(nil, to: ids)
            var anchors: [UUID] = []
            for _ in 0..<40 {
                let leaves = TabStrip.order(tabs)
                let target = leaves[next(leaves.count)]
                let edge = edges[next(4)]
                let result: [SplitLayout]?
                if next(2) == 0 {
                    result = TabStrip.dropTab(at: next(tabs.count), onto: target, edge: edge, in: tabs)
                } else {
                    result = TabStrip.dropPane(leaves[next(leaves.count)], onto: target, edge: edge, in: tabs)
                }
                guard let new = result else { continue }
                let nameBefore = TabStrip.index(of: target, in: tabs).flatMap { TabStrip.speaker(of: tabs[$0], anchors: anchors) }
                let carried = carry(tabs, anchors, new, target: target)
                let nameAfter = TabStrip.index(of: target, in: new).flatMap { TabStrip.speaker(of: new[$0], anchors: carried) }
                XCTAssertEqual(nameAfter, nameBefore, "seed \(seed): the tab a terminal is dropped into keeps its name")
                for tab in new {
                    XCTAssertNotNil(TabStrip.speaker(of: tab, anchors: carried))
                    XCTAssertTrue(tab.leaves.contains(TabStrip.speaker(of: tab, anchors: carried)!), "the name is a terminal of the tab")
                }
                XCTAssertEqual(carried.count, new.count, "one name per tab")
                landed += 1
                tabs = new
                anchors = carried
            }
        }
        XCTAssertGreaterThan(landed, 1000, "the random walk must really move things")
    }

    func testAStateFromBeforeTabsHadATitleOpensWithOneTitlePerTabFromTheFirstTerminal() throws {
        let group = try JSONDecoder().decode(SessionGroup.self, from: Data(#"{"id":"\#(UUID())","name":"p"}"#.utf8))
        XCTAssertEqual(group.tabAnchors, [])
        var stored = SessionGroup(id: UUID(), name: "p")
        stored.tabAnchors = [a, b]
        XCTAssertEqual(try JSONDecoder().decode(SessionGroup.self, from: JSONEncoder().encode(stored)).tabAnchors, [a, b])
    }
}

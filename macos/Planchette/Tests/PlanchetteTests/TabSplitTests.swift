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

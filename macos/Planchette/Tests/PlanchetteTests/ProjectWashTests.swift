import XCTest
@testable import Planchette

final class ProjectWashTests: XCTestCase {
    private func slices(_ count: Int, lead: Double = 0.3, tail: Double = 0.06) -> [(top: Double, bottom: Double)] {
        (0..<count).map { ProjectWash.slice(row: $0, of: count, lead: lead, tail: tail) }
    }

    // The point of drawing it in slices: where two terminals meet, the strength must not jump.
    func testTheRowsOfABodyJoinWithoutAJump() {
        for count in 1...9 {
            let all = slices(count)
            for (upper, lower) in zip(all, all.dropFirst()) {
                XCTAssertEqual(upper.bottom, lower.top, accuracy: 1e-12, "\(count) rows")
            }
        }
    }

    func testTheFirstRowStartsAtTheLeadAndTheLastOneEndsAtTheTail() {
        for count in 1...9 {
            let all = slices(count)
            XCTAssertEqual(all.first?.top ?? -1, 0.3, accuracy: 1e-12)
            XCTAssertEqual(all.last?.bottom ?? -1, 0.06, accuracy: 1e-12)
        }
    }

    func testEveryRowFadesByTheSameStep() {
        let all = slices(5)
        let steps = all.map { $0.top - $0.bottom }
        for step in steps { XCTAssertEqual(step, steps[0], accuracy: 1e-12) }
        XCTAssertGreaterThan(steps[0], 0, "the wash fades going down")
    }

    func testALoneTerminalGetsTheWholeFade() {
        let only = ProjectWash.slice(row: 0, of: 1, lead: 0.3, tail: 0.06)
        XCTAssertEqual(only.top, 0.3, accuracy: 1e-12)
        XCTAssertEqual(only.bottom, 0.06, accuracy: 1e-12)
    }

    // A row the list reports out of turn (a terminal closing, a project refreshing) must not draw
    // outside the fade, nor divide by nothing.
    func testARowOutsideTheBodyIsHeldAtItsEnds() {
        let first = ProjectWash.slice(row: 0, of: 3, lead: 0.3, tail: 0.06)
        let last = ProjectWash.slice(row: 2, of: 3, lead: 0.3, tail: 0.06)
        XCTAssertEqual(ProjectWash.slice(row: -4, of: 3, lead: 0.3, tail: 0.06).top, first.top)
        XCTAssertEqual(ProjectWash.slice(row: 9, of: 3, lead: 0.3, tail: 0.06).bottom, last.bottom)
        let none = ProjectWash.slice(row: 0, of: 0, lead: 0.3, tail: 0.06)
        XCTAssertEqual(none.top, 0.3, accuracy: 1e-12)
        XCTAssertEqual(none.bottom, 0.06, accuracy: 1e-12)
    }

    // The block has round corners at its ends only: between two terminals there is nothing to see.
    func testOnlyTheEndsOfTheBodyAreRounded() {
        let r = ProjectWash.radius
        let top = ProjectWash.outline(row: 0, of: 3).cornerRadii
        XCTAssertEqual([top.topLeading, top.topTrailing, top.bottomLeading, top.bottomTrailing], [r, r, 0, 0])
        let middle = ProjectWash.outline(row: 1, of: 3).cornerRadii
        XCTAssertEqual([middle.topLeading, middle.topTrailing, middle.bottomLeading, middle.bottomTrailing], [0, 0, 0, 0])
        let bottom = ProjectWash.outline(row: 2, of: 3).cornerRadii
        XCTAssertEqual([bottom.topLeading, bottom.topTrailing, bottom.bottomLeading, bottom.bottomTrailing], [0, 0, r, r])
        let lone = ProjectWash.outline(row: 0, of: 1).cornerRadii
        XCTAssertEqual([lone.topLeading, lone.topTrailing, lone.bottomLeading, lone.bottomTrailing], [r, r, r, r])
    }
}

import XCTest
@testable import Planchette

final class ProgressTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let steps = ["Plan", "Build", "Review", "CI"]

    private func resolve(
        steps: [String]? = nil, total: Int? = nil, step: Int? = nil, label: String? = nil,
        current: TerminalProgress? = nil, at offset: TimeInterval = 0
    ) -> Result<TerminalProgress, ControlAPI.Failure> {
        TerminalProgress.resolve(
            steps: steps, total: total, step: step, label: label,
            current: current, now: t0.addingTimeInterval(offset))
    }

    private func value(_ result: Result<TerminalProgress, ControlAPI.Failure>,
                       file: StaticString = #filePath, line: UInt = #line) -> TerminalProgress? {
        switch result {
        case .success(let progress): return progress
        case .failure(let failure):
            XCTFail("unexpected failure: \(failure.message)", file: file, line: line)
            return nil
        }
    }

    private func message(_ result: Result<TerminalProgress, ControlAPI.Failure>) -> String? {
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    // MARK: First report

    func testNamedStepsSetTheTotal() {
        let progress = value(resolve(steps: steps, step: 2, label: "round 1"))
        XCTAssertEqual(progress?.total, 4)
        XCTAssertEqual(progress?.stepName, "Build")
        XCTAssertEqual(progress?.label, "round 1")
        XCTAssertEqual(progress?.since, t0)
    }

    func testACountWithoutNamesIsEnough() {
        let progress = value(resolve(total: 13, step: 8))
        XCTAssertEqual(progress?.steps, [])
        XCTAssertNil(progress?.stepName)
    }

    func testFirstReportNeedsASequenceAndAStep() {
        XCTAssertEqual(message(resolve(step: 1)), "steps or total is required for the first report")
        XCTAssertEqual(message(resolve(steps: steps)), "step is required for the first report")
    }

    // MARK: Limits

    func testStepOutsideTheSequenceIsRefused() {
        XCTAssertEqual(message(resolve(steps: steps, step: 0)), "step must be 1 to 4")
        XCTAssertEqual(message(resolve(steps: steps, step: 5)), "step must be 1 to 4")
    }

    func testTotalThatContradictsTheNamesIsRefused() {
        XCTAssertEqual(message(resolve(steps: steps, total: 5, step: 1)),
                       "total (5) does not match steps (4)")
    }

    func testSequenceSizeIsBounded() {
        XCTAssertNotNil(message(resolve(total: TerminalProgress.maxSteps + 1, step: 1)))
        XCTAssertNotNil(message(resolve(total: 0, step: 1)))
        XCTAssertNotNil(message(resolve(steps: [], step: 1)))
        XCTAssertNotNil(message(resolve(steps: ["Plan", "  "], step: 1)))
    }

    // Text from the terminal is drawn into a one-line row.
    func testTextIsOneLineAndCut() {
        let long = String(repeating: "x", count: 500)
        let progress = value(resolve(steps: ["Plan\nnow", "Build"], step: 1, label: "a\n  b\t" + long))
        XCTAssertEqual(progress?.steps.first, "Plan now")
        XCTAssertEqual(progress?.label?.count, TerminalProgress.maxLabel)
        XCTAssertTrue(progress?.label?.hasPrefix("a b x") == true)
        XCTAssertTrue(progress?.label?.hasSuffix("…") == true)
    }

    // MARK: Later reports

    func testLaterReportsKeepTheSequence() {
        let first = value(resolve(steps: steps, step: 1, label: "reading"))
        let next = value(resolve(step: 3, current: first, at: 60))
        XCTAssertEqual(next?.steps, steps)
        XCTAssertEqual(next?.stepName, "Review")
        XCTAssertEqual(next?.label, "reading", "a report without a label keeps the old one")
        XCTAssertEqual(next?.since, t0.addingTimeInterval(60))
    }

    func testLabelAloneCanChange() {
        let first = value(resolve(steps: steps, step: 3, label: "round 1"))
        let next = value(resolve(label: "round 2", current: first, at: 30))
        XCTAssertEqual(next?.step, 3)
        XCTAssertEqual(next?.label, "round 2")
    }

    func testEmptyLabelClearsIt() {
        let first = value(resolve(steps: steps, step: 3, label: "round 1"))
        XCTAssertNil(value(resolve(label: "", current: first))?.label)
    }

    // Equal writes stay no-ops: a repeat must not look like news.
    func testRepeatKeepsTheTimeOfTheChange() {
        let first = value(resolve(steps: steps, step: 2, label: "x"))
        let repeated = value(resolve(steps: steps, step: 2, label: "x", current: first, at: 300))
        XCTAssertEqual(repeated, first)
    }

    func testNewCountDropsNamesThatNoLongerFit() {
        let first = value(resolve(steps: steps, step: 2))
        XCTAssertEqual(value(resolve(total: 6, step: 5, current: first))?.steps, [])
        XCTAssertEqual(value(resolve(total: 4, step: 4, current: first))?.steps, steps)
    }

    // MARK: API

    func testProgressIsAKnownCommand() {
        guard case .success(let request)? = ControlAPI.parse([
            "planchette_request": "session.progress", "steps": steps, "step": 2,
        ]) else { return XCTFail("expected a parsed request") }
        XCTAssertEqual(request.command, .sessionProgress)
        XCTAssertEqual(request.strings("steps"), steps)
        XCTAssertEqual(request.int("step"), 2)
    }

    func testDescribeReportsStableKeysAndOmitsAbsentOnes() {
        let iso = ISO8601DateFormatter()
        let named = value(resolve(steps: steps, step: 4, label: "green"))!.describe(iso: iso)
        XCTAssertEqual(named["step"] as? Int, 4)
        XCTAssertEqual(named["total"] as? Int, 4)
        XCTAssertEqual(named["step_name"] as? String, "CI")
        XCTAssertEqual(named["label"] as? String, "green")
        XCTAssertEqual(named["since"] as? String, iso.string(from: t0))
        let counted = value(resolve(total: 3, step: 1))!.describe(iso: iso)
        XCTAssertNil(counted["steps"])
        XCTAssertNil(counted["step_name"])
        XCTAssertNil(counted["label"])
    }
}

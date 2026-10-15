import XCTest
@testable import Planchette

/// A turn that ended while Claude still runs a shell or an agent in the background: the terminal
/// keeps showing what is true.
final class BackgroundRunningTests: XCTestCase {
    func testAFinishedTurnWithBackgroundWorkStaysRunning() {
        XCTAssertEqual(AttentionState.ready.settled(hasBackgroundWork: true), .running)
    }

    // A terminal at an idle prompt (a `/clear`, a session that just began) is no more done than a finished one.
    func testAnIdleTerminalWithBackgroundWorkIsRunningToo() {
        XCTAssertEqual(AttentionState.free.settled(hasBackgroundWork: true), .running)
    }

    // A question or an error still wants you, whatever else runs.
    func testAQuestionOrAnErrorWinsOverBackgroundWork() {
        XCTAssertEqual(AttentionState.waiting.settled(hasBackgroundWork: true), .waiting)
        XCTAssertEqual(AttentionState.error.settled(hasBackgroundWork: true), .error)
    }

    func testRunningStaysRunning() {
        XCTAssertEqual(AttentionState.running.settled(hasBackgroundWork: true), .running)
        XCTAssertEqual(AttentionState.running.settled(hasBackgroundWork: false), .running)
    }

    func testWithoutBackgroundWorkNothingChanges() {
        for state in [AttentionState.ready, .running, .waiting, .error, .free] {
            XCTAssertEqual(state.settled(hasBackgroundWork: false), state, "\(state)")
        }
    }

    // MARK: The setting

    private func decode(_ json: String) throws -> PersistedState {
        try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
    }

    func testTheSettingIsOnByDefault() throws {
        XCTAssertTrue(PersistedState(groups: [], sessions: [], windows: [], aiEnabled: false, language: .en,
                                     appearance: .system, autoUpdateCheck: true, durableTerminals: true)
            .backgroundCountsAsRunning)
        XCTAssertTrue(try decode("{}").backgroundCountsAsRunning, "a workspace from before the setting")
    }

    func testTheChoiceSurvivesASaveAndALoad() throws {
        let saved = PersistedState(groups: [], sessions: [], windows: [], aiEnabled: false, language: .en,
                                   appearance: .system, autoUpdateCheck: true, durableTerminals: true,
                                   backgroundCountsAsRunning: false)
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved))
        XCTAssertFalse(back.backgroundCountsAsRunning)
    }

    // A value no version can read costs that one choice, never the workspace.
    func testAnUnreadableChoiceFallsBackToTheDefault() throws {
        XCTAssertTrue(try decode(#"{"backgroundCountsAsRunning":"maybe"}"#).backgroundCountsAsRunning)
        XCTAssertFalse(try decode(#"{"backgroundCountsAsRunning":false}"#).backgroundCountsAsRunning)
    }
}

/// The globe: the icon of a terminal that runs only because of its background work.
final class GlobeSpriteTests: XCTestCase {
    private let globe = StatePixels.globe

    // A square grid of lit and unlit pixels, nothing else: a stray character would draw as a hole.
    func testTheGlobeIsASquareGridOfPixels() {
        XCTAssertEqual(globe.count, 13)
        for row in globe {
            XCTAssertEqual(row.count, globe.count)
            XCTAssertTrue(row.allSatisfy { $0 == "#" || $0 == "." }, row)
        }
    }

    // A globe is the same left and right, top and bottom: a crooked one reads as a mistake.
    func testTheGlobeIsSymmetric() {
        XCTAssertEqual(globe, globe.map { String($0.reversed()) }, "left and right")
        XCTAssertEqual(globe, Array(globe.reversed()), "top and bottom")
    }

    // The ring touches all four edges, so it fills the icon's frame as the other sprites do.
    func testTheGlobeFillsItsFrame() {
        XCTAssertTrue(globe.first!.contains("#"))
        XCTAssertTrue(globe.last!.contains("#"))
        XCTAssertTrue(globe.contains { $0.first == "#" })
        XCTAssertTrue(globe.contains { $0.last == "#" })
    }

    // It must not be mistaken for the robot, or it says nothing new.
    func testTheGlobeIsNotARunningFrame() {
        for frame in StatePixels.frames(.running) {
            XCTAssertNotEqual(frame, globe)
        }
        XCTAssertNotEqual(globe.count, StatePixels.size, "a different grid: lines need the room")
    }

    func testTheGlobeHasATranslatedNameAndLegend() {
        let language = L10n.current
        defer { L10n.current = language }
        for lang in AppLanguage.allCases where lang != .system {
            L10n.current = lang
            for key in [LKey.stateBackground, .backgroundDesc] {
                XCTAssertNotEqual(L10n.t(key), key.rawValue, "\(key) in \(lang)")
            }
        }
    }
}

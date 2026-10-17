import XCTest
@testable import Planchette

final class OnboardingStateTests: XCTestCase {
    private func decode(_ json: String) throws -> OnboardingState {
        try JSONDecoder().decode(OnboardingState.self, from: Data(json.utf8))
    }

    // MARK: What a saved file means

    // Somebody who updates from a version without this key already works in the app.
    func testAStateFromBeforeThisExistedReadsAsSeen() throws {
        let state = try decode("{}")
        XCTAssertTrue(state.welcomeSeen)
        XCTAssertNil(state.lastLaunchedVersion)
        XCTAssertFalse(state.durablePromptHidden)
    }

    func testAWorkspaceWithoutTheKeyReadsAsSeen() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[]}"#
        let saved = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertTrue(saved.onboarding.welcomeSeen)
    }

    func testAFirstLaunchSurvivesASaveAndALoad() throws {
        let saved = PersistedState(
            groups: [], sessions: [], windows: [], aiEnabled: false, language: .en,
            appearance: .system, autoUpdateCheck: true, durableTerminals: true,
            onboarding: OnboardingState(welcomeSeen: false, lastLaunchedVersion: "0.2.36", durablePromptHidden: true))
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.onboarding, saved.onboarding)
        XCTAssertFalse(back.onboarding.welcomeSeen)
    }

    // A file another version wrote must cost the field it cannot read, never the workspace.
    func testAnUnreadableValueCostsOnlyThatField() throws {
        let state = try decode(#"{"welcomeSeen":"yes","lastLaunchedVersion":"0.2.35","durablePromptHidden":true}"#)
        XCTAssertTrue(state.welcomeSeen)
        XCTAssertEqual(state.lastLaunchedVersion, "0.2.35")
        XCTAssertTrue(state.durablePromptHidden)
    }

    func testAnUnreadableBlockCostsOnlyTheOnboardingState() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[],"onboarding":"from the future","aiEnabled":false}"#
        let saved = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(saved.onboarding, OnboardingState())
    }

    func testTheFirstLaunchStateHasNotSeenTheWelcome() {
        XCTAssertFalse(OnboardingState.firstLaunch.welcomeSeen)
        XCTAssertNil(OnboardingState.firstLaunch.lastLaunchedVersion)
    }

    // MARK: When the durable terminals prompt is due

    func testDueOnTheFirstLaunchOfANewVersionWithoutDurableTerminals() {
        let state = OnboardingState(welcomeSeen: true, lastLaunchedVersion: "0.2.35")
        XCTAssertTrue(state.durablePromptDue(runningVersion: "0.2.36", durableOn: false))
    }

    // The message belongs to the update, not to every start.
    func testNotDueAgainOnTheSameVersion() {
        let state = OnboardingState(welcomeSeen: true, lastLaunchedVersion: "0.2.36")
        XCTAssertFalse(state.durablePromptDue(runningVersion: "0.2.36", durableOn: false))
    }

    func testDueAgainAfterTheNextUpdate() {
        let state = OnboardingState(welcomeSeen: true, lastLaunchedVersion: "0.2.36")
        XCTAssertTrue(state.durablePromptDue(runningVersion: "0.2.37", durableOn: false))
    }

    func testNotDueForSomebodyWhoHasDurableTerminals() {
        let state = OnboardingState(welcomeSeen: true, lastLaunchedVersion: "0.2.35")
        XCTAssertFalse(state.durablePromptDue(runningVersion: "0.2.36", durableOn: true))
    }

    func testNotDueAfterDontShowThisAgain() {
        let state = OnboardingState(welcomeSeen: true, lastLaunchedVersion: "0.2.35", durablePromptHidden: true)
        XCTAssertFalse(state.durablePromptDue(runningVersion: "0.2.36", durableOn: false))
        XCTAssertFalse(state.durablePromptDue(runningVersion: "0.9.0", durableOn: false))
    }

    // A first launch has the welcome screen, which carries the same message.
    func testNotDueOnAFirstLaunch() {
        XCTAssertFalse(OnboardingState.firstLaunch.durablePromptDue(runningVersion: "0.2.36", durableOn: false))
    }

    // A state from before versions were recorded: the user is updating right now.
    func testDueWhenNoVersionWasEverRecorded() {
        XCTAssertTrue(OnboardingState().durablePromptDue(runningVersion: "0.2.36", durableOn: false))
    }

    func testAHintIsDueUntilItsFeatureWasUsedOrAllAreHidden() {
        XCTAssertTrue(HintBook().isDue(.notepad))
        XCTAssertFalse(HintBook(done: [FeatureHint.notepad.rawValue]).isDue(.notepad))
        XCTAssertFalse(HintBook(hidden: true).isDue(.notepad))
    }

    func testEveryHintHasContent() {
        for hint in FeatureHint.allCases {
            let content = FeatureHintContent.of(hint)
            for key in [content.title, content.body, content.action, .hintHide] {
                XCTAssertNotEqual(L10n.t(key), key.rawValue, "untranslated: \(hint) \(key)")
            }
        }
    }

    func testAStateFromBeforeHintsReadsAsAllDue() throws {
        let old = #"{"welcomeSeen":true,"durablePromptHidden":false,"notepadTried":true}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(OnboardingState.self, from: old)
        XCTAssertTrue(state.hints.isDue(.notepad))
        let round = try JSONDecoder().decode(
            OnboardingState.self,
            from: JSONEncoder().encode(OnboardingState(hints: HintBook(hidden: true, done: ["notepad", "future"]))))
        XCTAssertTrue(round.hints.hidden)
        XCTAssertEqual(round.hints.done, ["notepad", "future"])
    }
}

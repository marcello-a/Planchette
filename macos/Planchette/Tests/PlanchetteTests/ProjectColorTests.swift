import XCTest
@testable import Planchette

final class ProjectColorLookTests: XCTestCase {
    private func decode(_ json: String) throws -> ProjectColorLook {
        try JSONDecoder().decode(ProjectColorLook.self, from: Data(json.utf8))
    }

    // The colorful look read as heavy: what a new user gets is the one in the middle.
    func testTheDefaultIsTheWholeProjectInTheMiddleStrength() {
        let look = ProjectColorLook()
        XCTAssertEqual(look.scope, .project)
        XCTAssertEqual(look.strength, .subtle)
    }

    func testAnEmptyBlockDecodesToTheDefaults() throws {
        XCTAssertEqual(try decode("{}"), ProjectColorLook())
    }

    func testAWorkspaceFromBeforeTheSettingGetsTheDefaults() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[]}"#
        let saved = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(saved.projectColor, ProjectColorLook())
    }

    // A value no version can read costs that one choice, never the workspace.
    func testAnUnreadableChoiceCostsOnlyThatChoice() throws {
        let look = try decode(#"{"scope":"everywhere","strength":"faint"}"#)
        XCTAssertEqual(look.scope, .project)
        XCTAssertEqual(look.strength, .faint)
        let other = try decode(#"{"scope":"label","strength":["loud"]}"#)
        XCTAssertEqual(other.scope, .label)
        XCTAssertEqual(other.strength, .subtle)
    }

    func testAnUnreadableBlockCostsOnlyTheLook() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[],"projectColor":42}"#
        XCTAssertEqual(try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8)).projectColor, ProjectColorLook())
    }

    func testAChoiceSurvivesASaveAndALoad() throws {
        var look = ProjectColorLook()
        look.scope = .label
        look.strength = .faint
        let saved = PersistedState(
            groups: [], sessions: [], windows: [], aiEnabled: false, language: .en,
            appearance: .system, autoUpdateCheck: true, durableTerminals: true, projectColor: look)
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.projectColor, look)
    }

    func testWhereTheColorShows() {
        func look(_ scope: ProjectColorScope) -> ProjectColorLook { var l = ProjectColorLook(); l.scope = scope; return l }
        XCTAssertFalse(look(.off).showsLabel)
        XCTAssertFalse(look(.off).showsBody)
        XCTAssertTrue(look(.label).showsLabel)
        XCTAssertFalse(look(.label).showsBody)
        XCTAssertTrue(look(.project).showsLabel)
        XCTAssertTrue(look(.project).showsBody)
    }

    func testEveryChoiceHasATranslatedTitle() {
        let language = L10n.current
        defer { L10n.current = language }
        for lang in AppLanguage.allCases where lang != .system {
            L10n.current = lang
            for key in ProjectColorScope.allCases.map(\.titleKey) + ProjectColorStrength.allCases.map(\.titleKey)
                + [.projectColorSection, .projectColorWhere, .projectColorStrength, .projectColorHelp] {
                XCTAssertNotEqual(L10n.t(key), key.rawValue, "\(key) in \(lang)")
            }
        }
    }
}

final class ProjectWashStrengthTests: XCTestCase {
    private func look(_ scope: ProjectColorScope, _ strength: ProjectColorStrength) -> ProjectColorLook {
        var look = ProjectColorLook()
        look.scope = scope
        look.strength = strength
        return look
    }

    // "None" means none: a project without a color is never tinted, whatever is set.
    func testAProjectWithoutAColorIsNeverTinted() {
        for scope in ProjectColorScope.allCases {
            for strength in ProjectColorStrength.allCases {
                XCTAssertNil(ProjectWash.strengths(isLabel: true, hasColor: false, look: look(scope, strength)))
                XCTAssertNil(ProjectWash.strengths(isLabel: false, hasColor: false, look: look(scope, strength)))
            }
        }
    }

    func testOffTintsNothing() {
        for strength in ProjectColorStrength.allCases {
            XCTAssertNil(ProjectWash.strengths(isLabel: true, look: look(.off, strength)))
            XCTAssertNil(ProjectWash.strengths(isLabel: false, look: look(.off, strength)))
        }
    }

    func testLabelOnlyTintsTheLabelAndLeavesTheTerminalsAlone() {
        XCTAssertNotNil(ProjectWash.strengths(isLabel: true, look: look(.label, .subtle)))
        XCTAssertNil(ProjectWash.strengths(isLabel: false, look: look(.label, .subtle)))
    }

    func testWholeProjectTintsBoth() {
        XCTAssertNotNil(ProjectWash.strengths(isLabel: true, look: look(.project, .subtle)))
        XCTAssertNotNil(ProjectWash.strengths(isLabel: false, look: look(.project, .subtle)))
    }

    // What 0.2.36 shipped, and what everything softer is a share of: it must not drift.
    func testColorfulIsTheLookOfVersion0236() throws {
        let label = try XCTUnwrap(ProjectWash.strengths(isLabel: true, look: look(.project, .colorful)))
        XCTAssertEqual(label.lead, 0.34, accuracy: 1e-12)
        XCTAssertEqual(label.tail, 0.05, accuracy: 1e-12)
        let body = try XCTUnwrap(ProjectWash.strengths(isLabel: false, look: look(.project, .colorful)))
        XCTAssertEqual(body.lead, 0.12, accuracy: 1e-12)
        XCTAssertEqual(body.tail, 0.03, accuracy: 1e-12)
    }

    func testEveryStepDownIsSofterButNeverGone() throws {
        for isLabel in [true, false] {
            let steps = try ProjectColorStrength.allCases.map {
                try XCTUnwrap(ProjectWash.strengths(isLabel: isLabel, look: look(.project, $0)))
            }
            for (louder, softer) in zip(steps, steps.dropFirst()) {
                XCTAssertGreaterThan(louder.lead, softer.lead)
                XCTAssertGreaterThan(louder.tail, softer.tail)
            }
            XCTAssertGreaterThan(try XCTUnwrap(steps.last).tail, 0)
        }
    }

    // The list of strengths is the picker: colorful first, the faintest last.
    func testTheStrengthsAreListedFromLoudToQuiet() {
        XCTAssertEqual(ProjectColorStrength.allCases, [.colorful, .subtle, .faint])
        XCTAssertEqual(ProjectColorScope.allCases, [.off, .label, .project])
    }
}

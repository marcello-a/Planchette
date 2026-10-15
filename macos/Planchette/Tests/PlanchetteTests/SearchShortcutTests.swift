import XCTest
@testable import Planchette

final class SearchShortcutTests: XCTestCase {
    func testTheDefaultIsShiftTwice() {
        XCTAssertEqual(SearchShortcut.default, .doubleTap(.shift))
        XCTAssertEqual(SearchShortcut.default.label, "⇧⇧")
    }

    func testLabelsAreWrittenTheWayMacOSWritesThem() {
        XCTAssertEqual(SearchShortcut.doubleTap(.command).label, "⌘⌘")
        XCTAssertEqual(SearchShortcut.chord(key: "p", modifiers: [.command]).label, "⌘P")
        // Control, option, shift, command — whatever the order they were given in.
        XCTAssertEqual(SearchShortcut.chord(key: "k", modifiers: [.command, .shift, .option, .control]).label, "⌃⌥⇧⌘K")
        XCTAssertEqual(SearchShortcut.chord(key: "/", modifiers: [.control]).label, "⌃/")
    }

    func testAChordNeedsAModifierBesidesShift() {
        XCTAssertNil(SearchShortcut.checkedChord(key: "p", modifiers: [Modifier]()), "a bare key is typing")
        XCTAssertNil(SearchShortcut.checkedChord(key: "p", modifiers: [.shift]), "shift and a letter is a capital letter")
        XCTAssertNotNil(SearchShortcut.checkedChord(key: "p", modifiers: [.shift, .command]))
        XCTAssertNotNil(SearchShortcut.checkedChord(key: "p", modifiers: [.control]))
        XCTAssertNotNil(SearchShortcut.checkedChord(key: "p", modifiers: [.option]))
    }

    func testTheOrderOfTheModifiersAndTheCaseOfTheKeyDoNotMatter() {
        XCTAssertEqual(SearchShortcut.chord(key: "P", modifiers: [.command, .shift]),
                       SearchShortcut.chord(key: "p", modifiers: [.shift, .command]))
        XCTAssertNotEqual(SearchShortcut.chord(key: "p", modifiers: [.command]),
                          SearchShortcut.chord(key: "p", modifiers: [.command, .shift]))
        XCTAssertNotEqual(SearchShortcut.doubleTap(.shift), SearchShortcut.doubleTap(.command))
        XCTAssertNotEqual(SearchShortcut.doubleTap(.command), SearchShortcut.chord(key: "p", modifiers: [.command]))
    }

    func testAChordIsOneVisibleKey() {
        XCTAssertNil(SearchShortcut.checkedChord(key: "", modifiers: [.command]))
        XCTAssertNil(SearchShortcut.checkedChord(key: "ab", modifiers: [.command]))
        XCTAssertNil(SearchShortcut.checkedChord(key: " ", modifiers: [.command]))
        XCTAssertEqual(SearchShortcut.checkedChord(key: "P", modifiers: [.command, .command]),
                       .chord(key: "p", modifiers: [.command]), "lowercase, once")
    }

    func testTheKeysTheAppAndMacOSUseAreReserved() {
        for key in ["q", "w", "n", "t", "c", "v", "x", "a", "z", ",", "h", "m"] {
            XCTAssertTrue(SearchShortcut.checkedChord(key: key, modifiers: [.command])!.isReserved, "⌘\(key)")
        }
        for key in ["n", "t", "k", "z"] {
            XCTAssertTrue(SearchShortcut.checkedChord(key: key, modifiers: [.command, .shift])!.isReserved, "⌘⇧\(key)")
        }
        XCTAssertFalse(SearchShortcut.checkedChord(key: "p", modifiers: [.command])!.isReserved)
        XCTAssertFalse(SearchShortcut.checkedChord(key: "k", modifiers: [.command])!.isReserved, "the menu's own")
        XCTAssertFalse(SearchShortcut.checkedChord(key: "p", modifiers: [.command, .shift])!.isReserved)
        XCTAssertFalse(SearchShortcut.default.isReserved)
    }

    func testItIsSavedAsAShortReadableWord() throws {
        XCTAssertEqual(SearchShortcut.default.rawValue, "double:shift")
        XCTAssertEqual(SearchShortcut.chord(key: "p", modifiers: [.command, .shift]).rawValue, "chord:shift+command:p",
                       "always in the order macOS prints them")
        for shortcut in [SearchShortcut.default, .doubleTap(.option),
                         SearchShortcut.chord(key: "p", modifiers: [.command, .shift]),
                         SearchShortcut.chord(key: ",", modifiers: [.control]), .chord(key: "/", modifiers: [.option])] {
            XCTAssertEqual(SearchShortcut(rawValue: shortcut.rawValue), shortcut, shortcut.label)
            let data = try JSONEncoder().encode(shortcut)
            // (JSON writes a slash as \/ — the same word, which is what decoding shows.)
            XCTAssertEqual(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/"),
                           "\"\(shortcut.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(SearchShortcut.self, from: data), shortcut)
        }
    }

    func testWhatIsNotAShortcutIsNotRead() {
        for raw in ["", "double:", "double:hyper", "chord:command", "chord:command:", "chord::p", "chord:shift:p",
                    "chord:command:ab", "tap:shift", "double:shift:extra"] {
            XCTAssertNil(SearchShortcut(rawValue: raw), raw)
        }
    }

    func testTheStateFileKeepsItAndFallsBackToTheDefault() throws {
        XCTAssertEqual(try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8)).searchShortcut, .default)
        var state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        state.searchShortcut = SearchShortcut.chord(key: "p", modifiers: [.command])
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.searchShortcut, state.searchShortcut)
        // A word a newer build wrote must not cost the whole workspace.
        let odd = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"searchShortcut":"triple:shift","tagList":["a"]}"#.utf8))
        XCTAssertEqual(odd.searchShortcut, .default)
        XCTAssertEqual(odd.tagList, ["a"])
    }

    private typealias Modifier = SearchShortcut.Modifier
}

final class DoubleTapDetectorTests: XCTestCase {
    private typealias Modifier = SearchShortcut.Modifier

    /// Feeds a script: modifier sets at times, or "." for another input.
    private func run(_ steps: [(Set<Modifier>?, TimeInterval)], modifier: Modifier = .shift) -> [Bool] {
        var detector = DoubleTapDetector(modifier: modifier)
        return steps.map { step in
            detector.feed(step.0.map { .modifiers($0, at: step.1) } ?? .other)
        }
    }

    private let shift: Set<Modifier> = [.shift]
    private let none: Set<Modifier> = []

    func testTwoQuickTapsOpenIt() {
        let fired = run([(shift, 0.00), (none, 0.08), (shift, 0.20), (none, 0.27)])
        XCTAssertEqual(fired, [false, false, false, true], "fires on the release of the second tap")
    }

    func testTwoSlowTapsDoNot() {
        XCTAssertEqual(run([(shift, 0), (none, 0.08), (shift, 0.9), (none, 0.97)]).last, false)
    }

    func testAHeldModifierIsNotATap() {
        // Shift held to select text, then a quick tap: still one tap only.
        XCTAssertEqual(run([(shift, 0), (none, 0.8), (shift, 1.0), (none, 1.07)]), [false, false, false, false])
    }

    func testAKeyBetweenTheTapsEndsTheAttempt() {
        XCTAssertEqual(run([(shift, 0), (none, 0.05), (nil, 0.1), (shift, 0.15), (none, 0.2)]).last, false)
    }

    // "Hello World": shift, a key, shift, a key — never a double tap.
    func testTypingCapitalLettersIsNotADoubleTap() {
        let fired = run([(shift, 0), (nil, 0.05), (none, 0.1), (shift, 0.2), (nil, 0.25), (none, 0.3)])
        XCTAssertFalse(fired.contains(true))
    }

    // Two Shift-clicks to select text.
    func testTwoShiftClicksAreNotADoubleTap() {
        let fired = run([(shift, 0), (nil, 0.05), (none, 0.1), (shift, 0.2), (nil, 0.25), (none, 0.3)])
        XCTAssertFalse(fired.contains(true))
    }

    func testAnotherModifierJoiningIsUseNotATap() {
        XCTAssertEqual(run([(shift, 0), ([.shift, .command], 0.02), (none, 0.06), (shift, 0.15), (none, 0.2)]).last, false)
        XCTAssertEqual(run([([.command], 0), ([.command, .shift], 0.02), (shift, 0.04), (none, 0.08)]).last, false,
                       "shift let go last is not a press of shift alone")
    }

    func testTheCapsLockKeyDoesNotBreakTheSequence() {
        // The flags do not change in the modifiers that count: the event is ignored.
        XCTAssertEqual(run([(shift, 0), (none, 0.05), (none, 0.08), (shift, 0.12), (none, 0.17)]).last, true)
    }

    func testAThirdTapStartsOver() {
        let fired = run([(shift, 0), (none, 0.05), (shift, 0.1), (none, 0.15),    // opens
                         (shift, 0.2), (none, 0.25),                               // a new first tap
                         (shift, 0.3), (none, 0.35)])                              // and its second
        XCTAssertEqual(fired.filter { $0 }.count, 2)
        XCTAssertEqual(fired, [false, false, false, true, false, false, false, true])
    }

    func testOtherModifiersCanBeTheKey() {
        let command: Set<Modifier> = [.command]
        XCTAssertEqual(run([(command, 0), (none, 0.05), (command, 0.1), (none, 0.15)], modifier: .command).last, true)
        XCTAssertEqual(run([(shift, 0), (none, 0.05), (shift, 0.1), (none, 0.15)], modifier: .command).last, false,
                       "the other key is not the one watched")
    }

    func testReleasingWithoutAPressDoesNothing() {
        XCTAssertEqual(run([(none, 0), (none, 0.1)]), [false, false])
    }
}

final class SearchStringsTests: XCTestCase {
    func testEveryTextOfTheSearchAndTheShortcutIsTranslated() {
        let keys: [LKey] = [
            .switcherPlaceholder, .switcherEmpty, .switcherHint, .quickSwitcherHelp, .searchTooltip, .searchSection,
            .searchShortcutTitle, .searchShortcutHelp, .searchShortcutChange, .searchShortcutCancel,
            .searchShortcutRecording, .searchShortcutRecordingHelp, .searchShortcutReset,
            .searchShortcutNeedsModifier, .searchShortcutTaken, .projectPanelSettingsHelp,
        ]
        for language in AppLanguage.allCases {
            L10n.current = language
            for key in keys {
                XCTAssertNotEqual(L10n.t(key), key.rawValue, "\(language) \(key)")
            }
        }
        L10n.current = .en
    }

    // The formats must take their argument in every language, or a tooltip prints "%@".
    func testTheFormatsTakeTheirArgument() {
        for language in AppLanguage.allCases {
            L10n.current = language
            for key in [LKey.searchTooltip, .searchShortcutReset, .searchShortcutTaken, .switcherEmpty] {
                let text = L10n.t(key, "⇧⇧")
                XCTAssertTrue(text.contains("⇧⇧"), "\(language) \(key): \(text)")
                XCTAssertFalse(text.contains("%"), "\(language) \(key): \(text)")
            }
        }
        L10n.current = .en
    }

    // The old help text named ⌘K: the live shortcut is shown next to it now, so no text may
    // claim a key of its own that Settings can change.
    func testNoStringHardCodesTheDefaultShortcut() {
        for language in AppLanguage.allCases {
            L10n.current = language
            XCTAssertFalse(L10n.t(.quickSwitcherHelp).contains("⌘K"), "\(language)")
            XCTAssertFalse(L10n.t(.searchTooltip, "x").contains("⇧⇧"), "\(language)")
        }
        L10n.current = .en
    }
}

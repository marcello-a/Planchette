import SwiftUI
import XCTest
@testable import Planchette

final class AppShortcutsTests: XCTestCase {
    func testTheDefaultsAreTheMenusKeysAndAllDifferent() {
        let combos = ShortcutAction.allCases.map(\.defaultCombo)
        XCTAssertEqual(Set(combos).count, combos.count, "two menu items with one key")
        XCTAssertEqual(ShortcutAction.newWindow.defaultCombo.label, "⇧⌘N")
        XCTAssertEqual(ShortcutAction.nextTab.defaultCombo.label, "⌥⌘→")
        XCTAssertEqual(ShortcutAction.projectPanel.defaultCombo.label, "⌃⌘S")
        for action in ShortcutAction.allCases {
            XCTAssertNil(ShortcutBook().refusal(of: action.defaultCombo, for: action, search: .default),
                         "\(action)'s default must be a key the book accepts")
        }
    }

    func testEveryActionIsInOneGroup() {
        XCTAssertEqual(ShortcutAction.Group.allCases.flatMap(\.actions).count, ShortcutAction.allCases.count)
    }

    func testAKeyBackToItsDefaultIsNoChange() {
        var book = ShortcutBook()
        book.set(KeyCombo("y", [.command]), for: .notepad)
        XCTAssertTrue(book.isChanged(.notepad))
        XCTAssertEqual(book.combo(for: .notepad)?.label, "⌘Y")
        book.set(ShortcutAction.notepad.defaultCombo, for: .notepad)
        XCTAssertFalse(book.isChanged(.notepad))
        XCTAssertTrue(book.isEmpty)
    }

    func testARemovedShortcutIsNone() {
        var book = ShortcutBook()
        book.set(nil, for: .splitDown)
        XCTAssertTrue(book.isChanged(.splitDown))
        XCTAssertNil(book.combo(for: .splitDown))
        XCTAssertNil(book.keyboardShortcut(for: .splitDown))
        book.reset(.splitDown)
        XCTAssertEqual(book.combo(for: .splitDown), ShortcutAction.splitDown.defaultCombo)
    }

    func testRefusals() {
        let book = ShortcutBook()
        XCTAssertEqual(book.refusal(of: KeyCombo("y", [.control]), for: .notepad, search: .default), .needsCommand)
        XCTAssertEqual(book.refusal(of: KeyCombo("y", [.option, .shift]), for: .notepad, search: .default), .needsCommand)
        XCTAssertEqual(book.refusal(of: KeyCombo("1", [.command, .shift]), for: .notepad, search: .default), .shiftNeedsLetter)
        XCTAssertNil(book.refusal(of: KeyCombo("left", [.command, .shift]), for: .previousTab, search: .default))
        XCTAssertEqual(book.refusal(of: KeyCombo("c", [.command]), for: .notepad, search: .default), .reserved)
        XCTAssertEqual(book.refusal(of: KeyCombo("3", [.command]), for: .notepad, search: .default), .reserved, "⌘3 is tab 3")
        XCTAssertEqual(book.refusal(of: KeyCombo("3", [.command, .option]), for: .notepad, search: .default), .reserved)
        XCTAssertEqual(book.refusal(of: KeyCombo("t", [.command]), for: .notepad, search: .default), .taken(.addTerminal))
        XCTAssertNil(book.refusal(of: KeyCombo("j", [.command]), for: .notepad, search: .default), "its own key")
        let search = SearchShortcut.chord(key: "p", modifiers: [.command, .shift])
        XCTAssertEqual(book.refusal(of: KeyCombo("p", [.shift, .command]), for: .notepad, search: search), .search)
    }

    func testAKeyAnotherActionGaveUpIsFree() {
        var book = ShortcutBook()
        book.set(KeyCombo("y", [.command]), for: .addTerminal)
        XCTAssertNil(book.refusal(of: KeyCombo("t", [.command]), for: .notepad, search: .default))
    }

    func testStoredAsReadableWordsAndReadBack() throws {
        var book = ShortcutBook()
        book.set(KeyCombo("p", [.shift, .command]), for: .quickSwitcher)
        book.set(KeyCombo("left", [.command, .control]), for: .previousTab)
        book.set(nil, for: .jira)
        let data = try JSONEncoder().encode(book)
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(raw, ["quickSwitcher": "shift+command:p", "previousTab": "control+command:left", "jira": ""])
        XCTAssertEqual(try JSONDecoder().decode(ShortcutBook.self, from: data), book)
    }

    func testAnUnknownEntryCostsOnlyItself() throws {
        let json = #"{"notepad": "command:y", "teleport": "command:x", "find": "hyper:q", "splitRight": "command"}"#
        let book = try JSONDecoder().decode(ShortcutBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.combo(for: .notepad)?.label, "⌘Y")
        XCTAssertFalse(book.isChanged(.find))
        XCTAssertFalse(book.isChanged(.splitRight))
    }

    func testAnOldWorkspaceHasTheDefaults() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"groups": [], "sessions": []}"#.utf8))
        XCTAssertTrue(state.shortcuts.isEmpty)
    }

    func testTextsNameTheNewKey() {
        var book = ShortcutBook()
        book.set(KeyCombo("y", [.command, .option]), for: .addTerminal)
        XCTAssertEqual(book.rewrite("Add a terminal (⌘T)"), "Add a terminal (⌥⌘Y)")
        XCTAssertEqual(book.rewrite("⌘T opens a new terminal"), "⌥⌘Y opens a new terminal")
        XCTAssertEqual(book.rewrite("Reopen (⌃⌘T)"), "Reopen (⌃⌘T)", "⌘T inside ⌃⌘T is another key")
        XCTAssertEqual(book.rewrite("New worktree (⌘⇧T)"), "New worktree (⌘⇧T)")
        XCTAssertEqual(book.rewrite("⌘Tab"), "⌘Tab")
    }

    func testTextsSpellTheKeyEitherWay() {
        var book = ShortcutBook()
        book.set(KeyCombo("p", [.command, .shift]), for: .newWindow)
        XCTAssertEqual(book.rewrite("Open a new window (⌘⇧N)"), "Open a new window (⇧⌘P)")
        XCTAssertEqual(book.rewrite("Open a new window (⇧⌘N)"), "Open a new window (⇧⌘P)")
    }

    func testARemovedKeyLeavesTheTooltip() {
        var book = ShortcutBook()
        book.set(nil, for: .splitRight)
        XCTAssertEqual(book.rewrite("A new terminal on the right (⌘D)"), "A new terminal on the right")
    }

    func testTwoSwappedKeysDoNotSwapBack() {
        var book = ShortcutBook()
        book.set(KeyCombo("d", [.command]), for: .addTerminal)
        book.set(KeyCombo("t", [.command]), for: .splitRight)
        XCTAssertEqual(book.rewrite("⌘T adds, ⌘D splits"), "⌘D adds, ⌘T splits")
    }

    func testNoChangeLeavesTextsAlone() {
        XCTAssertEqual(ShortcutBook().rewrite("⌘T opens a new terminal"), "⌘T opens a new terminal")
    }

    func testTheMenuGetsTheKey() {
        let shortcut = KeyCombo("left", [.command, .option]).keyboardShortcut
        XCTAssertEqual(shortcut.key, .leftArrow)
        XCTAssertEqual(shortcut.modifiers, [.command, .option])
        XCTAssertEqual(KeyCombo("Y", [.command]).keyboardShortcut.key, KeyEquivalent("y"))
    }
}

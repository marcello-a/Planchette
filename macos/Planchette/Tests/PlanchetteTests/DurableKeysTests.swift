import AppKit
import XCTest
@testable import Planchette

final class DurableKeysTests: XCTestCase {
    func testShiftReturnIsANewLine() {
        XCTAssertEqual(DurableKeys.action(keyCode: 36, flags: [.shift]), .newline)
        XCTAssertEqual(DurableKeys.action(keyCode: 76, flags: [.shift]), .newline, "the keypad's Enter too")
    }

    func testControlReturnSendsNow() {
        XCTAssertEqual(DurableKeys.action(keyCode: 36, flags: [.control]), .sendNow)
        XCTAssertEqual(DurableKeys.action(keyCode: 76, flags: [.control]), .sendNow)
    }

    func testOtherReturnsBelongToTheTerminal() {
        XCTAssertNil(DurableKeys.action(keyCode: 36, flags: []), "a plain Return submits")
        XCTAssertNil(DurableKeys.action(keyCode: 36, flags: [.option]))
        XCTAssertNil(DurableKeys.action(keyCode: 36, flags: [.command]), "⌘↩ is the notepad's")
        XCTAssertNil(DurableKeys.action(keyCode: 36, flags: [.control, .shift]))
        XCTAssertNil(DurableKeys.action(keyCode: 36, flags: [.shift, .option]))
    }

    func testOnlyReturnIsTranslated() {
        XCTAssertNil(DurableKeys.action(keyCode: 38, flags: [.control]), "⌃J itself stays ⌃J")
        XCTAssertNil(DurableKeys.action(keyCode: 48, flags: [.shift]), "⇧Tab cycles the mode")
    }

    func testDeviceFlagsDoNotMatter() {
        // Caps Lock and the numeric-pad flag ride along on real events.
        XCTAssertEqual(DurableKeys.action(keyCode: 76, flags: [.shift, .numericPad, .capsLock]), .newline)
    }

    func testTheKeysClaudeCodeKnows() {
        XCTAssertEqual(DurableKeys.Action.newline.presses.map(\.letter), ["j"], "chat:newline is ⌃J")
        XCTAssertEqual(DurableKeys.Action.sendNow.presses.map(\.letter), ["x", "s"], "chat:sendNow is ⌃X ⌃S")
        XCTAssertTrue(DurableKeys.Action.newline.repeats)
        XCTAssertFalse(DurableKeys.Action.sendNow.repeats)
    }
}

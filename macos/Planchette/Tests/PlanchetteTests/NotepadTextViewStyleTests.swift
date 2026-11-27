import AppKit
import XCTest
@testable import Planchette

/// The incremental look through the pad's real text view, as it is built in `NotepadEditor`
/// (TextKit 1, by hand): typing, deleting, pasting, undo and redo, and an input method's
/// composition — after each, the text must look exactly like a full restyle of it.
final class NotepadTextViewStyleTests: XCTestCase {
    /// The pad's text view and styler, wired as `NotepadEditor.Coordinator` wires them.
    final class Harness: NSObject, NSTextViewDelegate {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        let textView: NotepadTextView
        let styler = NotepadStyler()
        let undo = UndoManager()
        let look = NotepadStyle.Look(width: 280, returns: 2)

        init(_ text: String) {
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            textView = NotepadTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 400), textContainer: container)
            super.init()
            textView.isRichText = false
            textView.allowsUndo = true
            textView.smartInsertDeleteEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.string = text
            styler.attach(to: storage)
            textView.delegate = self
            styler.lookNow = { [unowned self] in self.lookNow() }
            textView.onUnmark = { [unowned self] in self.restyle() }        // as the coordinator wires it
            undo.groupsByEvent = false
            restyle()
        }

        /// The coordinator's `lookNow()`.
        func lookNow() -> NotepadStyle.Look? {
            textView.hasMarkedText() || textView.isSettingMarkedText ? nil : look
        }

        /// The coordinator's `restyle()`.
        func restyle() {
            guard let look = lookNow() else { return }
            styler.restyle(look: look)
            if let attributes = styler.attributes { textView.typingAttributes = attributes.plain }
            layout.ensureLayout(for: container)
        }

        func textDidChange(_ notification: Notification) { restyle() }
        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func step(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
            textView.breakUndoCoalescing()
        }

        func mismatch() -> String? {
            let reference = NSTextStorage(string: storage.string)
            NotepadStyleTests.OriginalRestyle.apply(to: reference, width: 280, returns: 2)
            storage.ensureAttributesAreFixed(in: NSRange(location: 0, length: storage.length))
            reference.ensureAttributesAreFixed(in: NSRange(location: 0, length: reference.length))
            return NotepadStyleTests.difference(storage, reference)
        }
    }

    private let notFound = NSRange(location: NSNotFound, length: 0)

    func testTypingDeletingAndUndoThroughTheTextView() {
        var rng = NotepadStyleTests.SeededGenerator(seed: NotepadStyleTests.baseSeed &+ 10)
        for documentIndex in 0..<8 {
            let text = NotepadStyleTests.document(lines: Int.random(in: 5...40, using: &rng), using: &rng)
            let pad = Harness(text)
            XCTAssertNil(pad.mismatch())
            var done = 0
            for stepIndex in 0..<80 {
                let ns = pad.storage.string as NSString
                let at = NotepadStyleTests.boundary(Int.random(in: 0...ns.length, using: &rng), in: ns)
                let roll = Int.random(in: 0..<10, using: &rng)
                var what = ""
                switch roll {
                case 0..<4:
                    let snippet = NotepadStyleTests.snippets.randomElement(using: &rng)!
                    what = "type \(NotepadStyleTests.escaped(snippet)) at \(at)"
                    pad.textView.setSelectedRange(NSRange(location: at, length: 0))
                    pad.step { for character in snippet { pad.textView.insertText(String(character), replacementRange: notFound) } }
                    done += 1
                case 4..<6:
                    what = "backspace ×3 at \(at)"
                    pad.textView.setSelectedRange(NSRange(location: at, length: 0))
                    pad.step { for _ in 0..<3 { pad.textView.deleteBackward(nil) } }
                    done += 1
                case 6:
                    let range = NotepadStyleTests.randomRange(in: ns, maxLength: 60, using: &rng)
                    let paste = NotepadStyleTests.document(lines: Int.random(in: 1...6, using: &rng), using: &rng)
                    what = "paste over \(range)"
                    pad.textView.setSelectedRange(range)
                    pad.step { pad.textView.insertText(paste, replacementRange: notFound) }
                    done += 1
                case 7, 8:
                    guard pad.undo.canUndo else { continue }
                    what = "undo"
                    pad.undo.undo()
                case _:
                    guard pad.undo.canRedo else { continue }
                    what = "redo"
                    pad.undo.redo()
                }
                if let problem = pad.mismatch() {
                    XCTFail("document \(documentIndex), step \(stepIndex) (\(what)): \(problem)\n"
                            + "text: \(NotepadStyleTests.escaped(pad.storage.string))")
                    return
                }
            }
            XCTAssertGreaterThan(done, 20)
        }
    }

    /// An input method's marked text is left as the text view put it in while the composition is
    /// open — nothing is drawn over it — and the result is drawn when it is committed. Composed
    /// inside `code`, it keeps the typing font until then, and gets the code font after.
    func testACompositionIsNotDrawnOverAndIsDrawnWhenCommitted() {
        let pad = Harness("# Head\n\nsome `code` here\n```swift\nlet x = 1\n```\n")
        let at = ("# Head\n\nsome `co" as NSString).length
        let typing = pad.textView.typingAttributes[.font] as? NSFont
        let code = pad.storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        XCTAssertNotEqual(typing, code)
        pad.textView.setSelectedRange(NSRange(location: at, length: 0))
        pad.undo.beginUndoGrouping()
        defer { pad.undo.endUndoGrouping() }
        for (index, composing) in ["k", "ka"].enumerated() {
            pad.textView.setMarkedText(composing, selectedRange: NSRange(location: index + 1, length: 0),
                                       replacementRange: notFound)
            XCTAssertTrue(pad.textView.hasMarkedText())
            let marked = pad.textView.markedRange()
            for location in marked.location..<NSMaxRange(marked) {
                XCTAssertEqual(pad.storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont, typing,
                               "nothing is drawn under the composition")
            }
            XCTAssertNotNil(pad.styler.pending, "the composition is kept to be drawn")
        }
        pad.textView.insertText("ka", replacementRange: notFound)            // committed
        XCTAssertFalse(pad.textView.hasMarkedText())
        pad.restyle()
        XCTAssertNil(pad.mismatch())
        XCTAssertNil(pad.styler.pending)
        XCTAssertEqual(pad.storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont, code)
    }

    /// A composition can end without a change of characters — a click elsewhere, the pad losing
    /// the keyboard: `unmarkText` keeps the marked text as typed. It is drawn then, not at the next key.
    func testACompositionEndedWithoutTypingIsDrawn() {
        let pad = Harness("# Head\n\nsome `code` here\n")
        let at = ("# Head\n\nsome `co" as NSString).length
        let code = pad.storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        pad.textView.setSelectedRange(NSRange(location: at, length: 0))
        pad.undo.beginUndoGrouping()
        defer { pad.undo.endUndoGrouping() }
        pad.textView.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0), replacementRange: notFound)
        XCTAssertNotNil(pad.styler.pending)
        XCTAssertNotNil(pad.mismatch(), "nothing drawn under the composition")
        pad.textView.unmarkText()
        XCTAssertFalse(pad.textView.hasMarkedText())
        XCTAssertNil(pad.styler.pending, "drawn when the composition ended")
        XCTAssertNil(pad.mismatch())
        XCTAssertEqual(pad.storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont, code)
    }

    /// A composition typed over a selection and then cancelled (Esc, its last letter deleted)
    /// ends inside `setMarkedText`; `unmarkText` then finds nothing marked. What it replaced —
    /// here the fence of a code block — is drawn when it ends, not at the next key.
    func testACancelledCompositionOverASelectionIsDrawn() {
        let pad = Harness("intro\n\n```swift\nlet x = 1\n```\n\nafter\n")
        let fence = (pad.storage.string as NSString).range(of: "```swift")
        pad.textView.setSelectedRange(NSRange(location: fence.location, length: 3))
        pad.undo.beginUndoGrouping()
        defer { pad.undo.endUndoGrouping() }
        pad.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: notFound)
        XCTAssertNotNil(pad.mismatch(), "nothing drawn under the composition")
        pad.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: notFound)
        XCTAssertFalse(pad.textView.hasMarkedText())
        XCTAssertNil(pad.styler.pending, "drawn when the composition was cancelled")
        XCTAssertNil(pad.mismatch())
        pad.textView.unmarkText()
        XCTAssertNil(pad.mismatch())
    }
}

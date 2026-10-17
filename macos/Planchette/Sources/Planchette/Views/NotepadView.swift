import AppKit
import SwiftUI

/// The way from a margin button to the text view: the button says a prompt was loaded, the text
/// view does what the setting says to it. The two sit side by side in SwiftUI and know nothing of
/// each other otherwise.
final class NotepadEditorHandle {
    var didLoad: ((NotepadRow) -> Void)?
}

/// The notepad of a terminal, as a strip at the right of the tab: a text view whose margin carries
/// a button for every line. A click loads the line into the terminal's prompt; ⌥ also presses
/// Return. One line is one prompt — it ends where the line does.
struct NotepadPanel: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    @State private var isEmpty: Bool
    /// Where the lines are, as the text view lays them out — the margin follows.
    @State private var rows: [NotepadRow] = []
    @State private var handle = NotepadEditorHandle()

    init(session: TerminalSession, text: String) {
        self.session = session
        _isEmpty = State(initialValue: text.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                Text(L10n.t(.notepadTitle, appState.tabName(for: session)))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    appState.notepad.isOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t(.notepadClose))
                .accessibilityLabel(L10n.t(.notepadClose))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            HStack(spacing: 0) {
                NotepadMargin(rows: rows, sessionID: session.id, handle: handle)
                ZStack(alignment: .topLeading) {
                    NotepadEditor(sessionID: session.id, isEmpty: $isEmpty, rows: $rows, handle: handle)
                    if isEmpty {
                        Text(L10n.t(.notepadPlaceholder, appState.notepad.returnsPerPrompt))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        // A pad belongs to one terminal: another terminal is another text, and the text view of the
        // one you left says goodbye (flushes, lets go of the keyboard) before this one appears.
        .id(session.id)
    }
}

/// The drag handle between the terminal and the pad. The width follows the pointer while it is
/// down and is stored when it is let go: a stored change redraws the window, a drag should not.
struct NotepadResizeHandle: View {
    @EnvironmentObject var appState: AppState
    /// The width the pad has now, as drawn.
    @Binding var live: Double?
    let available: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay(Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? NotepadLook.clamped(width: appState.notepad.width, in: available)
                        startWidth = start
                        // Dragging left makes the pad wider.
                        live = NotepadLook.clamped(width: start - drag.translation.width, in: available)
                    }
                    .onEnded { _ in
                        if let live { appState.notepad.width = live }
                        startWidth = nil
                        live = nil
                    }
            )
            .accessibilityLabel(L10n.t(.notepadResize))
    }
}

/// A prompt, and where its first line is in the pad: the margin puts its button there.
struct NotepadRow: Identifiable, Equatable {
    /// Where the line starts in the text.
    let id: Int
    let prompt: String
    /// The first row of the prompt, from the top of the pad's text area.
    let y: Double
    let height: Double
    /// Struck through: it was loaded already.
    var isDone = false
}

/// The margin: a ▶ at the first row of every prompt. A click loads the prompt into
/// the terminal's prompt; ⌥-click also presses Return. They are buttons, so they are in the
/// accessibility tree and in the tab order like any other.
struct NotepadMargin: View {
    @EnvironmentObject var appState: AppState
    let rows: [NotepadRow]
    let sessionID: UUID
    let handle: NotepadEditorHandle

    static let width: Double = 26

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.primary.opacity(0.05))
            ForEach(rows) { row in
                Button {
                    let submit = NSEvent.modifierFlags.contains(.option)
                    appState.loadPrompt(row.prompt, into: sessionID, submit: submit) { [handle] in
                        handle.didLoad?(row)
                    }
                } label: {
                    // A check where the prompt was loaded already; it can still be loaded again.
                    Image(systemName: row.isDone ? "checkmark" : "arrowtriangle.right.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.width, height: row.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t(.notepadLoadHelp))
                .accessibilityLabel(L10n.t(.notepadLoadLine))
                .accessibilityHint(row.prompt)
                .offset(y: row.y)
            }
        }
        .frame(width: Self.width)
        .clipped()
    }
}

/// The text view.
struct NotepadEditor: NSViewRepresentable {
    @EnvironmentObject var appState: AppState
    let sessionID: UUID
    @Binding var isEmpty: Bool
    @Binding var rows: [NotepadRow]
    let handle: NotepadEditorHandle

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let size = scroll.contentSize
        let textView = NotepadTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 8)

        // A prompt is typed text, character for character: nothing may be "corrected".
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.setAccessibilityLabel(L10n.t(.notepad))
        textView.string = appState.notepadText(for: sessionID)
        textView.delegate = context.coordinator
        scroll.documentView = textView

        textView.onLoadCurrentLine = { [weak coordinator = context.coordinator] in
            coordinator?.loadCurrentLine(submit: true)
        }
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }
        context.coordinator.attach(textView: textView, scroll: scroll)
        handle.didLoad = { [weak coordinator = context.coordinator] row in
            coordinator?.applyAfterLoading(row)
        }
        if appState.notepadWantsKeyboard {
            appState.notepadWantsKeyboard = false
            context.coordinator.takeKeyboard()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // The setting that says what ends a prompt changed: the buttons are somewhere else.
        if context.coordinator.returns != appState.notepad.returnsPerPrompt {
            context.coordinator.returns = appState.notepad.returnsPerPrompt
            DispatchQueue.main.async { context.coordinator.restyle(); context.coordinator.updateRows() }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotepadEditor
        weak var textView: NotepadTextView?
        weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        /// The number of Returns that ended a prompt when the margin was last worked out.
        var returns: Int

        init(_ parent: NotepadEditor) {
            self.parent = parent
            returns = parent.appState.notepad.returnsPerPrompt
        }

        func attach(textView: NotepadTextView, scroll: NSScrollView) {
            self.textView = textView
            self.scroll = scroll
            // The lines move when the text scrolls and when the pad changes width.
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView as NSView),
                                   (NSView.frameDidChangeNotification, scroll as NSView)] {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateRows() }
                })
            }
            // What this text view holds decides whether the placeholder shows — not what the panel
            // showed for the terminal before: the panel's state outlives a change of terminal.
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                let empty = textView.string.isEmpty
                if self.parent.isEmpty != empty { self.parent.isEmpty = empty }
                self.restyle()
                self.updateRows()
            }
        }

        /// Make the text view the first responder, once it is in a window — the view is built before
        /// SwiftUI has put it there, so this tries again a few times, and stops as soon as it holds.
        func takeKeyboard(attempt: Int = 0) {
            guard let textView else { return }
            if let window = textView.window, window.makeFirstResponder(textView), window.firstResponder === textView {
                return
            }
            guard attempt < 6 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(attempt + 1)) { [weak self] in
                self?.takeKeyboard(attempt: attempt + 1)
            }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            focusChanged(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.appState.setNotepad(textView.string, for: parent.sessionID)
            let empty = textView.string.isEmpty
            if parent.isEmpty != empty { parent.isEmpty = empty }
            restyle()
            updateRows()
        }

        /// The look of the text: the plain look, with a line through every prompt that is written
        /// as `~~…~~`. It is drawn, not stored — the file keeps plain text, and a restart gets
        /// the same look back from the marks.
        func restyle() {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let plain: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(plain, range: whole)
            for prompt in NotepadPrompts.prompts(in: textView.string, returns: parent.appState.notepad.returnsPerPrompt)
            where prompt.isDone {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: prompt.range)
            }
            storage.endEditing()
            textView.typingAttributes = plain
        }

        /// A prompt was loaded into the terminal: do what the setting says to it. The prompt is
        /// found again by its words, nearest to where it was — the pad can have changed since the
        /// click — and the change goes through the text view, so ⌘Z gives the prompt back.
        func applyAfterLoading(_ row: NotepadRow) {
            guard let textView else { return }
            let returns = parent.appState.notepad.returnsPerPrompt
            guard let prompt = NotepadPrompts.locate(row.prompt, near: row.id, in: textView.string, returns: returns),
                  let edit = NotepadPrompts.edit(
                    afterLoading: parent.appState.notepad.afterLoading, prompt, in: textView.string),
                  textView.shouldChangeText(in: edit.range, replacementString: edit.replacement)
            else { return }
            textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
        }

        /// Where the lines that hold a prompt are, from the top of what is shown.
        func updateRows() {
            guard let textView, let scroll, let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let length = (textView.string as NSString).length
            let origin = textView.textContainerOrigin
            let visibleTop = scroll.contentView.bounds.minY
            let shown = scroll.contentView.bounds.height
            let rows: [NotepadRow] = NotepadPrompts.prompts(in: textView.string, returns: parent.appState.notepad.returnsPerPrompt).compactMap { line in
                guard line.range.location < length else { return nil }
                let glyph = layout.glyphIndexForCharacter(at: line.range.location)
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let y = fragment.minY + origin.y - visibleTop
                guard y + fragment.height > -20, y < shown + 20 else { return nil }
                return NotepadRow(id: line.range.location, prompt: line.text, y: y, height: fragment.height,
                                  isDone: line.isDone)
            }
            if rows != parent.rows { parent.rows = rows }
        }

        func focusChanged(_ focused: Bool) {
            parent.appState.notepadEditing = focused
        }

        /// ⌘↩: the prompt the insertion point is in, and Return after it.
        func loadCurrentLine(submit: Bool) {
            guard let textView,
                  let prompt = NotepadPrompts.promptValue(
                    at: textView.selectedRange().location, in: textView.string,
                    returns: parent.appState.notepad.returnsPerPrompt)
            else { return }
            let row = NotepadRow(id: prompt.range.location, prompt: prompt.text, y: 0, height: 0, isDone: prompt.isDone)
            parent.appState.loadPrompt(prompt.text, into: parent.sessionID, submit: submit) { [weak self] in
                self?.applyAfterLoading(row)
            }
        }
    }
}

/// The text view: ⌘↩ loads the current line and presses Return, and it says when it has the
/// keyboard (see `AppState.notepadEditing`).
final class NotepadTextView: NSTextView {
    var onLoadCurrentLine: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onLoadCurrentLine?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

import AppKit
import SwiftUI

/// The way from a margin button to the text view: the button says a prompt was loaded, the text
/// view does what the setting says to it. The two sit side by side in SwiftUI and know nothing of
/// each other otherwise.
final class NotepadEditorHandle {
    var didLoad: ((NotepadRow) -> Void)?
    /// The text as the text view holds it now.
    var text: (() -> String)?
    /// Put a new text in place of the whole pad (Format with AI), so ⌘Z gives the old one back.
    /// False when there is no text view any more.
    var replaceAll: ((String) -> Bool)?
    /// Put text from the history back, at the end of the pad, as a prompt of its own.
    var insert: ((String) -> Void)?
    /// Lock the pad while the AI formats it: what is typed then would be lost.
    var setEditable: ((Bool) -> Void)?
    var convertSuggestion: (() -> Void)?
    var dismissSuggestion: (() -> Void)?
    /// The text view asks for one code block to be formatted (its context menu): the code, its
    /// language, and where the code is. The panel runs it, as it runs "Format with AI".
    var formatCode: ((String, String?, NSRange) -> Void)?
    /// Put formatted code in place of `range`, when that still holds the code that was sent.
    var replaceCode: ((NSRange, String, String) -> Bool)?
}

/// The notepad of a terminal, as a strip at the right of the tab: a text view whose margin carries
/// two buttons for every prompt: one adds it to the terminal as a draft, one adds it and presses
/// Return. Its menu formats the pad with AI, shows what left it, and closes it.
struct NotepadPanel: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    @State private var isEmpty: Bool
    /// Where the lines are, as the text view lays them out — the margin follows.
    @State private var rows: [NotepadRow] = []
    @State private var handle = NotepadEditorHandle()
    /// Lines that look like code, in the prompt the insertion point is in: the bar offers a block.
    @State private var suggestion: NotepadCode.Suggestion?
    @State private var showsHistory = false
    @State private var formatting = false
    @State private var formatFailed = false

    init(session: TerminalSession, text: String) {
        self.session = session
        _isEmpty = State(initialValue: text.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                NotepadMargin(rows: rows, sessionID: session.id, handle: handle)
                ZStack(alignment: .topLeading) {
                    NotepadEditor(sessionID: session.id, isEmpty: $isEmpty, rows: $rows, suggestion: $suggestion,
                                  handle: handle)
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
            if formatFailed {
                Divider()
                Label(L10n.t(.notepadFormatFailed), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
            }
            if let suggestion {
                Divider()
                suggestionBar(suggestion)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .onAppear {
            handle.formatCode = { code, language, range in formatCode(code, language: language, at: range) }
        }
        // A pad belongs to one terminal: another terminal is another text, and the text view of the
        // one you left says goodbye (flushes, lets go of the keyboard) before this one appears.
        .id(session.id)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text").foregroundStyle(.secondary)
            Text(L10n.t(.notepadTitle, appState.tabName(for: session)))
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if formatting {
                ProgressView().controlSize(.mini)
                    .help(L10n.t(.notepadFormatting))
                    .accessibilityLabel(L10n.t(.notepadFormatting))
            }
            menu
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private var menu: some View {
        Menu {
            Button { format() } label: { Label(L10n.t(.notepadFormat), systemImage: "wand.and.stars") }
                .disabled(isEmpty || formatting)
            Button { showsHistory = true } label: {
                Label(L10n.t(.notepadHistory), systemImage: "clock.arrow.circlepath")
            }
            Divider()
            Button { appState.notepad.setOpen(false, for: session.id) } label: {
                Label(L10n.t(.notepadClose), systemImage: "xmark")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
                // The menu button can take its name from its label, so the label carries the name too.
                .accessibilityLabel(L10n.t(.notepadMenu))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t(.notepadMenu))
        .accessibilityLabel(L10n.t(.notepadMenu))
        .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
            NotepadHistoryView(sessionID: session.id) { text in
                handle.insert?(text)
                showsHistory = false
            }
            .environmentObject(appState)
        }
    }

    private func suggestionBar(_ suggestion: NotepadCode.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(suggestion.language.map { L10n.t(.notepadCodeSuggestionLanguage, NotepadCode.displayName(of: $0)) }
                    ?? L10n.t(.notepadCodeSuggestion),
                  systemImage: "curlybraces")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(L10n.t(.notepadCodeDismiss)) { handle.dismissSuggestion?() }
                Button(L10n.t(.notepadCodeConvert)) { handle.convertSuggestion?() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    /// The whole pad, tidied by Claude. The pad is locked meanwhile; the text from before goes into
    /// the history, and ⌘Z brings it back as well.
    private func format() {
        guard let original = handle.text?(),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let returns = appState.notepad.returnsPerPrompt
        let id = session.id
        runAI { await AIAssist.formatNotepad(original, returns: returns) } apply: { result in
            guard result != original else { return }
            appState.recordNotepad(.formatted, original, for: id)
            // The pad was closed meanwhile: the text is changed where it is kept, if it is the same.
            if handle.replaceAll?(result) != true, appState.notepadText(for: id) == original {
                appState.setNotepad(result, for: id)
            }
        }
    }

    /// One code block, laid out by Claude; only its code changes, the fences stay.
    private func formatCode(_ code: String, language: String?, at range: NSRange) {
        let id = session.id
        runAI { await AIAssist.formatCode(code, language: language) } apply: { result in
            guard result != code, handle.replaceCode?(range, code, result) == true else { return }
            appState.recordNotepad(.formatted, code, for: id)
        }
    }

    /// An AI run over the pad: one at a time, the pad locked and the spinner on meanwhile, and a
    /// line that says so when nothing came back.
    private func runAI(_ work: @escaping @MainActor () async -> String?, apply: @escaping @MainActor (String) -> Void) {
        guard !formatting else { return }
        formatting = true
        formatFailed = false
        handle.setEditable?(false)
        Task { @MainActor in
            let result = await work()
            formatting = false
            handle.setEditable?(true)
            guard let result else {
                formatFailed = true
                try? await Task.sleep(for: .seconds(6))
                formatFailed = false
                return
            }
            apply(result)
        }
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

/// The margin: two buttons at the first row of every prompt. The first adds the prompt to the
/// terminal as a draft (it waits for you to press Return); the second adds it and presses Return.
/// They are buttons, so they are in the accessibility tree and in the tab order like any other.
struct NotepadMargin: View {
    @EnvironmentObject var appState: AppState
    let rows: [NotepadRow]
    let sessionID: UUID
    let handle: NotepadEditorHandle

    static let buttonWidth: Double = 22
    static let width: Double = buttonWidth * 2

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.primary.opacity(0.05))
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    // A check where the prompt was loaded already; it can still be loaded again.
                    button(row, submit: false, icon: row.isDone ? "checkmark" : "arrow.down.to.line",
                           label: .notepadLoadLine, help: .notepadLoadHelp)
                    button(row, submit: true, icon: "return", label: .notepadRunLine, help: .notepadRunHelp)
                }
                .offset(y: row.y)
            }
        }
        .frame(width: Self.width)
        .clipped()
    }

    private func button(_ row: NotepadRow, submit: Bool, icon: String, label: LKey, help: LKey) -> some View {
        Button {
            appState.loadPrompt(row.prompt, into: sessionID, submit: submit) { [handle] in
                handle.didLoad?(row)
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.buttonWidth, height: row.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(label))
        .accessibilityHint(row.prompt)
    }
}

/// A fenced block as the pad shows it: folded after two lines, opened by a click, or open because
/// the insertion point is in it.
struct NotepadFold: Equatable {
    enum State: Equatable {
        /// Two lines shown; the closing fence row says how many more there are.
        case folded
        /// Opened by a click; the closing fence row folds it again.
        case opened
        /// The insertion point is in it: all of it, fences as typed, nothing drawn over them.
        case editing
    }

    /// The block's text: which block was opened by a click. Changed text is another block.
    let key: String
    /// The closing fence line: the row the label is drawn in.
    let close: NSRange
    /// What is hidden while folded.
    let hidden: NSRange
    let hiddenLines: Int
    let state: State
}

/// Hides the folded lines of code blocks: their characters get no glyphs and their line breaks
/// no line, so the closing fence follows the second line. The text stays as it is — what goes
/// into the terminal is all of it.
final class NotepadFolding: NSObject, NSLayoutManagerDelegate {
    var hidden: [NSRange] = []

    func isHidden(_ index: Int) -> Bool {
        hidden.contains { NSLocationInRange(index, $0) }
    }

    /// The hidden ranges after an edit, before the pad works them out again: the ones after it
    /// move along, the one it touches is dropped (and shown).
    func shift(for range: NSRange, replacementLength: Int) {
        let delta = replacementLength - range.length
        hidden = hidden.compactMap { h in
            if NSMaxRange(range) <= h.location { return NSRange(location: h.location + delta, length: h.length) }
            if range.location >= NSMaxRange(h) { return h }
            return nil
        }
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
        font: NSFont, forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hidden.isEmpty,
              (0..<glyphRange.length).contains(where: { isHidden(characterIndexes[$0]) }) else { return 0 }
        let changed = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        defer { changed.deallocate() }
        for index in 0..<glyphRange.length {
            var property = properties[index]
            if isHidden(characterIndexes[index]) { property.insert(.null) }
            changed[index] = property
        }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font,
                                forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isHidden(charIndex) ? .zeroAdvancement : action
    }
}

/// The text view.
struct NotepadEditor: NSViewRepresentable {
    @EnvironmentObject var appState: AppState
    let sessionID: UUID
    @Binding var isEmpty: Bool
    @Binding var rows: [NotepadRow]
    @Binding var suggestion: NotepadCode.Suggestion?
    let handle: NotepadEditorHandle

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // TextKit 1, built by hand: folding a code block needs a layout manager and its delegate.
        let size = scroll.contentSize
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.delegate = context.coordinator.folding
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = NotepadTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
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
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.setAccessibilityLabel(L10n.t(.notepad))
        textView.string = appState.notepadText(for: sessionID)
        textView.delegate = context.coordinator
        scroll.documentView = textView

        let coordinator = context.coordinator
        textView.onLoadCurrentLine = { [weak coordinator] in coordinator?.loadCurrentLine(submit: true) }
        textView.onFocusChange = { [weak coordinator] focused in coordinator?.focusChanged(focused) }
        textView.onNewline = { [weak coordinator] in coordinator?.newline() ?? false }
        textView.onTab = { [weak coordinator] outdent in coordinator?.tab(outdent: outdent) ?? false }
        textView.onClick = { [weak coordinator] point, command in coordinator?.click(at: point, command: command) ?? false }
        textView.onMarks = { [weak coordinator] mark in coordinator?.marks(mark) ?? false }
        textView.onPaste = { [weak coordinator] pasted in coordinator?.pasteLink(pasted) ?? false }
        textView.extraMenuItems = { [weak coordinator] index in coordinator?.menuItems(at: index) ?? [] }
        coordinator.attach(textView: textView, scroll: scroll)
        handle.didLoad = { [weak coordinator] row in coordinator?.applyAfterLoading(row) }
        handle.text = { [weak coordinator] in coordinator?.textView?.string ?? "" }
        handle.replaceAll = { [weak coordinator] text in coordinator?.replaceAll(with: text) ?? false }
        handle.insert = { [weak coordinator] text in coordinator?.insertFromHistory(text) }
        handle.setEditable = { [weak coordinator] editable in coordinator?.textView?.isEditable = editable }
        handle.convertSuggestion = { [weak coordinator] in coordinator?.convertSuggestion() }
        handle.dismissSuggestion = { [weak coordinator] in coordinator?.dismissSuggestion() }
        handle.replaceCode = { [weak coordinator] range, old, new in
            coordinator?.replaceCode(in: range, old: old, with: new) ?? false
        }
        if appState.notepadWantsKeyboard {
            appState.notepadWantsKeyboard = false
            coordinator.takeKeyboard()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // The setting that says what ends a prompt changed: the buttons are somewhere else.
        if context.coordinator.returns != appState.notepad.returnsPerPrompt {
            context.coordinator.returns = appState.notepad.returnsPerPrompt
            DispatchQueue.main.async { context.coordinator.refresh() }
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
        let folding = NotepadFolding()
        private var observers: [NSObjectProtocol] = []
        /// The number of Returns that ended a prompt when the margin was last worked out.
        var returns: Int
        /// Blocks opened by a click, by their text.
        private var opened: Set<String> = []
        /// Code suggestions turned down, by their first line.
        private var dismissed: Set<String> = []
        /// An edit the pad makes itself (a list going on, a prompt leaving): not a deletion of yours.
        private var editingItself = false
        /// Characters deleted one key at a time, not weighed yet (`NotepadHistory.Run`).
        private var deletions: NotepadHistory.Run?
        private var hasFocus = false

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
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // A narrower or wider pad draws the text at another size.
                        let width = Double(self.scroll?.frame.width ?? 0)
                        if NotepadMarkdown.bodySize(forWidth: width) != self.appliedSize { self.restyle() }
                        self.updateRows()
                    }
                })
            }
            // What this text view holds decides whether the placeholder shows — not what the panel
            // showed for the terminal before: the panel's state outlives a change of terminal.
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                let empty = textView.string.isEmpty
                if self.parent.isEmpty != empty { self.parent.isEmpty = empty }
                self.refresh()
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
            weighDeletions()
            focusChanged(false)
        }

        /// Everything the text decides: the look, the folds, the margin, the code suggestion.
        func refresh() {
            restyle()
            updateFolds()
            updateRows()
            updateSuggestion()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.appState.setNotepad(textView.string, for: parent.sessionID)
            let empty = textView.string.isEmpty
            if parent.isEmpty != empty { parent.isEmpty = empty }
            refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            // The insertion point went somewhere else: the deleting is over.
            if let run = deletions, textView.selectedRange().location != run.location { weighDeletions() }
            updateFolds()
            updateSuggestion()
        }

        // MARK: History

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            folding.shift(for: range, replacementLength: (replacementString as NSString?)?.length ?? 0)
            guard !editingItself, let replacement = replacementString,
                  !(textView.undoManager?.isUndoing ?? false), !(textView.undoManager?.isRedoing ?? false)
            else { return true }
            let text = textView.string as NSString
            let removed = text.substring(with: range)
            guard !removed.isEmpty else {
                weighDeletions()
                return true
            }
            // One key, one character: it joins the run of keys before it, and is weighed with it.
            if replacement.isEmpty, removed.count == 1 {
                if let run = deletions?.adding(removed, at: range) {
                    deletions = run
                } else {
                    weighDeletions()
                    deletions = NotepadHistory.Run(location: range.location, text: removed)
                }
                return true
            }
            weighDeletions()
            // A selection deleted, typed over or cut: all of its line went when nothing but blanks is
            // left around it.
            let line = text.lineRange(for: range)
            let before = text.substring(with: NSRange(location: line.location, length: range.location - line.location))
            let after = text.substring(with: NSRange(location: NSMaxRange(range),
                                                     length: max(NSMaxRange(line) - NSMaxRange(range), 0)))
            let whole = before.trimmingCharacters(in: .whitespaces).isEmpty
                && after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let kept = NotepadHistory.worthKeeping(removed, lineIsLeftBlank: whole) {
                parent.appState.recordNotepad(.deleted, kept, for: parent.sessionID)
            }
            return true
        }

        /// The run of single deletions is over: keep it when it was worth it.
        private func weighDeletions() {
            guard let run = deletions, let textView else { return }
            deletions = nil
            let text = textView.string as NSString
            let location = min(run.location, text.length)
            let line = text.substring(with: text.lineRange(for: NSRange(location: location, length: 0)))
            let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let kept = NotepadHistory.worthKeeping(run.text, lineIsLeftBlank: blank) {
                parent.appState.recordNotepad(.deleted, kept, for: parent.sessionID)
            }
        }

        // MARK: Edits the pad makes

        /// One change through the text view, so ⌘Z takes it back; the insertion point goes where
        /// the change says.
        @discardableResult
        private func apply(_ change: NotepadEditing.Change) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            editingItself = true
            defer { editingItself = false }
            guard textView.shouldChangeText(in: change.range, replacementString: change.replacement) else { return false }
            storage.replaceCharacters(in: change.range, with: NSAttributedString(
                string: change.replacement, attributes: textView.typingAttributes))
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: min(change.caret, storage.length), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            return true
        }

        /// Return: a list goes on, an empty item ends it, code keeps its indent, a fence closes.
        func newline() -> Bool {
            guard let textView, !textView.hasMarkedText(), textView.selectedRange().length == 0,
                  let change = NotepadEditing.newline(at: textView.selectedRange().location, in: textView.string)
            else { return false }
            return apply(change)
        }

        /// Tab and Shift-Tab on a list item move it in and out.
        func tab(outdent: Bool) -> Bool {
            guard let textView, !textView.hasMarkedText() else { return false }
            let selection = textView.selectedRange()
            let text = textView.string as NSString
            // Within one line only: a selection over several lines types a tab as always.
            guard text.lineRange(for: NSRange(location: selection.location, length: 0))
                    == text.lineRange(for: selection) || selection.length == 0,
                  let change = NotepadEditing.indent(at: selection.location, in: textView.string, outdent: outdent)
            else { return false }
            return apply(change)
        }

        /// A click on a task box ticks it; on the row under a folded block, opens it (or folds it);
        /// ⌘-click on a link opens its address.
        func click(at point: NSPoint, command: Bool) -> Bool {
            guard let textView else { return false }
            if command {
                let index = textView.characterIndexForInsertion(at: point)
                guard let url = NotepadMarkdown.link(at: index, in: textView.string) else { return false }
                NSWorkspace.shared.open(url)
                return true
            }
            for fold in textView.folds where fold.state != .editing {
                guard let rect = textView.labelRect(for: fold), rect.contains(point) else { continue }
                if fold.state == .folded { opened.insert(fold.key) } else { opened.remove(fold.key) }
                updateFolds()
                updateRows()
                return true
            }
            let index = textView.characterIndexForInsertion(at: point)
            guard let change = NotepadEditing.toggleTask(at: index, in: textView.string) else { return false }
            let selection = textView.selectedRange()
            apply(change)
            textView.setSelectedRange(selection)
            return true
        }

        /// ⌘B, ⌘I, ⌘E, or a backtick typed over a selection: the marks go on, or come off.
        func marks(_ mark: String) -> Bool {
            guard let textView, textView.isEditable, !textView.hasMarkedText(),
                  let change = NotepadEditing.toggleMarks(mark, around: textView.selectedRange(), in: textView.string)
            else { return false }
            let selection = textView.selectedRange()
            guard apply(change) else { return false }
            // What was selected stays selected, inside its new marks — ⌘B then ⌘I makes it both.
            if selection.length > 0 {
                let inner = (change.replacement as NSString).length
                let width = (mark as NSString).length
                let wrapped = inner > change.range.length
                textView.setSelectedRange(wrapped
                    ? NSRange(location: change.range.location + width, length: inner - 2 * width)
                    : NSRange(location: change.range.location, length: inner))
            }
            return true
        }

        /// A web address pasted over selected words makes a link of them.
        func pasteLink(_ pasted: String) -> Bool {
            guard let textView, textView.isEditable,
                  let change = NotepadEditing.link(pasting: pasted, over: textView.selectedRange(), in: textView.string)
            else { return false }
            return apply(change)
        }

        /// What the context menu adds at `index`: the marks for a selection, and in a code block,
        /// "Format code with AI".
        func menuItems(at index: Int) -> [NSMenuItem] {
            guard let textView, textView.isEditable else { return [] }
            var items: [NSMenuItem] = []
            if let block = NotepadCode.blocks(in: textView.string).first(where: {
                NSLocationInRange(index, $0.range) || index == NSMaxRange($0.range)
            }), let first = block.lines.first, let last = block.lines.last {
                let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                let code = (textView.string as NSString).substring(with: range)
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(ClosureMenuItem(title: L10n.t(.notepadFormatCode)) { [weak self] in
                        self?.parent.handle.formatCode?(code, block.language, range)
                    })
                }
            }
            if textView.selectedRange().length > 0 {
                for (key, mark, letter) in [(LKey.notepadBold, "**", "b"), (.notepadItalic, "*", "i"),
                                            (.notepadInlineCode, "`", "e")] {
                    let item = ClosureMenuItem(title: L10n.t(key)) { [weak self] in _ = self?.marks(mark) }
                    item.keyEquivalent = letter
                    item.keyEquivalentModifierMask = .command
                    items.append(item)
                }
            }
            return items
        }

        /// Formatted code in place of the code that was sent, if it is still there.
        func replaceCode(in range: NSRange, old: String, with new: String) -> Bool {
            guard let textView, NSMaxRange(range) <= (textView.string as NSString).length,
                  (textView.string as NSString).substring(with: range) == old else { return false }
            return apply(NotepadEditing.Change(range: range, replacement: new,
                                               caret: range.location + (new as NSString).length))
        }

        func replaceAll(with text: String) -> Bool {
            guard let textView else { return false }
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            return apply(NotepadEditing.Change(range: whole, replacement: text, caret: 0))
        }

        /// Text from the history, back at the end of the pad, as a prompt of its own.
        func insertFromHistory(_ text: String) {
            guard let textView else { return }
            let current = textView.string as NSString
            let trimmedEnd = (textView.string as NSString).length
                - (textView.string.reversed().prefix { $0.isNewline }.count)
            let gap = current.length == 0 ? "" : String(repeating: "\n", count: parent.appState.notepad.returnsPerPrompt)
            let range = NSRange(location: max(trimmedEnd, 0), length: current.length - max(trimmedEnd, 0))
            let replacement = gap + text
            apply(NotepadEditing.Change(range: range, replacement: replacement,
                                        caret: range.location + (replacement as NSString).length))
            takeKeyboard()
        }

        // MARK: Code

        func convertSuggestion() {
            guard let textView, let suggestion = parent.suggestion else { return }
            apply(NotepadCode.fence(suggestion, in: textView.string))
            takeKeyboard()
        }

        func dismissSuggestion() {
            guard let suggestion = parent.suggestion, let textView else { return }
            dismissed.insert(Self.key(of: suggestion, in: textView.string))
            parent.suggestion = nil
        }

        private static func key(of suggestion: NotepadCode.Suggestion, in text: String) -> String {
            let ns = text as NSString
            return ns.substring(with: ns.lineRange(for: NSRange(location: suggestion.range.location, length: 0)))
        }

        /// The stretch of code in the prompt the insertion point is in, unless it was turned down.
        func updateSuggestion() {
            guard let textView else { return }
            let text = textView.string
            var found: NotepadCode.Suggestion?
            if textView.isEditable,
               let prompt = NotepadPrompts.promptValue(at: textView.selectedRange().location, in: text,
                                                       returns: parent.appState.notepad.returnsPerPrompt),
               !prompt.isDone,
               let candidate = NotepadCode.suggestion(within: prompt.range, of: text),
               !dismissed.contains(Self.key(of: candidate, in: text)) {
                found = candidate
            }
            if parent.suggestion != found { parent.suggestion = found }
        }

        /// Which blocks are folded: every closed one longer than two lines, but the one you are
        /// writing in and the ones opened by a click.
        func updateFolds() {
            guard let textView, let layout = textView.layoutManager else { return }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            let folds: [NotepadFold] = NotepadCode.blocks(in: textView.string).compactMap { block in
                guard let close = block.close, let hidden = NotepadCode.foldedRange(of: block) else { return nil }
                let range = block.range
                let key = text.substring(with: range)
                let inside = hasFocus && selection.location >= range.location
                    && selection.location <= NSMaxRange(range)
                let state: NotepadFold.State = inside ? .editing : opened.contains(key) ? .opened : .folded
                return NotepadFold(key: key, close: close, hidden: hidden,
                                   hiddenLines: NotepadCode.hiddenLineCount(of: block), state: state)
            }
            // A block opened by a click whose text is gone is forgotten.
            opened.formIntersection(folds.map(\.key))
            let hidden = folds.filter { $0.state == .folded }.map(\.hidden)
            let whole = NSRange(location: 0, length: text.length)
            if hidden != folding.hidden {
                folding.hidden = hidden
                layout.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
                layout.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
            }
            // The closing fence of a block that is not being written makes room for its label.
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            for fold in folds where fold.state != .editing {
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: fold.close)
            }
            if textView.folds != folds {
                textView.folds = folds
                textView.needsDisplay = true
            }
        }

        // MARK: Look

        /// The body size the text was last drawn at: it follows the width of the pad.
        private var appliedSize: Double = 0

        /// The look of the text: Markdown (headlines, lists, tasks, quotes, code, bold, italic — see
        /// `NotepadMarkdown`), code in small type with colours (`NotepadCode`), and a line through
        /// every prompt written as `~~…~~`. It is drawn, not stored — the file keeps the text as
        /// typed, and a restart gets the same look back.
        func restyle() {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let width = Double(scroll?.frame.width ?? 0)
            let size = NotepadMarkdown.bodySize(forWidth: width)
            appliedSize = size
            let body = NSFont.systemFont(ofSize: size)
            let mono = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
            let code = NSFont.monospacedSystemFont(ofSize: (size * 0.85).rounded(), weight: .regular)
            let spacing = NotepadMarkdown.lineSpacing(forBodySize: size)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            let codeParagraph = NSMutableParagraphStyle()
            codeParagraph.lineSpacing = 1
            codeParagraph.tabStops = []
            codeParagraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: code]).width
            let plain: [NSAttributedString.Key: Any] = [
                .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            let text = textView.string as NSString
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(plain, range: whole)
            func derive(_ range: NSRange, _ change: (NSFont) -> NSFont) {
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    storage.addAttribute(.font, value: change(value as? NSFont ?? body), range: sub)
                }
            }
            for span in NotepadMarkdown.spans(in: textView.string) where NSMaxRange(span.range) <= storage.length {
                switch span.style {
                case .heading(let level):
                    let big = NSFont.systemFont(
                        ofSize: size * NotepadMarkdown.headingScale(level: level, forWidth: width), weight: .bold)
                    storage.addAttribute(.font, value: big, range: span.range)
                case .codeBlock:
                    storage.addAttributes([.font: code, .paragraphStyle: codeParagraph], range: span.range)
                case .inlineCode:
                    storage.addAttributes([
                        .font: mono, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                    ], range: span.range)
                case .bold:
                    derive(span.range) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
                case .italic:
                    derive(span.range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
                case .quote:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
                case .mark:
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
                case .listItem(let prefix):
                    // A wrapped line of an item lines up under its words, not under its bullet.
                    let lead = text.substring(with: NSRange(location: span.range.location, length: prefix))
                    let indent = (lead as NSString).size(withAttributes: [.font: body]).width
                    let item = NSMutableParagraphStyle()
                    item.lineSpacing = spacing
                    item.headIndent = indent
                    storage.addAttribute(.paragraphStyle, value: item, range: span.range)
                case .taskBox(let checked):
                    storage.addAttributes([
                        .font: mono,
                        .foregroundColor: checked ? NSColor.systemGreen : NSColor.secondaryLabelColor,
                    ], range: span.range)
                case .doneTask:
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ], range: span.range)
                case .link:
                    storage.addAttributes([
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: span.range)
                }
            }
            for block in NotepadCode.blocks(in: textView.string) {
                for line in block.lines where NSMaxRange(line) <= storage.length {
                    for token in NotepadCode.tokens(in: text.substring(with: line), language: block.language) {
                        let range = NSRange(location: line.location + token.range.location, length: token.range.length)
                        storage.addAttribute(.foregroundColor, value: Self.color(of: token.token), range: range)
                    }
                }
            }
            for prompt in NotepadPrompts.prompts(in: textView.string, returns: parent.appState.notepad.returnsPerPrompt)
            where prompt.isDone {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: prompt.range)
            }
            storage.endEditing()
            textView.typingAttributes = plain
            textView.codeBlocks = NotepadCode.blocks(in: textView.string).map(\.range)
            textView.labelFont = NSFont.systemFont(ofSize: (size * 0.8).rounded(), weight: .medium)
            textView.needsDisplay = true
        }

        /// The colours of code, close to what an editor shows; system colours, so they hold in light
        /// and dark mode.
        private static func color(of token: NotepadCode.Token) -> NSColor {
            switch token {
            case .keyword: .systemPink
            case .string: .systemRed
            case .comment: .secondaryLabelColor
            case .number: .systemBlue
            case .type: .systemPurple
            }
        }

        // MARK: Prompts

        /// A prompt was loaded into the terminal: do what the setting says to it. The prompt is
        /// found again by its words, nearest to where it was — the pad can have changed since the
        /// click — and the change goes through the text view, so ⌘Z gives the prompt back.
        func applyAfterLoading(_ row: NotepadRow) {
            guard let textView else { return }
            let returns = parent.appState.notepad.returnsPerPrompt
            guard let prompt = NotepadPrompts.locate(row.prompt, near: row.id, in: textView.string, returns: returns),
                  let edit = NotepadPrompts.edit(
                    afterLoading: parent.appState.notepad.afterLoading, prompt, in: textView.string)
            else { return }
            editingItself = true
            defer { editingItself = false }
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
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
            let clip = scroll.contentView
            let visibleTop = clip.bounds.minY
            let shown = clip.bounds.height
            let rows: [NotepadRow] = NotepadPrompts.prompts(in: textView.string, returns: parent.appState.notepad.returnsPerPrompt).compactMap { line in
                // A prompt in the folded part of a block has no row of its own to put buttons at.
                guard line.range.location < length, !folding.isHidden(line.range.location) else { return nil }
                let glyph = layout.glyphIndexForCharacter(at: line.range.location)
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                // Through the clip view: the text view need not sit at its top (it was seen at -255
                // after the pad got shorter), and only the clip's own coordinates say what is shown.
                let y = textView.convert(NSPoint(x: 0, y: fragment.minY + origin.y), to: clip).y - visibleTop
                guard y + fragment.height > -20, y < shown + 20 else { return nil }
                return NotepadRow(id: line.range.location, prompt: line.text, y: y, height: fragment.height,
                                  isDone: line.isDone)
            }
            if rows != parent.rows { parent.rows = rows }
        }

        func focusChanged(_ focused: Bool) {
            parent.appState.notepadEditing = focused
            guard hasFocus != focused else { return }
            hasFocus = focused
            if !focused { weighDeletions() }
            // A block you were writing in folds when you leave the pad, and opens when you come back.
            updateFolds()
            updateRows()
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

/// The text view: ⌘↩ loads the current line and presses Return, Return and Tab go to the pad's
/// Markdown rules first, and it says when it has the keyboard (see `AppState.notepadEditing`). It
/// draws the box behind code blocks and the label of a folded one.
final class NotepadTextView: NSTextView {
    var onLoadCurrentLine: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// Return: true when the pad did something of its own.
    var onNewline: (() -> Bool)?
    /// Tab, or Shift-Tab (`true`).
    var onTab: ((Bool) -> Bool)?
    /// A click, and whether ⌘ was down.
    var onClick: ((NSPoint, Bool) -> Bool)?
    /// Marks around the selection: `**`, `*` or `` ` ``.
    var onMarks: ((String) -> Bool)?
    /// A paste: true when the pad made something of its own of it (a link).
    var onPaste: ((String) -> Bool)?
    /// The pad's own items at the top of the context menu, for the character clicked at.
    var extraMenuItems: ((Int) -> [NSMenuItem])?
    /// The fenced blocks, fences included: each gets a box behind it.
    var codeBlocks: [NSRange] = []
    var folds: [NotepadFold] = []
    var labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onLoadCurrentLine?()
            return true
        }
        if window?.firstResponder === self, flags == .command,
           let mark = ["b": "**", "i": "*", "e": "`"][event.charactersIgnoringModifiers?.lowercased() ?? ""],
           onMarks?(mark) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if onNewline?() == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if onTab?(false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if onTab?(true) == true { return }
        super.insertBacktab(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if event.clickCount == 1, onClick?(point, command) == true { return }
        super.mouseDown(with: event)
    }

    /// A backtick typed over a selection makes it code, as editors do.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if (string as? String) == "`", selectedRange().length > 0, !hasMarkedText(), onMarks?("`") == true { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), onPaste?(text) == true { return }
        super.paste(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let items = extraMenuItems?(index) ?? []
        guard !items.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
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

    // MARK: Drawing

    /// The rows of the text from `range`'s first line to its last, across the whole width.
    private func band(for range: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let origin = textContainerOrigin
        return NSRect(x: origin.x + 1, y: first.minY + origin.y,
                      width: container.size.width - 2, height: last.maxY - first.minY)
    }

    private func label(for fold: NotepadFold) -> String {
        switch fold.state {
        case .folded:
            "⋯ " + (fold.hiddenLines == 1 ? L10n.t(.notepadCodeMoreLine) : L10n.t(.notepadCodeMoreLines, fold.hiddenLines))
        case .opened: "⌃ " + L10n.t(.notepadCodeFold)
        case .editing: ""
        }
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
    }

    /// Where the label of a block that is not being written sits: on its closing fence row.
    func labelRect(for fold: NotepadFold) -> NSRect? {
        guard fold.state != .editing, let row = band(for: fold.close), let container = textContainer else { return nil }
        let size = (label(for: fold) as NSString).size(withAttributes: labelAttributes)
        return NSRect(x: row.minX + container.lineFragmentPadding - 3, y: row.minY,
                      width: size.width + 6, height: row.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        for block in codeBlocks {
            guard let box = band(for: block)?.insetBy(dx: 0, dy: -1) else { continue }
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.08).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        super.draw(dirtyRect)
        for fold in folds {
            guard let rect = labelRect(for: fold) else { continue }
            let text = label(for: fold) as NSString
            let size = text.size(withAttributes: labelAttributes)
            text.draw(at: NSPoint(x: rect.minX + 3, y: rect.midY - size.height / 2), withAttributes: labelAttributes)
        }
    }
}

/// A menu item that runs a closure: the pad's own entries in the text view's context menu.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func runClosure() { run() }
}

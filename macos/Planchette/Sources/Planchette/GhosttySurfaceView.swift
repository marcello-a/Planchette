import AppKit
import SwiftUI
import GhosttyKit

/// NSView hosting one libghostty surface. libghostty attaches its Metal layer
/// to this view and renders; we forward input and sizing.
final class GhosttySurfaceNSView: NSView {
    private(set) var surface: ghostty_surface_t?
    let sessionID: UUID
    var onFocus: (() -> Void)?
    /// Whether this session is the visible/active one — used to reclaim the
    /// first-responder after SwiftUI re-attaches the view.
    var isActive: () -> Bool = { false }

    init(
        app: ghostty_app_t,
        sessionID: UUID,
        workingDirectory: String,
        initialInput: String? = nil
    ) {
        self.sessionID = sessionID
        super.init(frame: .zero)
        wantsLayer = true

        // Reliably catch every frame change (SwiftUI does not always call
        // setFrameSize on a hosted NSView during window/live resize).
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification, object: self)
        // Accept files (e.g. images for Claude), URLs, and text dropped onto
        // the terminal — their escaped path/content is typed at the prompt.
        registerForDraggedTypes([.fileURL, .URL, .string])

        // AppKit does NOT reliably call viewDidChangeBackingProperties when a
        // window moves to a screen with a different scale (e.g. external
        // monitor → MacBook display), leaving the surface at the old pixel
        // size. Observe the screen change directly, as Ghostty's own app does
        // (ghostty#2731). Registered for ALL windows (object: nil) because the
        // view moves between windows; the handler filters for its own.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification, object: nil)

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        // Everything the C call needs must stay alive for its duration.
        let envKey = strdup("PLANCHETTE_SESSION")
        let envValue = strdup(sessionID.uuidString)
        let sockKey = strdup("PLANCHETTE_SOCKET")
        let sockValue = strdup(HookServer.socketPath)
        // Notification tools (e.g. peon-ping/OpenPeon) run this on click so the
        // right terminal comes to front via our hook socket.
        let clickKey = strdup("PEON_CLICK_COMMAND")
        let clickValue = strdup(
            "printf '{\"planchette_session\":\"\(sessionID.uuidString)\","
                + "\"event\":{\"hook_event_name\":\"PlanchetteFocus\"}}'"
                + " | nc -U \(HookServer.socketPath)"
        )
        let cwd = strdup(workingDirectory)
        let input = initialInput.map { strdup($0) }
        defer {
            free(envKey); free(envValue); free(sockKey); free(sockValue)
            free(clickKey); free(clickValue); free(cwd)
            if let input { free(input) }
        }

        var envVars = [
            ghostty_env_var_s(key: envKey, value: envValue),
            ghostty_env_var_s(key: sockKey, value: sockValue),
            ghostty_env_var_s(key: clickKey, value: clickValue),
        ]
        envVars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            cfg.working_directory = UnsafePointer(cwd)
            if let input { cfg.initial_input = UnsafePointer(input) }
            self.surface = ghostty_surface_new(app, &cfg)
        }
        if surface == nil { NSLog("ghostty_surface_new failed") }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func destroySurface() {
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        destroySurface()
    }

    // MARK: Sizing

    /// Size handed down by SwiftUI's GeometryReader (points). Authoritative —
    /// during window/fullscreen animation the frame lags behind the final size.
    private var explicitSize: CGSize?

    /// Called from the SwiftUI representable with the layout size.
    func updateSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        explicitSize = size
        syncSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize()
    }

    @objc private func frameDidChange() { syncSurfaceSize() }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Authoritative final sync after a live drag settles.
        syncSurfaceSize()
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let window, let object = notification.object as? NSWindow,
              window == object else { return }
        if let surface, let screen = window.screen,
           let number = screen.deviceDescription[
               NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            // Keep vsync on the new display's refresh rate.
            ghostty_surface_set_display_id(surface, number)
        }
        // The scale may have changed with the screen; AppKit doesn't always
        // deliver viewDidChangeBackingProperties for that, so trigger it. Async
        // because the window's backingScaleFactor settles after the move.
        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        // Keep the compositor from scaling our Metal layer's contents itself —
        // we re-render at the new scale below (see Ghostty's own surface view).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSurfaceSize()
    }

    // MARK: Scrollback

    /// The full screen buffer (scrollback + screen) as plain text, for
    /// persistence. Plain text only — colors/styling aren't captured.
    func readScrollback() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return String(cString: ptr)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        // SwiftUI re-attaches NSViews on structural updates; the first
        // responder is lost in the process. Reclaim it if we're the active
        // terminal and nothing else claimed the keyboard.
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.isActive() else { return }
            if !(window.firstResponder is GhosttySurfaceNSView) {
                window.makeFirstResponder(self)
            }
        }
    }

    private func syncSurfaceSize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0)
        // Prefer the SwiftUI-provided size; fall back to the view's own frame.
        let size = explicitSize ?? frame.size
        let width = UInt32(max(1, size.width * scale))
        let height = UInt32(max(1, size.height * scale))
        ghostty_surface_set_size(surface, width, height)
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        onFocus?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    // MARK: Mouse

    /// Tell ghostty the pointer position for this event. Must be sent BEFORE a
    /// button press/release, otherwise ghostty uses a stale position and a click
    /// selects from there (e.g. the start of the line) to the release point.
    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, event.modifierFlags.ghosttyMods)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMousePos(event)   // position first → click lands where clicked
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event.modifierFlags.ghosttyMods)
    }

    override func mouseUp(with event: NSEvent) {
        sendMousePos(event)
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event.modifierFlags.ghosttyMods)
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }

    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }

    // Right click, exactly like Ghostty's own app: offer it to the surface
    // first (apps with mouse reporting, e.g. TUIs, may consume it); only when
    // unconsumed does super trigger `menu(for:)` — the context menu.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMousePos(event)
        guard let surface else { return super.rightMouseDown(with: event) }
        if ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event.modifierFlags.ghosttyMods) {
            return   // consumed by the terminal app
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePos(event)
        guard let surface else { return super.rightMouseUp(with: event) }
        if ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event.modifierFlags.ghosttyMods) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }

    /// Native terminal context menu (Copy / Paste / Select All), driven by
    /// ghostty's own clipboard binding actions.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown, let surface else { return nil }
        let menu = NSMenu()
        if ghostty_surface_has_selection(surface) {
            menu.addItem(withTitle: L10n.t(.menuCopy), action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: L10n.t(.menuPaste), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t(.menuSelectAll), action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // Clicking an unfocused terminal should register the click, not just focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Tracking area so mouseMoved/Entered/Exited fire — ghostty needs the live
    // pointer position for hover, selection, and mouse reporting. Without this
    // the position is stale and clicks/selection behave unintuitively.
    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let surface else { return }
        // Negative position tells ghostty the cursor left the viewport.
        ghostty_surface_mouse_pos(surface, -1, -1, event.modifierFlags.ghosttyMods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        ghostty_surface_mouse_scroll(
            surface, event.scrollingDeltaX, event.scrollingDeltaY,
            ghostty_input_scroll_mods_t(mods))
    }

    // MARK: Keyboard
    //
    // Route key presses through AppKit's text input system
    // (`interpretKeyEvents` → NSTextInputClient), exactly like Ghostty's own
    // app. The system resolves the correct characters in order — hand-decoding
    // `event.characters` dropped/reordered characters during fast typing
    // (e.g. "ls a aa" arriving as "laaa"). Control/navigation keys produce no
    // insertText, so we fall back to sending the keycode for those.

    /// Text the input system produced during the current keyDown.
    private var keyTextAccumulator: [String]?
    private var markedTextValue = NSMutableAttributedString()

    // MARK: Pending input (best-effort, for restore)
    //
    // Mirrors plain typing at the prompt so a restart can re-type what you'd
    // entered but not yet sent. It stays *conservative*: the moment anything
    // ambiguous happens (arrow keys, shortcuts, history recall, paste), we mark
    // it invalid and simply won't restore — never inject the wrong text.
    private var pendingInput = ""
    private var pendingValid = true

    /// The unsent line to restore, or nil if we can't trust it.
    func capturedPendingInput() -> String? {
        guard pendingValid, !pendingInput.isEmpty, pendingInput.count <= 4096 else { return nil }
        return pendingInput
    }

    private func trackPendingInput(event: NSEvent, produced: [String]) {
        switch event.keyCode {
        case 36, 76:                       // Return / Enter → line submitted
            pendingInput = ""; pendingValid = true; return
        case 51:                           // Backspace
            if pendingValid, !pendingInput.isEmpty { pendingInput.removeLast() }
            return
        default: break
        }
        // Any modifier combo (shortcuts, ⌃-sequences) → can't track.
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            pendingValid = false; return
        }
        let printable = produced.joined().filter {
            ($0.unicodeScalars.first?.value ?? 0) >= 0x20 && $0 != "\u{7F}"
        }
        if printable.isEmpty {             // arrows, tab, esc, fn keys, history…
            pendingValid = false
        } else if pendingValid {
            pendingInput += printable
        }
    }

    override func keyDown(with event: NSEvent) {
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let produced = keyTextAccumulator ?? []
        keyTextAccumulator = nil
        trackPendingInput(event: event, produced: produced)
        sendKey(event: event, action: GHOSTTY_ACTION_PRESS, texts: produced)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event: event, action: GHOSTTY_ACTION_RELEASE, texts: [])
    }

    override func doCommand(by selector: Selector) {
        // Swallow — the key is already forwarded to the surface via sendKey;
        // letting the responder chain also handle it would double-fire or beep.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let app-level shortcuts (⌘K, ⌘N, ⌘T, ⌘, …) reach the menus.
        guard event.modifierFlags.contains(.command) else { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        let appShortcuts: Set<String> = ["k", "n", "t", "w", "q", ","]
        if appShortcuts.contains(chars) { return false }

        // Font zoom: ⌘+ / ⌘- / ⌘0 (⌘= and ⌘⇧= both map to "+"/"=").
        switch chars {
        case "+", "=": increaseFontSize(); return true
        case "-": decreaseFontSize(); return true
        case "0": resetFontSize(); return true
        default: break
        }

        // The embedded runtime has no default clipboard keybindings, so drive
        // ghostty's clipboard actions directly (⌘V respects bracketed paste).
        let plainCommand = event.modifierFlags
            .intersection([.command, .option, .control, .shift]) == .command
        if plainCommand {
            switch chars {
            case "v":
                pendingValid = false   // can't track pasted text
                if performBindingAction("paste_from_clipboard") { return true }
            case "c": if performBindingAction("copy_to_clipboard") { return true }
            case "a": if performBindingAction("select_all") { return true }
            default: break
            }
        }

        keyDown(with: event)
        return true
    }

    /// Trigger a ghostty keybind action by name (e.g. `paste_from_clipboard`).
    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        let len = action.utf8CString.count
        guard len > 0 else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(len - 1)) }
    }

    // Font zoom, driven by the header buttons and ⌘+/⌘-/⌘0.
    func increaseFontSize() { performBindingAction("increase_font_size:1") }
    func decreaseFontSize() { performBindingAction("decrease_font_size:1") }
    func resetFontSize() { performBindingAction("reset_font_size") }

    // MARK: Drag & drop (files → escaped path at the prompt, like Ghostty)

    /// Send text straight into the terminal as if typed (used for drops —
    /// unlike `insertText`, which only feeds the keyDown pipeline).
    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        pendingValid = false   // injected text isn't tracked prompt typing
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                ghostty_surface_text(surface, ptr, UInt(buf.count))
            }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: [.fileURL, .URL, .string])
        else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let content: String?
        if let url = pb.string(forType: .URL) {
            // URLs first, escaped as-is.
            content = Shell.escape(url)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty {
            // Files (images, folders, …): escape each path, join with spaces —
            // exactly what a running `claude` expects to read a file.
            content = urls.map { Shell.escape($0.path) }.joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            // Plain strings stay unescaped — they may be a command to run.
            content = str
        } else {
            content = nil
        }
        guard let content else { return false }
        window?.makeFirstResponder(self)
        sendText(content)
        return true
    }

    // Standard clipboard responder selectors so the Edit menu items (Paste,
    // Copy, Select All) are enabled and routed to the surface too.
    @objc func paste(_ sender: Any?) { pendingValid = false; performBindingAction("paste_from_clipboard") }
    @objc func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBindingAction("select_all") }

    private func sendKey(event: NSEvent, action: ghostty_input_action_e, texts: [String]) {
        guard let surface else { return }

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = event.modifierFlags.ghosttyMods
        // Control/Command never contribute to text translation (ghostty's own
        // heuristic); everything else did.
        key.consumed_mods = event.modifierFlags.subtracting([.control, .command]).ghosttyMods
        key.keycode = UInt32(event.keyCode)
        // The codepoint with NO modifiers applied. Ghostty needs this to encode
        // control shortcuts (⌃C → \x03, ⌃U, ⌃A, ⌃E, ⌃W, …) and Alt combos.
        // Without it, control-key shortcuts silently do nothing.
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        key.composing = markedTextValue.length > 0

        let printable = texts.filter { s in
            guard let scalar = s.unicodeScalars.first else { return false }
            return scalar.value >= 0x20 && scalar.value != 0x7F
        }
        if printable.isEmpty {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        } else {
            for text in printable {
                text.withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            }
        }
    }
}

// MARK: - NSTextInputClient
// Lets `interpretKeyEvents` deliver resolved characters via insertText (in
// order) and provides basic dead-key/IME composition.
extension GhosttySurfaceNSView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedTextValue = NSMutableAttributedString()
        if keyTextAccumulator != nil { keyTextAccumulator?.append(text) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            markedTextValue = NSMutableAttributedString(attributedString: s)
        } else if let s = string as? String {
            markedTextValue = NSMutableAttributedString(string: s)
        }
    }

    func unmarkText() { markedTextValue = NSMutableAttributedString() }
    func hasMarkedText() -> Bool { markedTextValue.length > 0 }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        markedTextValue.length > 0 ? NSRange(location: 0, length: markedTextValue.length)
                                   : NSRange(location: NSNotFound, length: 0)
    }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}

/// Builds the shell input replayed into a terminal when a session is restored.
/// Pure and side-effect free so it can be unit-tested.
enum RestoreCommand {
    static func input(
        hasScrollback: Bool,
        scrollbackPath: String,
        startupCommand: String?,
        claudeSessionID: String?,
        resumeClaude: Bool,
        pendingInput: String? = nil
    ) -> String? {
        var commands: [String] = []
        let willResumeClaude = resumeClaude && claudeSessionID != nil

        // Replay the saved scrollback (plain text) so the history is back.
        // `clear` wipes the injected command line, leaving just the history.
        // Skip it when we're resuming Claude: `claude --resume` redraws the
        // conversation itself, and the captured buffer would just be a snapshot
        // of its full-screen TUI.
        if hasScrollback && !willResumeClaude {
            let escaped = scrollbackPath.replacingOccurrences(of: "'", with: "'\\''")
            commands.append("clear; cat '\(escaped)' 2>/dev/null")
        }
        let hasStartup = !(startupCommand ?? "").isEmpty
        if let startup = startupCommand, hasStartup {
            commands.append(startup)
        }
        if willResumeClaude, let claudeID = claudeSessionID {
            // Resume THIS terminal's exact conversation; if that fails, fall back
            // to Claude's interactive session picker so the user can still choose
            // their conversation, and only then to a fresh session — so a Claude
            // session is essentially never lost. Never `claude --continue`: it
            // resumes the folder's most recent conversation, which may belong to
            // a different terminal.
            commands.append("claude --resume \(claudeID) || claude --resume || claude")
        }

        var script = commands.isEmpty ? "" : commands.joined(separator: "\n") + "\n"
        // Best-effort: re-type unsent input at the prompt WITHOUT a newline, so
        // it sits there ready to edit and nothing runs. Only for a plain shell —
        // if we're launching Claude or a startup command, the input would land
        // in the wrong place.
        if !willResumeClaude, !hasStartup, let pending = pendingInput, !pending.isEmpty {
            script += pending
        }
        return script.isEmpty ? nil : script
    }
}

/// Keeps terminal NSViews alive independent of SwiftUI view lifecycles —
/// switching tabs or view modes must never destroy a running surface.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var views: [UUID: GhosttySurfaceNSView] = [:]

    func view(for session: TerminalSession, appState: AppState) -> GhosttySurfaceNSView? {
        if let existing = views[session.id] { return existing }
        guard let app = GhosttyRuntime.shared.app else { return nil }

        var initialInput: String? = nil
        if appState.isRestoring {
            let sbPath = AppState.scrollbackURL(for: session.id).path
            let pending = try? String(contentsOf: AppState.pendingInputURL(for: session.id), encoding: .utf8)
            // The conversation to resume, resolved as one batch over ALL
            // terminals in applyRestore — never per-terminal here, so tabs of
            // the same project can't converge on the same conversation. Only
            // sessions with resumeClaudeOnRestore are in the map.
            let resumeID = appState.restoreResumeIDs[session.id]
            initialInput = RestoreCommand.input(
                hasScrollback: FileManager.default.fileExists(atPath: sbPath),
                scrollbackPath: sbPath,
                startupCommand: session.startupCommand,
                claudeSessionID: resumeID,
                resumeClaude: session.resumeClaudeOnRestore,
                pendingInput: pending)
        }

        let view = GhosttySurfaceNSView(
            app: app,
            sessionID: session.id,
            workingDirectory: session.currentDirectory,
            initialInput: initialInput
        )
        let id = session.id
        // Focusing must not clear attention state (a glance isn't an answer).
        view.onFocus = nil
        view.isActive = { [weak appState] in
            guard let appState, let session = appState.sessions[id] else { return false }
            let window = appState.windowContaining(groupID: session.groupID)
            return window?.selectedGroupID == session.groupID
                && appState.groups.first { $0.id == session.groupID }?.activeSessionID == id
        }
        views[id] = view
        return view
    }

    func close(_ id: UUID) {
        views[id]?.destroySurface()
        views[id] = nil
    }

    /// The live surface view for a session, if it exists (no creation).
    func existingView(_ id: UUID) -> GhosttySurfaceNSView? { views[id] }

    /// Push a rebuilt config (e.g. after a light/dark change) to every surface.
    func updateConfig(_ config: ghostty_config_t) {
        for view in views.values {
            if let surface = view.surface {
                ghostty_surface_update_config(surface, config)
            }
        }
    }

    /// Persist each live surface's scrollback (plain text) into `dir`, so the
    /// terminal history survives a restart. Capped per session to stay small.
    /// Files are user-only (0600) since scrollback can contain secrets.
    func saveScrollback(to dir: URL) {
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for (id, view) in views {
            // Scrollback (visual history).
            if let text = view.readScrollback(), !text.isEmpty {
                let capped = String(text.suffix(200_000))
                let url = dir.appendingPathComponent("\(id.uuidString).txt")
                if (try? capped.write(to: url, atomically: true, encoding: .utf8)) != nil {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
            // Unsent input at the prompt (best-effort) — write, or clear stale.
            let inputURL = dir.appendingPathComponent("\(id.uuidString).input")
            if let pending = view.capturedPendingInput() {
                if (try? pending.write(to: inputURL, atomically: true, encoding: .utf8)) != nil {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
                }
            } else {
                try? FileManager.default.removeItem(at: inputURL)
            }
        }
    }
}

/// Hosts a terminal surface, sized by SwiftUI's layout. The GeometryReader is
/// the authoritative size source: SwiftUI does not reliably call setFrameSize
/// on a hosted NSView during window/live resize, so we feed geo.size straight
/// to the surface (this is Ghostty's own recommended embedding approach).
struct TerminalHostView: View {
    let session: TerminalSession
    var autoFocus = true

    var body: some View {
        GeometryReader { geo in
            TerminalSurfaceRepresentable(session: session, autoFocus: autoFocus, size: geo.size)
        }
    }
}

private struct TerminalSurfaceRepresentable: NSViewRepresentable {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    var autoFocus: Bool
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = TerminalRegistry.shared.view(for: session, appState: appState) ?? NSView()
        (view as? GhosttySurfaceNSView)?.updateSize(size)
        focusIfActive(view)
        return view
    }

    // SwiftUI re-runs updateNSView when the layout size or observed state
    // changes, so this both resizes the surface and moves focus to whichever
    // terminal just became active (restore, tab switches, quick-switcher jumps).
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? GhosttySurfaceNSView)?.updateSize(size)
        focusIfActive(nsView)
    }

    private func focusIfActive(_ view: NSView) {
        guard autoFocus, let surfaceView = view as? GhosttySurfaceNSView else { return }
        DispatchQueue.main.async {
            guard let window = surfaceView.window, surfaceView.isActive() else { return }
            // Ensure a key window exists so keystrokes are delivered at all
            // (after the launch modal + window restoration the app can end up
            // with no key window).
            if NSApp.keyWindow == nil, window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
            if window.firstResponder !== surfaceView {
                window.makeFirstResponder(surfaceView)
            }
        }
    }
}

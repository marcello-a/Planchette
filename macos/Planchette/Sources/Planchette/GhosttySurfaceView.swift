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
        let cwd = strdup(workingDirectory)
        let input = initialInput.map { strdup($0) }
        defer {
            free(envKey); free(envValue); free(cwd)
            if let input { free(input) }
        }

        var envVars = [ghostty_env_var_s(key: envKey, value: envValue)]
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event.modifierFlags.ghosttyMods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event.modifierFlags.ghosttyMods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, event.modifierFlags.ghosttyMods)
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

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

    override func keyDown(with event: NSEvent) {
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let produced = keyTextAccumulator ?? []
        keyTextAccumulator = nil
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

        // The embedded runtime has no default clipboard keybindings, so drive
        // ghostty's clipboard actions directly (⌘V respects bracketed paste).
        let plainCommand = event.modifierFlags
            .intersection([.command, .option, .control, .shift]) == .command
        if plainCommand {
            switch chars {
            case "v": if performBindingAction("paste_from_clipboard") { return true }
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

    // Standard clipboard responder selectors so the Edit menu items (Paste,
    // Copy, Select All) are enabled and routed to the surface too.
    @objc func paste(_ sender: Any?) { performBindingAction("paste_from_clipboard") }
    @objc func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBindingAction("select_all") }

    private func sendKey(event: NSEvent, action: ghostty_input_action_e, texts: [String]) {
        guard let surface else { return }

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = event.modifierFlags.ghosttyMods
        key.consumed_mods = ghostty_input_mods_e(0)
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = 0
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
        resumeClaude: Bool
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
        if let startup = startupCommand, !startup.isEmpty {
            commands.append(startup)
        }
        if willResumeClaude, let claudeID = claudeSessionID {
            // Resume THIS terminal's exact conversation, else start fresh.
            // Never `claude --continue`: it resumes the most recent conversation
            // in the folder, which may belong to a different terminal.
            commands.append("claude --resume \(claudeID) || claude")
        }
        return commands.isEmpty ? nil : commands.joined(separator: "\n") + "\n"
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
            initialInput = RestoreCommand.input(
                hasScrollback: FileManager.default.fileExists(atPath: sbPath),
                scrollbackPath: sbPath,
                startupCommand: session.startupCommand,
                claudeSessionID: session.claudeSessionID,
                resumeClaude: session.resumeClaudeOnRestore)
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
            guard let text = view.readScrollback(), !text.isEmpty else { continue }
            let capped = String(text.suffix(200_000))
            let url = dir.appendingPathComponent("\(id.uuidString).txt")
            guard (try? capped.write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            // with no key window). Only while active: keyWindow is always nil
            // when the app is in the background, and ordering front from there
            // would raise/deminiaturize the window on every state update.
            if NSApp.isActive, NSApp.keyWindow == nil, window.canBecomeKey, !window.isMiniaturized {
                window.makeKeyAndOrderFront(nil)
            }
            if window.firstResponder !== surfaceView {
                window.makeFirstResponder(surfaceView)
            }
        }
    }
}

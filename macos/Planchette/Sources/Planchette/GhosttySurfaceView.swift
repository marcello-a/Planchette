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

    deinit { destroySurface() }

    // MARK: Sizing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSurfaceSize()
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
        let width = UInt32(max(1, frame.width * scale))
        let height = UInt32(max(1, frame.height * scale))
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

    override func keyDown(with event: NSEvent) {
        handleKey(event: event, action: GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        handleKey(event: event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let app-level shortcuts (⌘K, ⌘N, …) through; feed everything else
        // (⌘C/⌘V/… have ghostty bindings) to the surface.
        guard event.modifierFlags.contains(.command) else { return false }
        let appShortcuts: Set<String> = ["k", "n", "t", "w", "q", ","]
        if let chars = event.charactersIgnoringModifiers, appShortcuts.contains(chars) {
            return false
        }
        handleKey(event: event, action: GHOSTTY_ACTION_PRESS)
        return true
    }

    private func handleKey(event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = event.modifierFlags.ghosttyMods
        key.consumed_mods = ghostty_input_mods_e(0)
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = 0
        key.composing = false

        // Provide text only for printable input; libghostty encodes the rest
        // from keycode + modifiers.
        var text: String? = nil
        if action == GHOSTTY_ACTION_PRESS,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           let chars = event.characters,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x20, scalar.value != 0x7F {
            text = chars
        }

        if let text {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
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
            var commands: [String] = []
            if let startup = session.startupCommand, !startup.isEmpty {
                commands.append(startup)
            }
            if session.resumeClaudeOnRestore, let claudeID = session.claudeSessionID {
                commands.append("claude --resume \(claudeID)")
            }
            if !commands.isEmpty { initialInput = commands.joined(separator: "\n") + "\n" }
        }

        let view = GhosttySurfaceNSView(
            app: app,
            sessionID: session.id,
            workingDirectory: session.currentDirectory,
            initialInput: initialInput
        )
        let id = session.id
        view.onFocus = { [weak appState] in appState?.sessionWasAttended(id) }
        view.isActive = { [weak appState] in
            guard let appState, let session = appState.sessions[id] else { return false }
            return appState.selectedGroupID == session.groupID
                && appState.groups.first { $0.id == session.groupID }?.activeSessionID == id
        }
        views[id] = view
        return view
    }

    func close(_ id: UUID) {
        views[id]?.destroySurface()
        views[id] = nil
    }
}

struct TerminalHostView: NSViewRepresentable {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    var autoFocus = true

    func makeNSView(context: Context) -> NSView {
        let view = TerminalRegistry.shared.view(for: session, appState: appState) ?? NSView()
        if autoFocus {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

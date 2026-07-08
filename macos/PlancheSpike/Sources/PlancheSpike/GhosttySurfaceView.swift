import AppKit
import SwiftUI
import GhosttyKit

/// Minimal NSView hosting one libghostty surface. libghostty attaches its own
/// Metal layer to this view and renders into it; we forward input and sizing.
final class GhosttySurfaceNSView: NSView {
    private(set) var surface: ghostty_surface_t?

    init(app: ghostty_app_t, workingDirectory: String) {
        super.init(frame: .zero)
        wantsLayer = true

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        workingDirectory.withCString { cwd in
            cfg.working_directory = cwd
            self.surface = ghostty_surface_new(app, &cfg)
        }
        if surface == nil { NSLog("ghostty_surface_new failed") }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

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
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

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

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        ghostty_surface_mouse_scroll(
            surface, event.scrollingDeltaX, event.scrollingDeltaY, ghostty_input_scroll_mods_t(mods))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        handleKey(event: event, action: GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        handleKey(event: event, action: GHOSTTY_ACTION_RELEASE)
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

        // Provide text only for printable input (no command shortcuts, no
        // control characters) — libghostty encodes everything else from the
        // keycode + modifiers itself.
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

/// SwiftUI wrapper.
struct GhosttyTerminalView: NSViewRepresentable {
    let app: ghostty_app_t
    var workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    func makeNSView(context: Context) -> GhosttySurfaceNSView {
        GhosttySurfaceNSView(app: app, workingDirectory: workingDirectory)
    }

    func updateNSView(_ nsView: GhosttySurfaceNSView, context: Context) {}
}

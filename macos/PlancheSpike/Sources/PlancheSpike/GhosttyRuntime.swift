import AppKit
import GhosttyKit

/// Minimal libghostty runtime wrapper: one app instance, ticked on the main
/// thread whenever libghostty asks for a wakeup.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("ghostty_init failed")
            return
        }

        guard let config = ghostty_config_new() else {
            NSLog("ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { _, _, _ in
                // Spike: no app-level actions handled.
                false
            },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, content, count, _ in
                guard let content, count > 0 else { return }
                for i in 0..<count {
                    let item = content[i]
                    guard let mime = item.mime, let data = item.data else { continue }
                    if String(cString: mime).hasPrefix("text/") {
                        let string = String(cString: data)
                        DispatchQueue.main.async {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(string, forType: .string)
                        }
                        return
                    }
                }
            },
            close_surface_cb: { _, _ in }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            NSLog("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}

extension NSEvent.ModifierFlags {
    var ghosttyMods: ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }
}

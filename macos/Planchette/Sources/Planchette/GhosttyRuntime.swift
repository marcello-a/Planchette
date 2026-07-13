import AppKit
import GhosttyKit

extension Notification.Name {
    static let planchetteSurfaceTitle = Notification.Name("planchette.surface.title")
    static let planchetteSurfacePwd = Notification.Name("planchette.surface.pwd")
    static let planchetteSurfaceChildExited = Notification.Name("planchette.surface.childExited")
    static let planchetteCommandFinished = Notification.Name("planchette.surface.commandFinished")
}

/// libghostty runtime: one app instance, ticked on the main thread on wakeup.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        // In a packaged .app the Ghostty resources (terminfo, shell
        // integration) live in the bundle; point libghostty at them if the
        // env var isn't already set (dev runs still set it explicitly).
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil,
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
           FileManager.default.fileExists(atPath: bundled.path) {
            setenv("GHOSTTY_RESOURCES_DIR", bundled.path, 1)
        }

        // Point ncurses at Ghostty's terminfo so `xterm-ghostty` resolves —
        // without it, clear/line-editing/redraw sequences fail and the display
        // garbles ("'xterm-ghostty': unknown terminal type"). Set before the
        // shell spawns so child processes inherit it.
        if ProcessInfo.processInfo.environment["TERMINFO"] == nil {
            let fm = FileManager.default
            var terminfo: String?
            if let bundled = Bundle.main.resourceURL?.appendingPathComponent("terminfo"),
               fm.fileExists(atPath: bundled.path) {
                terminfo = bundled.path
            } else if let res = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] {
                // Dev: resources dir is …/share/ghostty; terminfo is …/share/terminfo.
                let sibling = URL(fileURLWithPath: res).deletingLastPathComponent()
                    .appendingPathComponent("terminfo").path
                if fm.fileExists(atPath: sibling) { terminfo = sibling }
            }
            if let terminfo { setenv("TERMINFO", terminfo, 1) }
        }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("ghostty_init failed")
            return
        }

        guard let config = GhosttyRuntime.makeConfig(dark: GhosttyRuntime.isDarkAppearance()) else {
            NSLog("ghostty_config_new failed")
            return
        }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { _, target, action in
                GhosttyRuntime.handleAction(target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // Skip the confirmation dialog in v1: allow the read.
                GhosttyRuntime.readClipboard(userdata, location: GHOSTTY_CLIPBOARD_STANDARD, state: state)
            },
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
            close_surface_cb: { userdata, _ in
                guard let userdata else { return }
                let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .planchetteSurfaceChildExited, object: nil,
                        userInfo: ["sessionID": view.sessionID])
                }
            }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            NSLog("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        ghostty_app_set_color_scheme(app, GhosttyRuntime.isDarkAppearance()
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        startAppearanceTracking()
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: Appearance
    //
    // The terminal background follows the app's light/dark mode: white on light,
    // black on dark. libghostty is configured from files only, so we write the
    // color overrides to a small config file and (re)load it.

    private var appearanceObserver: NSKeyValueObservation?

    static func isDarkAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func makeConfig(dark: Bool) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        // Respect the user's regular Ghostty config (fonts, palette) if present…
        ghostty_config_load_default_files(cfg)
        // …then force the background/foreground to match the app's mode.
        let bg = dark ? "000000" : "ffffff"
        let fg = dark ? "ffffff" : "000000"
        let text = "background = \(bg)\nforeground = \(fg)\ncursor-color = \(fg)\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-ghostty-\(dark ? "dark" : "light").conf")
        if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
            url.path.withCString { ghostty_config_load_file(cfg, $0) }
        }
        ghostty_config_finalize(cfg)
        return cfg
    }

    private func startAppearanceTracking() {
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyCurrentAppearance() }
        }
    }

    /// Rebuild the config for the current mode and push it to the app + every
    /// live surface.
    func applyCurrentAppearance() {
        guard let app, let cfg = GhosttyRuntime.makeConfig(dark: GhosttyRuntime.isDarkAppearance())
        else { return }
        let old = config
        config = cfg
        ghostty_app_update_config(app, cfg)
        ghostty_app_set_color_scheme(app, GhosttyRuntime.isDarkAppearance()
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        MainActor.assumeIsolated { TerminalRegistry.shared.updateConfig(cfg) }
        if let old { ghostty_config_free(old) }
    }

    // MARK: Callbacks

    private static func view(for target: ghostty_target_s) -> GhosttySurfaceNSView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func handleAction(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = view(for: target), let cTitle = action.action.set_title.title
            else { return false }
            let title = String(cString: cTitle)
            let sessionID = view.sessionID
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .planchetteSurfaceTitle, object: nil,
                    userInfo: ["sessionID": sessionID, "title": title])
            }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view = view(for: target), let cPwd = action.action.pwd.pwd
            else { return false }
            let pwd = String(cString: cPwd)
            let sessionID = view.sessionID
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .planchetteSurfacePwd, object: nil,
                    userInfo: ["sessionID": sessionID, "pwd": pwd])
            }
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            // OSC 133 shell-integration exit code of the last command.
            guard let view = view(for: target) else { return false }
            let exitCode = Int(action.action.command_finished.exit_code)
            let sessionID = view.sessionID
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .planchetteCommandFinished, object: nil,
                    userInfo: ["sessionID": sessionID, "exitCode": exitCode])
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            // ⌘-click on a detected link (ghostty reconstructs URLs across soft
            // line wraps). Open it in the default app.
            let u = action.action.open_url
            guard let ptr = u.url, u.len > 0,
                  let str = String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)), encoding: .utf8),
                  let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return false }
            DispatchQueue.main.async { openExternalURL(url) }
            return true

        default:
            return false
        }
    }

    /// Open a URL from terminal content, restricted to safe web/mail schemes so
    /// untrusted output can't trigger arbitrary URL-scheme handlers.
    private static func openExternalURL(_ url: URL) {
        let allowed: Set<String> = ["http", "https", "mailto", "ftp", "ftps", "file"]
        guard let scheme = url.scheme?.lowercased(), allowed.contains(scheme) else {
            NSLog("blocked opening url with scheme: \(url.scheme ?? "none")")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata else { return false }
        let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            guard let surface = view.surface else { return }
            let string = NSPasteboard.general.string(forType: .string) ?? ""
            string.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }
        return true
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

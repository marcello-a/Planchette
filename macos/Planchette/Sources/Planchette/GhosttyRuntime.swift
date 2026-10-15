import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let planchetteSurfaceTitle = Notification.Name("planchette.surface.title")
    static let planchetteSurfacePwd = Notification.Name("planchette.surface.pwd")
    static let planchetteSurfaceChildExited = Notification.Name("planchette.surface.childExited")
    static let planchetteCommandFinished = Notification.Name("planchette.surface.commandFinished")
    static let planchetteSurfaceSearch = Notification.Name("planchette.surface.search")
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
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, confirmed: false)
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                // libghostty is asking whether to let an OSC 52 read, a risky
                // paste or an OSC 52 write through. It used to be answered "yes"
                // unconditionally, which switched its protections off; the user
                // decides now (see `ClipboardConfirmation`). Whatever the answer,
                // the request is completed with `confirmed: true` — completing
                // with `false` would re-trigger this callback forever.
                GhosttyRuntime.confirmClipboard(userdata, string: string, state: state, request: request)
            },
            write_clipboard_cb: { userdata, _, content, count, confirm in
                guard let content, count > 0 else { return }
                for i in 0..<count {
                    let item = content[i]
                    guard let mime = item.mime, let data = item.data else { continue }
                    if String(cString: mime).hasPrefix("text/") {
                        // Copied here: the C buffers only live for this call.
                        GhosttyRuntime.writeClipboard(
                            userdata, text: String(cString: data), confirm: confirm)
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

        case GHOSTTY_ACTION_START_SEARCH, GHOSTTY_ACTION_END_SEARCH,
             GHOSTTY_ACTION_SEARCH_TOTAL, GHOSTTY_ACTION_SEARCH_SELECTED:
            // The find bar of a plain terminal: libghostty searches its own scrollback
            // and says how many matches there are and which one is selected. Strings
            // are built HERE: the C buffer only lives for this callback.
            guard let view = view(for: target) else { return false }
            var info: [String: Any] = ["sessionID": view.sessionID]
            switch action.tag {
            case GHOSTTY_ACTION_START_SEARCH:
                info["event"] = "start"
                info["needle"] = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            case GHOSTTY_ACTION_END_SEARCH:
                info["event"] = "end"
            case GHOSTTY_ACTION_SEARCH_TOTAL:
                info["event"] = "total"
                info["value"] = Int(action.action.search_total.total)
            default:
                info["event"] = "selected"
                info["value"] = Int(action.action.search_selected.selected)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .planchetteSurfaceSearch, object: nil, userInfo: info)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            // The pointer entered (url set) or left (empty) a detected link.
            // Kept on the view so the context menu knows whether "Open Link"
            // can act. The string is built HERE: the C buffer only lives for
            // this callback.
            guard let view = view(for: target) else { return false }
            let link = action.action.mouse_over_link
            var url: String?
            if let ptr = link.url, link.len > 0 {
                url = String(
                    bytes: UnsafeRawBufferPointer(start: ptr, count: Int(link.len)),
                    encoding: .utf8)
            }
            DispatchQueue.main.async { view.hoveredLinkURL = url }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            // ⌘-click on a detected link (ghostty reconstructs URLs across soft
            // line wraps). Open it in the default app.
            let u = action.action.open_url
            guard let ptr = u.url, u.len > 0,
                  let str = String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)), encoding: .utf8)
            else { return false }
            // Handled either way. Returning false makes libghostty run `open` on the
            // raw string itself, with none of the policy in `openExternalURL` — and
            // a string `URL` cannot parse (`http://[`, a space in the host) is
            // exactly what would take that path. It is simply not opened.
            if let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                DispatchQueue.main.async { openExternalURL(url) }
            } else {
                NSLog("blocked a link that is not a valid URL")
            }
            return true

        default:
            return false
        }
    }

    /// What to do with a URL that came out of terminal text.
    enum URLAction: Equatable {
        case open
        /// Show it in Finder instead of opening it.
        case reveal
        case block
    }

    /// File types that start something when they are opened rather than showing
    /// it: applications, scripts Terminal runs, installers, disk images that
    /// mount, launchers, bookmarks that open arbitrary URLs.
    static let launchingExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "action", "scpt", "scptd",
        "pkg", "mpkg", "dmg", "jar", "webloc", "inetloc", "fileloc", "vncloc",
        "afploc", "saver", "prefpane", "service", "xpc", "kext",
    ]

    /// How a URL from terminal output may be opened, and what exactly to open.
    ///
    /// Web and mail links open. A `file:` link is a different matter —
    /// `NSWorkspace.open` on an application, a `.command` file or an executable
    /// *runs* it, so one ⌘-click on a path a program printed could start whatever
    /// sits there. Those are revealed in Finder (where launching is the user's
    /// deliberate second step); documents and ordinary folders still open.
    ///
    /// Everything is judged on where the link LEADS, not on what it is called.
    /// LaunchServices follows a symlink, so a link named `notes.txt` (or `docs`)
    /// that points at `x.terminal` or `payload.app` was opened as that — and a
    /// repository can carry both the link and the target. The path is therefore
    /// resolved first (`realpath`: symlinks, `..`, `/tmp`), and the *resolved* URL is
    /// what is opened, so the file cannot change between the check and the open.
    ///
    /// Whether a plain file would run is decided by its content type, not by the
    /// execute bit: Mach-O programs and extension-less scripts are executables,
    /// while a text file with the bit set is still a text file (and every file on
    /// an exFAT or SMB volume reports the bit).
    static func resolve(_ url: URL) -> (action: URLAction, target: URL) {
        guard let scheme = url.scheme?.lowercased() else { return (.block, url) }
        switch scheme {
        case "http", "https", "mailto", "ftp", "ftps":
            return (.open, url)
        case "file":
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(url.path, &buffer) != nil else { return (.block, url) }
            let target = URL(fileURLWithPath: String(cString: buffer))
            return (fileAction(of: target, linkedAs: url), target)
        default:
            return (.block, url)
        }
    }

    static func action(for url: URL) -> URLAction { resolve(url).action }

    private static func fileAction(of target: URL, linkedAs link: URL) -> URLAction {
        // Both names: either could carry the extension that makes it launch.
        let extensions = [target.pathExtension, link.pathExtension].map { $0.lowercased() }
        if extensions.contains(where: launchingExtensions.contains) { return .reveal }
        let values = try? target.resourceValues(
            forKeys: [.isApplicationKey, .isAliasFileKey, .isDirectoryKey, .contentTypeKey])
        // A Finder alias is resolved by LaunchServices to who-knows-what.
        if values?.isAliasFile == true || values?.isApplication == true { return .reveal }
        if values?.isDirectory == true { return .open }
        if let type = values?.contentType {
            if type.conforms(to: .executable) || type.conforms(to: .unixExecutable) {
                return .reveal
            }
            if type.conforms(to: .script),
               FileManager.default.isExecutableFile(atPath: target.path) {
                return .reveal
            }
        }
        return .open
    }

    /// Open a URL from terminal content, restricted to safe web/mail schemes so
    /// untrusted output can't trigger arbitrary URL-scheme handlers — and, for
    /// files, to things that show rather than run (see `resolve`). Shared by
    /// ⌘-click (OPEN_URL above) and the context menu's "Open Link" — one policy.
    static func openExternalURL(_ url: URL) {
        let (action, target) = resolve(url)
        switch action {
        case .open:
            NSWorkspace.shared.open(target)
        case .reveal:
            NSLog("link points at something that would run: revealing it instead")
            NSWorkspace.shared.activateFileViewerSelecting([target])
        case .block:
            NSLog("blocked opening url with scheme: \(url.scheme ?? "none")")
        }
    }

    /// A program set the clipboard (OSC 52, or a copy). `confirm` is libghostty
    /// saying the user's config asks first (`clipboard-write = ask`); it used to be
    /// ignored, so that setting did nothing. Without a surface to attach the
    /// question to, a write that needs confirming is not performed.
    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?, text: String, confirm: Bool
    ) {
        let perform = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        guard confirm else {
            DispatchQueue.main.async(execute: perform)
            return
        }
        guard let userdata else { return }
        let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ClipboardConfirmation.requestWrite(text: text, view: view, allow: perform)
            }
        }
    }

    /// Hand a libghostty clipboard confirmation to the user.
    ///
    /// The string is copied here because the C buffer only lives for this call,
    /// and the dialog is shown from the next main-queue turn: completing a
    /// request from inside the callback that reported it would re-enter the
    /// library.
    private static func confirmClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata else { return }
        let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
        let text = string.map { String(cString: $0) } ?? ""
        let kind = ClipboardConfirmation.Kind(request)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ClipboardConfirmation.request(kind: kind, text: text, state: state, view: view)
            }
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) -> Bool {
        guard let userdata else { return false }
        let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            guard let surface = view.surface else { return }
            let string = NSPasteboard.general.string(forType: .string) ?? ""
            string.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
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

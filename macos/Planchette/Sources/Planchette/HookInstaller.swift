import Foundation

/// Installs the agent integrations so Planchette receives attention events with
/// zero manual setup. Runs on every launch and is idempotent per target: it
/// deploys the bundled hook script to a stable location and merges the hook
/// entries into each agent's own config, never overwriting anything else (a
/// one-time backup is kept). If a config can't be parsed, that target is
/// skipped rather than risking the user's setup.
///
/// Two kinds of target, and the difference matters:
///
/// - **Full lifecycle** (Claude Code): every state change is reported, so hooks
///   alone can drive the indicator.
/// - **Session claim** (Codex): the integration only tells us *which agent runs
///   in which terminal*. Lifecycle comes from screen detection. Installing more
///   than that would be worse than installing less — a `working` event with no
///   matching `finished` event leaves a terminal purple forever.
enum HookInstaller {
    /// The Claude Code hook events Planchette reacts to (see AppState.applyHookEvent).
    ///
    /// `PreToolUse`/`PostToolUse` are here for one reason: granting a permission
    /// fires no event of its own, so they are the only proof that the turn moved
    /// on. Without them a terminal you have already answered keeps showing
    /// "waiting" until the whole turn ends (see `AttentionState.forHookEvent`).
    static let events = [
        "SessionStart", "UserPromptSubmit", "Notification",
        "PermissionRequest", "PreToolUse", "PostToolUse",
        "Stop", "SubagentStop", "SessionEnd",
    ]

    /// Events whose config entries are per tool. `*` is Claude Code's "every
    /// tool" matcher — stated rather than omitted, so the entry reads the same as
    /// the ones a user writes by hand.
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// Codex fires the same event names, but only `SessionStart` is worth
    /// installing — see the note above.
    static let codexEvents = ["SessionStart"]

    /// Stable path for the hook script. Deliberately a space-free path under
    /// ~/.planchette: agents run the hook command through the shell, and a
    /// space (e.g. "Application Support") would break the unquoted path.
    static var hookScriptURL: URL {
        planchetteDirectory.appendingPathComponent("planchette-hook")
    }

    /// The control CLI agents call to drive Planchette. Deployed next to the
    /// hook and handed to every terminal as $PLANCHETTE_CLI, so an agent never
    /// has to guess a path and we never touch the user's PATH.
    static var cliURL: URL {
        planchetteDirectory.appendingPathComponent("planchette")
    }

    static var planchetteDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".planchette", isDirectory: true)
    }

    /// The command an agent's config invokes: the script plus the agent label,
    /// so one script serves every agent and the app knows who spoke.
    static func hookCommand(for kind: AgentKind) -> String {
        "\(hookScriptURL.path) \(kind.rawValue)"
    }

    /// The script path out of a configured hook command (which now carries an
    /// argument). Used to recognize our own entries in a foreign config.
    static func scriptPath(ofCommand command: String) -> String {
        String(command.split(separator: " ").first ?? "")
    }

    static func isPlanchetteCommand(_ command: String) -> Bool {
        (scriptPath(ofCommand: command) as NSString).lastPathComponent == "planchette-hook"
    }

    static func installIfNeeded() {
        do {
            try deployScript()
            try deployCLI()
        } catch {
            NSLog("hook install failed: \(error)")
            return
        }
        // One bad config must not stop the other agents from being wired up.
        do {
            // Only wire up settings if the hook script is actually deployed.
            if FileManager.default.fileExists(atPath: hookScriptURL.path) {
                let settings = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/settings.json")
                try mergeSettings(at: settings, hookCmd: hookCommand(for: .claude))
            }
        } catch {
            NSLog("%@", describeWriteFailure(
                error, path: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/settings.json").path))
        }
        do { try installCodex() } catch {
            NSLog("%@", describeWriteFailure(
                error, path: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex").path))
        }
    }

    /// The copy of `name` (`planchette-hook`, `planchette`) that ships inside the
    /// app, or nil when this is not the packaged app.
    ///
    /// A dev run — `./.build/debug/Planchette`, which is what AGENTS.md tells you to
    /// do — has no bundle: `Bundle.main.resourceURL` is the folder the executable sits
    /// in. The file system is case-insensitive, so `<that folder>/planchette` *is* the
    /// executable `Planchette`, `fileExists` said yes, and every dev run copied the
    /// 27 MB binary over the installed CLI: agents in the real app's terminals
    /// (`$PLANCHETTE_CLI`) then started a second Planchette instead of talking to the
    /// first. Only a real `.app` has bundled resources.
    static func bundledResource(named name: String, in bundle: Bundle = .main) -> URL? {
        guard bundle.bundleURL.pathExtension == "app",
              let url = bundle.resourceURL?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Copy the bundled `name` to `dest` and make it executable. Refreshed each
    /// launch, so updates ship the latest. Does nothing for a dev run (use
    /// `hook/install-hooks.sh` instead).
    static func deploy(_ name: String, to dest: URL, from bundle: Bundle = .main) throws {
        guard let bundled = bundledResource(named: name, in: bundle) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: bundled)) != (try? Data(contentsOf: dest)) {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: bundled, to: dest)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    private static func deployScript() throws { try deploy("planchette-hook", to: hookScriptURL) }

    /// Same refresh-every-launch deal as the hook script.
    private static func deployCLI() throws { try deploy("planchette", to: cliURL) }

    // MARK: Claude Code — ~/.claude/settings.json

    /// Where a config file really lives. Dotfile managers (stow, chezmoi, a bare
    /// git repo) keep `~/.claude/settings.json` as a symlink into a repository,
    /// and an atomic write — which renames a temp file over its destination —
    /// replaces that symlink with a regular file: the user's dotfiles silently
    /// stop tracking the file, and the hooks never reach the copy they track.
    /// Writing to the resolved path updates the real file and leaves the link
    /// where it is.
    ///
    /// `resolvingSymlinksInPath` leaves a link whose target does not exist yet (the
    /// dotfiles checkout has not been cloned, the file has not been created) as
    /// the link itself, and the write then replaced it. Such a link is followed by
    /// hand, so the file is created where the link points.
    static func realLocation(of url: URL) -> URL {
        let fm = FileManager.default
        var current = url.resolvingSymlinksInPath()
        for _ in 0..<16 {   // a chain of links, not a loop
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = URL(
                fileURLWithPath: destination,
                relativeTo: current.deletingLastPathComponent()
            ).standardizedFileURL.resolvingSymlinksInPath()
        }
        return current
    }

    /// Say why a config file could not be written, in terms of what to do. A file
    /// that is read-only — typically a link into a declarative store such as
    /// home-manager's — is somebody else's to change, and Planchette must not
    /// "fix" it by replacing the link; the hooks have to be added where it is
    /// managed. This runs on every launch, so it only logs.
    static func describeWriteFailure(_ error: Error, path: String) -> String {
        let code = (error as? CocoaError)?.code
        let readOnly = code == .fileWriteNoPermission || code == .fileWriteVolumeReadOnly
            || (error as NSError).domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(EROFS), Int(EPERM)].contains((error as NSError).code)
        return readOnly
            ? "hook install: \(path) is read-only (managed by something else?) — add the "
                + "Planchette hooks there by hand (see docs/API.md); nothing was changed"
            : "hook install: could not write \(path): \(error)"
    }

    /// Copy the file once, before the first change, next to where the user sees it.
    /// The source is the *resolved* file: copying a symlink copies the link, which
    /// would make the "backup" point at the very file about to be rewritten.
    private static func backUpOnce(_ url: URL, as backup: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try? fm.copyItem(at: realLocation(of: url), to: backup)
    }

    /// Merge the Planchette hook into a Claude Code `settings.json`, keeping
    /// every other setting and every foreign hook.
    static func mergeSettings(at settingsURL: URL, hookCmd: String) throws {
        let fm = FileManager.default

        var settings: [String: Any] = [:]
        let exists = fm.fileExists(atPath: settingsURL.path)
        if exists {
            guard let data = try? Data(contentsOf: settingsURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                NSLog("hook install: ~/.claude/settings.json unparseable — skipping")
                return
            }
            settings = obj
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let planchetteCmds = entries
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
                .filter(isPlanchetteCommand)
            // Already exactly our hook → leave it untouched (idempotent).
            if planchetteCmds == [hookCmd] { continue }
            // Otherwise strip any planchette-hook (stale path, missing agent
            // label, duplicate) and add ours, preserving every foreign hook.
            entries = entries.compactMap { entry -> [String: Any]? in
                guard let list = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = list.filter {
                    guard let cmd = $0["command"] as? String else { return true }
                    return !isPlanchetteCommand(cmd)
                }
                if kept.isEmpty { return nil }
                var e = entry; e["hooks"] = kept; return e
            }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": hookCmd]]]
            if toolEvents.contains(event) { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
            changed = true
        }
        guard changed else { return }
        settings["hooks"] = hooks

        // One-time backup before the first modification.
        if exists {
            backUpOnce(
                settingsURL,
                as: settingsURL.deletingPathExtension().appendingPathExtension("json.planchette-bak"))
        }
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        // Write atomically: this is an unlocked read-modify-write of a file Claude
        // Code also owns, and a crash or power loss mid-write would truncate the
        // user's whole settings.json.
        try out.write(to: realLocation(of: settingsURL), options: .atomic)
        NSLog("hook install: wired Planchette hooks into \(settingsURL.path)")
    }

    // MARK: Codex — ~/.codex/hooks.json + config.toml

    private static func installCodex() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hookScriptURL.path) else { return }
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        // No ~/.codex → Codex isn't installed. Creating it would be presumptuous.
        guard fm.fileExists(atPath: dir.path) else { return }

        try mergeCodexHooks(dir: dir, hookCmd: hookCommand(for: .codex))
        try enableCodexHooksFeature(dir: dir)
    }

    static func mergeCodexHooks(dir: URL, hookCmd: String) throws {
        let fm = FileManager.default
        let hooksURL = dir.appendingPathComponent("hooks.json")

        var root: [String: Any] = [:]
        let exists = fm.fileExists(atPath: hooksURL.path)
        if exists {
            guard let data = try? Data(contentsOf: hooksURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                NSLog("hook install: ~/.codex/hooks.json unparseable — skipping")
                return
            }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in codexEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let ours = entries
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
                .filter(isPlanchetteCommand)
            if ours == [hookCmd] { continue }
            entries = entries.compactMap { entry -> [String: Any]? in
                guard let list = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = list.filter {
                    guard let cmd = $0["command"] as? String else { return true }
                    return !isPlanchetteCommand(cmd)
                }
                if kept.isEmpty { return nil }
                var e = entry; e["hooks"] = kept; return e
            }
            entries.append(["hooks": [["type": "command", "command": hookCmd]]])
            hooks[event] = entries
            changed = true
        }
        guard changed else { return }
        root["hooks"] = hooks

        if exists {
            backUpOnce(
                hooksURL,
                as: hooksURL.deletingPathExtension().appendingPathExtension("json.planchette-bak"))
        }
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // Atomic for the same reason as settings.json: never leave a half-written
        // config behind if the write is interrupted.
        try out.write(to: realLocation(of: hooksURL), options: .atomic)
        NSLog("hook install: wired Planchette hooks into \(hooksURL.path)")
    }

    /// Codex only runs hooks when the feature is switched on in config.toml.
    /// Edited as text, not re-serialized: config.toml is the user's file and a
    /// TOML round-trip would drop their comments and ordering.
    static func enableCodexHooksFeature(dir: URL) throws {
        let url = dir.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let updated = codexConfigEnablingHooks(existing) else { return }
        try updated.write(to: realLocation(of: url), atomically: true, encoding: .utf8)
        NSLog("hook install: enabled codex hooks in \(url.path)")
    }

    /// Pure: returns the config text with `hooks = true` under `[features]`, or
    /// nil when it is already enabled and nothing needs writing.
    static func codexConfigEnablingHooks(_ content: String) -> String? {
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        var inFeatures = false
        var featuresIndex: Int?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inFeatures = line == "[features]"
                if inFeatures, featuresIndex == nil { featuresIndex = index }
                continue
            }
            guard inFeatures else { continue }
            // `hooks = <anything>` already present: only flip an explicit false.
            let key = line.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces)
            if key == "hooks" {
                if line.contains("true") { return nil }
                lines[index] = "hooks = true"
                return lines.joined(separator: "\n")
            }
        }
        if let featuresIndex {
            lines.insert("hooks = true", at: featuresIndex + 1)
            return lines.joined(separator: "\n")
        }
        var appended = content
        if !appended.isEmpty, !appended.hasSuffix("\n") { appended += "\n" }
        if !appended.isEmpty { appended += "\n" }
        appended += "[features]\nhooks = true\n"
        return appended
    }
}

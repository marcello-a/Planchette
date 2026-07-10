import Foundation

/// Installs the Claude Code hooks so Planchette receives attention events with
/// zero manual setup. Runs on every launch and is idempotent: it deploys the
/// bundled hook script to a stable location and merges the hook entries into
/// `~/.claude/settings.json` (never overwriting other hooks; a one-time backup
/// is kept). If settings.json can't be parsed, it does nothing rather than risk
/// clobbering the user's config.
enum HookInstaller {
    /// The Claude hook events Planchette reacts to (see AppState.applyHookEvent).
    static let events = [
        "SessionStart", "UserPromptSubmit", "Notification",
        "PermissionRequest", "Stop", "SubagentStop", "SessionEnd",
    ]

    /// Stable path for the hook script — in Application Support, so it survives
    /// app moves/updates (settings.json references it by absolute path).
    static var hookScriptURL: URL {
        AppState.stateURL.deletingLastPathComponent().appendingPathComponent("planchette-hook")
    }

    static func installIfNeeded() {
        do {
            try deployScript()
            try mergeSettings()
        } catch {
            NSLog("hook install failed: \(error)")
        }
    }

    /// Copy the bundled hook script to the stable location and make it
    /// executable. Refreshed each launch so updates ship the latest script.
    private static func deployScript() throws {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("planchette-hook"),
              FileManager.default.fileExists(atPath: bundled.path)
        else { return }   // dev run (unbundled) — use hook/install-hooks.sh instead
        let dest = hookScriptURL
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: bundled)) != (try? Data(contentsOf: dest)) {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: bundled, to: dest)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    private static func mergeSettings() throws {
        let fm = FileManager.default
        // Only wire up settings if the hook script is actually deployed.
        guard fm.fileExists(atPath: hookScriptURL.path) else { return }
        let settingsURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let hookCmd = hookScriptURL.path

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
                .filter { ($0 as NSString).lastPathComponent == "planchette-hook" }
            // Already exactly our hook → leave it untouched (idempotent).
            if planchetteCmds == [hookCmd] { continue }
            // Otherwise strip any planchette-hook (stale path / duplicate) and
            // add ours, preserving every non-Planchette hook.
            entries = entries.compactMap { entry -> [String: Any]? in
                guard let list = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = list.filter {
                    (($0["command"] as? String) as NSString?)?.lastPathComponent != "planchette-hook"
                }
                if kept.isEmpty { return nil }
                var e = entry; e["hooks"] = kept; return e
            }
            entries.append(["hooks": [["type": "command", "command": hookCmd]]])
            hooks[event] = entries
            changed = true
        }
        guard changed else { return }
        settings["hooks"] = hooks

        // One-time backup before the first modification.
        if exists {
            let backup = settingsURL.deletingPathExtension().appendingPathExtension("json.planchette-bak")
            if !fm.fileExists(atPath: backup.path) {
                try? fm.copyItem(at: settingsURL, to: backup)
            }
        }
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL)
        NSLog("hook install: wired Planchette hooks into \(settingsURL.path)")
    }
}

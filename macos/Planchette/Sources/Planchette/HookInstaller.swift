import AppKit

/// Installs the Claude Code hooks that feed Planchette's attention engine and
/// session resume. Self-contained Swift port of hook/install-hooks.sh so the
/// app can offer the install on first launch (merge, never overwrite; a backup
/// is written next to the settings file).
enum HookInstaller {
    static let events = [
        "SessionStart", "UserPromptSubmit", "Notification",
        "PermissionRequest", "Stop", "SessionEnd",
    ]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// The hook script lives in Application Support — a stable path that
    /// survives app updates and relocations.
    static var hookBinURL: URL {
        AppState.stateURL.deletingLastPathComponent()
            .appendingPathComponent("planchette-hook")
    }

    /// Verbatim copy of hook/planchette-hook.
    static let hookScript = """
    #!/bin/sh
    # planchette-hook — forwards a Claude Code hook event to the Planchette app.
    # Installed by Planchette.app. Always exit 0: a missing/busy app must never
    # block Claude.

    [ -n "$PLANCHETTE_SESSION" ] || exit 0

    SOCKET="${PLANCHETTE_SOCKET:-/tmp/planchette.sock}"
    [ -S "$SOCKET" ] || exit 0

    payload=$(cat)
    [ -n "$payload" ] || payload='{}'

    printf '{"planchette_session":"%s","event":%s}' "${PLANCHETTE_SESSION:-}" "$payload" \\
        | nc -U "$SOCKET" >/dev/null 2>&1 || true

    exit 0
    """

    /// Whether any hook entry already points at a planchette-hook (either the
    /// repo script or our installed copy).
    static func isInstalled(settings: URL = settingsURL) -> Bool {
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return text.contains("planchette-hook")
    }

    static func install(settings: URL = settingsURL, hookBin: URL = hookBinURL) throws {
        try FileManager.default.createDirectory(
            at: hookBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try hookScript.write(to: hookBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hookBin.path)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settings) {
            root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let backup = settings.appendingPathExtension("planchette-bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: settings, to: backup)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let already = entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains("planchette-hook") == true
                }
            }
            if !already {
                entries.append(["hooks": [["type": "command", "command": hookBin.path]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: settings, options: .atomic)
    }

    /// Launch-time offer: shown while the hooks are missing, until the user
    /// installs or checks "don't ask again".
    @MainActor
    static func offerInstallIfNeeded() {
        let suppressKey = "hookInstallDeclined"
        guard !isInstalled(), !UserDefaults.standard.bool(forKey: suppressKey) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.t(.hooksTitle)
        alert.informativeText = L10n.t(.hooksBody)
        alert.addButton(withTitle: L10n.t(.hooksInstall))
        alert.addButton(withTitle: L10n.t(.hooksLater))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.t(.hooksDontAsk)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return }

        do {
            try install()
        } catch {
            let fail = NSAlert()
            fail.alertStyle = .warning
            fail.messageText = L10n.t(.hooksFailed)
            fail.informativeText = error.localizedDescription
            fail.runModal()
        }
    }
}

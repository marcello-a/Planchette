import Foundation

/// Where this instance keeps everything it owns — state.json, scrollback,
/// presets, the screen-rule override, the tmux config, the hook socket pointer.
///
/// `PLANCHETTE_STATE_DIR` moves all of it at once, which is the only way to run
/// a second instance that cannot touch the first one's workspace. Redirecting
/// `$HOME` does **not** work: on macOS `NSHomeDirectory()` and the Application
/// Support URL come from the user record and ignore the environment, so a launch
/// with a redirected HOME silently opens the real workspace — and re-attaches
/// its live durable agents. Learned the hard way; see AGENTS.md.
///
/// Deliberately not on `AppState`: `Durable` reads these off the main actor.
enum SupportPaths {
    static let overrideKey = "PLANCHETTE_STATE_DIR"

    /// True when this instance runs against an overridden directory. It must then
    /// keep away from everything the normal instance owns — including its tmux
    /// server, whose sessions it would otherwise consider its own to reap.
    static var isIsolated: Bool {
        !(ProcessInfo.processInfo.environment[overrideKey] ?? "").isEmpty
    }

    static let dir: URL = {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Planchette", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A suffix that keeps per-instance resources apart (the tmux server name).
    /// Derived from the directory, so the same override always maps to the same
    /// server and a restart re-attaches its own sessions rather than orphaning them.
    static var instanceSuffix: String? {
        guard isIsolated else { return nil }
        let digest = abs(dir.path.hashValue)
        return String(format: "%08x", digest & 0xFFFF_FFFF)
    }
}

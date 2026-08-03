import Foundation

/// Durable terminals: the agent runs inside a **tmux** session, so its process
/// tree belongs to tmux's server instead of to Planchette.
///
/// Why this exists: Planchette *is* the terminal. libghostty forks the shell in
/// our process and holds the PTY master, so when the app exits the slave side
/// gets SIGHUP and every agent under it dies — an update, a crash or a quit ends
/// every running turn, and restore can only replay `claude --resume`, never the
/// work that was in flight. libghostty cannot adopt an existing PTY (there is no
/// fd or pty field in `ghostty_surface_config_s`), so the fix is not to make the
/// PTY survive but to make the *agent* survive: put it behind a multiplexer that
/// outlives us and re-attach on the way back.
///
/// What it does and does not cover:
/// - covers app quit, Install & Relaunch, and an app crash,
/// - does **not** cover a reboot or a logout, which end tmux's server too.
enum Durable {
    /// Where tmux normally lives. Searched in order, absolutely: a GUI app's
    /// PATH does not include Homebrew, so `which tmux` is no use to us.
    static let candidatePaths = [
        "/opt/homebrew/bin/tmux",   // Apple silicon Homebrew
        "/usr/local/bin/tmux",      // Intel Homebrew, manual installs
        "/opt/local/bin/tmux",      // MacPorts
        "/usr/bin/tmux",            // a future system tmux
    ]

    /// Pure (with an injectable probe, so it is testable): the first tmux found.
    static func tmuxPath(
        searching candidates: [String] = candidatePaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: isExecutable)
    }

    static var isAvailable: Bool { tmuxPath() != nil }

    /// The tmux session name for a terminal. Derived from the persisted session
    /// id, which is what makes re-attach possible after a restart — the id is
    /// stable, so the name is too. Lowercased and dot-free: tmux treats `.` and
    /// `:` as window/pane separators in target names.
    static func sessionName(for id: UUID) -> String {
        "planchette-" + id.uuidString.lowercased()
    }

    /// Pure: the command a durable terminal runs instead of a plain shell.
    ///
    /// `-A` attaches to the session when it already exists and creates it
    /// otherwise — one command for both first launch and re-attach. `-D` detaches
    /// any other client, which is how the *stale* client left behind by a crashed
    /// Planchette gets evicted instead of fighting us for the terminal size.
    ///
    /// `-e` is not a convenience: a pane does **not** inherit the client's
    /// environment. One tmux server serves every session and keeps the
    /// environment of the client that happened to start it, so without `-e` the
    /// second durable terminal would run with the *first* one's
    /// `PLANCHETTE_SESSION` and report every hook event as that terminal.
    /// Values are only applied when the session is created; re-attaching leaves
    /// the existing session's environment alone, which is correct — its processes
    /// already hold those values, and the session id is stable across restarts.
    static func attachCommand(
        tmux: String,
        session: String,
        environment: [(key: String, value: String)] = []
    ) -> String {
        var parts = [tmux, "new-session", "-A", "-D", "-s", session]
        for (key, value) in environment {
            parts.append("-e")
            parts.append(singleQuoted("\(key)=\(value)"))
        }
        // Durability is plumbing, not a feature the user asked for, so tmux must
        // not show through: no status bar eating the bottom row, and no prefix
        // swallowing keystrokes (the default C-b is backward-char in every
        // emacs-mode shell, and agent TUIs bind it too). Set per session with
        // `-t`, never globally — the user's own tmux sessions are not ours to
        // reconfigure. Re-running these on re-attach is harmless.
        for option in ["status off", "prefix None"] {
            parts.append("\\;")
            parts.append("set-option -t \(session) \(option)")
        }
        return parts.joined(separator: " ")
    }

    /// Pure: POSIX single-quoting, so a value carrying quotes, `$` or `|` — the
    /// click command carries all three — survives the shell that runs this.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Talking to tmux

    /// Run tmux and return its exit status. Cheap and synchronous; used for the
    /// one-shot `has-session` probe at terminal creation.
    @discardableResult
    private static func run(_ tmux: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func output(_ tmux: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// End a session and everything in it. Called when a terminal or a whole
    /// project is closed on purpose — without this, durable sessions would pile
    /// up in tmux forever.
    static func killSession(for id: UUID) {
        guard let tmux = tmuxPath() else { return }
        run(tmux, ["kill-session", "-t", "=\(sessionName(for: id))"])
    }

    /// Everything the app needs to know about our sessions, in **one** call.
    /// Both questions asked of tmux — "is this terminal's agent still alive?"
    /// and "which sessions are orphans?" — are answered from this list, so a
    /// restore costs one subprocess rather than one per terminal.
    static func listSessions() -> [(id: UUID, attached: Bool)] {
        guard let tmux = tmuxPath(),
              let out = output(
                tmux, ["list-sessions", "-F", "#{session_name} #{session_attached}"])
        else { return [] }
        return parseSessionList(out)
    }

    /// Pure: every terminal tmux still holds a session for — i.e. whose agent
    /// survived and must be re-attached to rather than replayed into.
    static func liveIDs(in sessions: [(id: UUID, attached: Bool)]) -> Set<UUID> {
        Set(sessions.map(\.id))
    }

    /// Pure: the sessions safe to reap.
    ///
    /// An attached session belongs to a Planchette that is running right now: a
    /// second instance starting fresh must not kill the first one's agents, and
    /// "is anyone attached" is the question that actually distinguishes the two.
    /// An orphan — the terminal was closed, or its app died — has no client,
    /// because the client dies with the app.
    static func unattachedIDs(in sessions: [(id: UUID, attached: Bool)]) -> Set<UUID> {
        Set(sessions.filter { !$0.attached }.map(\.id))
    }

    static func unattachedSessionIDs() -> Set<UUID> { unattachedIDs(in: listSessions()) }

    /// Pure: parse `tmux list-sessions -F '#{session_name} #{session_attached}'`.
    /// Anything that is not one of ours is ignored — the user's own tmux sessions
    /// are none of our business. A line without a readable attached count is
    /// reported as attached, so an unparsable session is never reaped.
    static func parseSessionList(_ output: String) -> [(id: UUID, attached: Bool)] {
        var sessions: [(id: UUID, attached: Bool)] = []
        for line in output.components(separatedBy: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
            guard let name = fields.first, name.hasPrefix("planchette-") else { continue }
            let raw = String(name.dropFirst("planchette-".count))
            guard let id = UUID(uuidString: raw) else { continue }
            let attached = fields.count > 1 ? fields[1] != "0" : true
            sessions.append((id, attached))
        }
        return sessions
    }
}

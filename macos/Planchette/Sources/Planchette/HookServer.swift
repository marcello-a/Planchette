import Foundation

/// Unix-domain-socket server receiving one JSON payload per connection from
/// `planchette-hook`, which Claude Code invokes on hook events.
final class HookServer {
    /// Per-instance path: a fixed path lets a second instance (e.g. a dev
    /// build) unlink+rebind it and silently cut off the running app's hooks.
    /// The hook finds us via the PLANCHETTE_SOCKET env var in each terminal.
    static let socketPath = "/tmp/planchette-\(getpid()).sock"

    /// Stable pointer to the live socket, for callers whose environment is stale.
    /// A durable terminal's agent survives our restart (see Durable.swift) with
    /// the *old* pid's socket path baked into its environment — the hook and the
    /// CLI fall back to reading this file, so the attention engine keeps working
    /// for an agent that outlived the app that started it.
    /// An isolated instance publishes its pointer inside its own state directory:
    /// overwriting `~/.planchette/socket` would send the hooks of the normal
    /// instance's terminals to this one.
    static var socketPointerURL: URL {
        if SupportPaths.isIsolated {
            return SupportPaths.dir.appendingPathComponent("socket")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".planchette", isDirectory: true)
            .appendingPathComponent("socket")
    }

    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "planchette.hook-server")
    private let readQueue = DispatchQueue(label: "planchette.hook-server.read", attributes: .concurrent)
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        unlink(Self.socketPath)
        Self.removeSocketsOfDeadInstances()

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("hook-server: socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            Self.socketPath.utf8CString.withUnsafeBytes { src in
                buf.copyBytes(from: src.prefix(buf.count - 1))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0, listen(fd, 32) == 0 else {
            NSLog("hook-server: bind/listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            // Reset the field so stop() does not close this descriptor a second
            // time — by then the kernel may have handed the number to an unrelated
            // fd, which we would then wrongly close.
            fd = -1
            return
        }
        // Only the owner may connect — the socket carries no auth and its events
        // drive UI state, so keep other local users/processes out.
        chmod(Self.socketPath, 0o600)

        publishSocketPointer()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
        NSLog("hook-server: listening on \(Self.socketPath)")
    }

    func stop() {
        acceptSource?.cancel()
        if fd >= 0 { close(fd) }
        unlink(Self.socketPath)
        // Only clear the pointer if it still names *our* socket: a second
        // instance may have taken over in the meantime.
        if (try? String(contentsOf: Self.socketPointerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == Self.socketPath {
            try? FileManager.default.removeItem(at: Self.socketPointerURL)
        }
    }

    /// Delete `/tmp/planchette-<pid>.sock` files whose process is gone.
    ///
    /// An app killed rather than quit never runs `stop()`, so its socket file
    /// outlives it. That matters beyond tidiness: a caller inside a durable
    /// terminal tests `-S $PLANCHETTE_SOCKET` to decide whether it still has a
    /// live app, and a leftover file makes that test lie — the caller then talks
    /// to nothing instead of falling back to the published pointer.
    ///
    /// Only files whose pid is dead are touched, so a second running instance
    /// keeps its own socket (that separation is the point of the per-pid name).
    static func removeSocketsOfDeadInstances() {
        let dir = "/tmp"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            guard let pid = pidOfSocketFile(named: name), pid != getpid() else { continue }
            // ESRCH = no such process. EPERM would mean it exists but is not
            // ours, which is reason to leave it alone.
            if kill(pid, 0) != 0, errno == ESRCH {
                unlink("\(dir)/\(name)")
            }
        }
    }

    /// Pure: the pid encoded in a `planchette-<pid>.sock` filename, if it is one.
    static func pidOfSocketFile(named name: String) -> pid_t? {
        let prefix = "planchette-", suffix = ".sock"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let pid = pid_t(digits), pid > 0
        else { return nil }
        return pid
    }

    private func publishSocketPointer() {
        let url = Self.socketPointerURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (Self.socketPath + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("hook-server: could not publish socket pointer: \(error)")
        }
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }

        // Read each connection off the accept path so one slow/stuck client
        // can't block the serial accept queue and stall all hook events. A
        // receive timeout bounds a client that connects and never sends EOF.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        readQueue.async { [weak self] in
            var replied = false
            defer { if !replied { close(client) } }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            // Cap total payload so a flood can't grow memory unbounded.
            let maxBytes = 1 << 20
            while data.count < maxBytes {
                let n = read(client, &buf, buf.count)
                guard n > 0 else { break }
                data.append(buf, count: n)
            }
            // A control request answers on the same connection and owns the fd
            // from here on; a hook event is fire-and-forget.
            replied = self?.handle(data: data, client: client) ?? false
        }
    }

    /// Write a response and close. Errors are ignored: a client that walked away
    /// is normal and must never take the server down.
    ///
    /// Always off the main thread: a `session.read --scrollback` response can be
    /// far larger than the socket buffer, and then `write` blocks until the
    /// client drains it (AGENTS.md rule 5).
    private func reply(_ data: Data, to client: Int32) {
        readQueue.async { Self.writeAndClose(data, to: client) }
    }

    private static func writeAndClose(_ data: Data, to client: Int32) {
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        close(client)
    }

    /// Returns true when the connection has been answered (and closed) here.
    private func handle(data: Data, client: Int32) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("hook-server: unparseable payload, ignored")
            return false
        }

        // Control requests (agents driving Planchette) answer on this connection.
        if let parsed = ControlAPI.parse(obj) {
            switch parsed {
            case .failure(let failure):
                reply(ControlAPI.encode(ok: false, error: failure.message), to: client)
            case .success(let request):
                Task { @MainActor [weak self] in
                    guard let appState = self?.appState else {
                        self?.reply(
                            ControlAPI.encode(ok: false, error: "app not ready"), to: client)
                        return
                    }
                    let response = await ControlAPI.handle(request, state: appState)
                    self?.reply(response, to: client)
                }
            }
            return true
        }

        guard
            let sessionString = obj["planchette_session"] as? String,
            let sessionID = UUID(uuidString: sessionString)
        else {
            NSLog("hook-server: payload without valid planchette_session, ignored")
            return false
        }
        let event = obj["event"] as? [String: Any] ?? [:]
        let hookEvent = event["hook_event_name"] as? String ?? ""
        // Which agent spoke — the hook script passes its own label.
        let agent = AgentKind(hookLabel: obj["agent"] as? String)

        // Not a Claude Code event: sent by the PEON_CLICK_COMMAND we inject,
        // when the user clicks a desktop notification for this session.
        if hookEvent == "PlanchetteFocus" {
            DispatchQueue.main.async { [weak self] in
                self?.appState?.focusSession(sessionID)
            }
            return false
        }

        let claudeSessionID = event["session_id"] as? String
        let transcriptPath = event["transcript_path"] as? String
        let message = event["message"] as? String
        // UserPromptSubmit carries the submitted prompt itself — the direct
        // answer to "what is this agent working on?".
        let prompt = event["prompt"] as? String
        // SessionStart tells us *why* a conversation began (startup / clear /
        // resume / compact / fork) — which decides whether it starts out free.
        let source = event["source"] as? String

        DispatchQueue.main.async { [weak self] in
            self?.appState?.applyHookEvent(
                sessionID: sessionID,
                hookEvent: hookEvent,
                claudeSessionID: claudeSessionID,
                transcriptPath: transcriptPath,
                message: message,
                prompt: prompt,
                source: source,
                agent: agent
            )
        }
        return false
    }
}

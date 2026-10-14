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

    /// A hook event or a control request is one small JSON object. This bounds the
    /// memory one connection can claim; a prompt pasted from a log is the largest
    /// thing an event carries, and 4 MiB is far beyond any of those.
    static let maxPayloadBytes = 4 << 20
    /// How long a client gets to deliver its payload — in total. A per-read
    /// timeout alone lets a client that sends one byte every few seconds hold a
    /// thread for as long as it likes. Real clients (`nc`, the CLI) are done in
    /// milliseconds, so this only ever bounds a stuck one — and every second of it
    /// is a second a connection slot is taken.
    static let readDeadline: TimeInterval = 5
    /// Connections being READ at once. A reader holds a thread until its client has
    /// delivered the request, and a stuck client can make that a full deadline;
    /// without a cap a flood of them would starve every hook event of a thread.
    ///
    /// The slot is given back the moment the read ends. It must not span the
    /// answer: a `session.wait` is answered minutes later, and 64 of them (or 64
    /// whose callers were killed) would otherwise leave no slot for the hook
    /// events that keep every terminal's state true.
    static let maxConcurrentConnections = 64
    /// Control requests accepted but not yet answered. A `session.wait` can take
    /// minutes; each one holds a descriptor and a polling task on the main actor,
    /// so a client that opens them in a loop is bounded here instead of there.
    static let maxPendingRequests = 64

    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "planchette.hook-server")
    private let readQueue = DispatchQueue(label: "planchette.hook-server.read", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: HookServer.maxConcurrentConnections)
    private let pendingLock = NSLock()
    private var pendingRequests = 0
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        unlink(Self.socketPath)
        Self.removeSocketsOfDeadInstances()

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("hook-server: socket() failed"); return }
        // Not inherited by the shells and agents this process starts: a copy of the
        // listening descriptor in a surviving child would keep answering `connect`
        // after the app is gone, which is exactly the "dead socket that looks
        // alive" the hook's fallback logic exists to avoid.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

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
        // The kernel queues connections the app has not accepted yet, and refuses
        // (ECONNREFUSED) the ones that do not fit. A burst — every durable agent
        // reporting at once after a restart — must reach the app's own limits, which
        // refuse deliberately and are counted, not be cut off by chance at 32.
        guard bindResult == 0, listen(fd, 128) == 0 else {
            NSLog("hook-server: bind/listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            // Reset the field so stop() does not close this descriptor a second
            // time — by then the kernel may have handed the number to an unrelated
            // fd, which we would then wrongly close.
            fd = -1
            return
        }
        // Only the owner may connect — the socket carries no auth and its events
        // drive UI state, so keep other local users/processes out. The file mode
        // is the first line of defence; `admit` checks the peer's uid as the
        // second, because the socket lives in a world-writable directory.
        chmod(Self.socketPath, 0o600)
        // Non-blocking, so draining the backlog ends on EAGAIN instead of parking
        // the accept thread when a client gives up between the readiness
        // notification and `accept`.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        publishSocketPointer()

        let listening = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: listening, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: listening) }
        // The descriptor is closed by the source itself, once no handler can still
        // be running on it — closing it from `stop()` raced the handler.
        source.setCancelHandler { close(listening) }
        source.resume()
        acceptSource = source
        NSLog("hook-server: listening on \(Self.socketPath)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        fd = -1
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

    /// Take every connection that is waiting. Works on the descriptor the source
    /// was made for, not on `fd`: `stop()` resets that field from another thread.
    private func acceptPending(on listening: Int32) {
        while true {
            let client = accept(listening, nil, nil)
            if client >= 0 {
                admit(client)
                continue
            }
            switch errno {
            case EINTR, ECONNABORTED:
                continue
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // Out of descriptors: the connection stays queued, so the source
                // would fire again at once and spin. Let the process recover.
                NSLog("hook-server: accept failed (\(String(cString: strerror(errno))))")
                usleep(100_000)
                return
            default:
                return   // EAGAIN: the backlog is empty
            }
        }
    }

    /// True when the process at the other end of `fd` runs as this user. The
    /// socket file is 0600, but it sits in /tmp, where a name can be taken or a
    /// mode loosened by something else — so the kernel's answer about who is
    /// really connected decides, not the path.
    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    /// Refusals are logged at most once a second, with a count: a client that
    /// connects in a loop must not also be able to flood the log. Only touched from
    /// `queue` (the serial accept queue), where `admit` runs.
    private var refusals = 0
    private var lastRefusalLog: UInt64 = 0

    private func logRefusal(_ reason: String) {
        refusals += 1
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastRefusalLog > 1_000_000_000 else { return }
        lastRefusalLog = now
        NSLog("hook-server: refused a connection (\(reason)); \(refusals) so far")
    }

    private func admit(_ client: Int32) {
        guard Self.peerIsCurrentUser(client) else {
            logRefusal("another user")
            close(client)
            return
        }
        // The accepted socket may inherit the listener's O_NONBLOCK; the read
        // below is a poll loop over blocking reads.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // A client that has gone away must fail the write with EPIPE, never kill
        // the process with SIGPIPE. AppKit happens to ignore the signal today;
        // this does not depend on it.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A client that stops reading a large reply must not park a thread for
        // good (see `writeAndClose`).
        var sendTimeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard slots.wait(timeout: .now()) == .success else {
            logRefusal("too many open connections")
            close(client)
            return
        }

        // Read each connection off the accept path so one slow/stuck client
        // can't block the serial accept queue and stall all hook events.
        readQueue.async { [weak self] in
            let payload = Self.readPayload(
                from: client, deadline: Self.readDeadline, maxBytes: Self.maxPayloadBytes)
            // The slot covers the read and nothing after it (see
            // `maxConcurrentConnections`).
            self?.slots.signal()
            guard let data = payload else {
                close(client)
                return
            }
            // A control request answers on the same connection and owns the fd
            // from here on; a hook event is fire-and-forget.
            if self?.handle(data: data, client: client) != true { close(client) }
        }
    }

    /// Everything the client sends until it closes its side, the deadline passes,
    /// or the payload would exceed `maxBytes` (then nil: half a request is not a
    /// request, and truncating JSON only produces a confusing parse error).
    ///
    /// The deadline covers the whole read. A client that connects and never closes
    /// (macOS `nc` cannot half-close) ends at the deadline with what it sent,
    /// which is how a complete request from such a client is still served.
    static func readPayload(from client: Int32, deadline: TimeInterval, maxBytes: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let left = deadline - elapsed
            if left <= 0 { break }
            var watch = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watch, 1, Int32(min(left, 3600) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }
            let count = read(client, &buffer, buffer.count)
            // A signal landing mid-read is not the end of the request.
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { break }   // EOF, or the connection broke
            data.append(buffer, count: count)
            if data.count > maxBytes {
                NSLog("hook-server: payload over \(maxBytes) bytes, dropped")
                return nil
            }
        }
        return data
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

    private func beginPending() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard pendingRequests < Self.maxPendingRequests else { return false }
        pendingRequests += 1
        return true
    }

    private func endPending() {
        pendingLock.lock()
        pendingRequests -= 1
        pendingLock.unlock()
    }

    /// True when the process at the other end has closed the connection for good —
    /// not merely finished sending.
    ///
    /// A client that sent its request and half-closed (the protocol: "the app
    /// answers on EOF") is still waiting for the reply, and `poll` cannot tell it
    /// from one that is gone: both read as `POLLIN|POLLHUP` on macOS (measured).
    /// kqueue's write filter can — it carries `EV_EOF` only once the peer has
    /// fully closed. A `session.wait` whose caller was Ctrl-C'd, timed out or
    /// killed used to keep waiting, and keep its descriptor, for its whole
    /// timeout (up to an hour).
    static func clientHasGone(_ fd: Int32) -> Bool {
        // `UInt(fd)` traps on a negative number, and this runs on the main actor.
        guard fd >= 0 else { return false }
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(fd), filter: Int16(EVFILT_WRITE),
            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: 0, data: 0, udata: nil)
        var event = kevent()
        var none = timespec(tv_sec: 0, tv_nsec: 0)
        guard kevent(queue, &change, 1, &event, 1, &none) > 0 else { return false }
        return event.flags & UInt16(EV_EOF) != 0
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
                guard beginPending() else {
                    reply(ControlAPI.encode(
                        ok: false, error: "too many requests in flight; try again shortly"),
                          to: client)
                    return true
                }
                Task { @MainActor [weak self] in
                    defer { self?.endPending() }
                    guard let appState = self?.appState else {
                        self?.reply(
                            ControlAPI.encode(ok: false, error: "app not ready"), to: client)
                        return
                    }
                    let response = await ControlAPI.handle(
                        request, state: appState,
                        clientAlive: { !HookServer.clientHasGone(client) })
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
        // What the event says about background shells and agents (Claude only:
        // the other agents' hooks carry none of these fields).
        let background = BackgroundTasks.signal(from: event)

        DispatchQueue.main.async { [weak self] in
            self?.appState?.applyHookEvent(
                sessionID: sessionID,
                hookEvent: hookEvent,
                claudeSessionID: claudeSessionID,
                transcriptPath: transcriptPath,
                message: message,
                prompt: prompt,
                source: source,
                agent: agent,
                background: background
            )
        }
        return false
    }
}

import Foundation

/// Unix-domain-socket server receiving one JSON payload per connection from
/// `planchette-hook`, which Claude Code invokes on hook events.
final class HookServer {
    /// Per-instance path: a fixed path lets a second instance (e.g. a dev
    /// build) unlink+rebind it and silently cut off the running app's hooks.
    /// The hook finds us via the PLANCHETTE_SOCKET env var in each terminal.
    static let socketPath = "/tmp/planchette-\(getpid()).sock"

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
            return
        }
        // Only the owner may connect — the socket carries no auth and its events
        // drive UI state, so keep other local users/processes out.
        chmod(Self.socketPath, 0o600)

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
            defer { close(client) }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            // Cap total payload so a flood can't grow memory unbounded.
            let maxBytes = 1 << 20
            while data.count < maxBytes {
                let n = read(client, &buf, buf.count)
                guard n > 0 else { break }
                data.append(buf, count: n)
            }
            self?.handle(data: data)
        }
    }

    private func handle(data: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionString = obj["planchette_session"] as? String,
            let sessionID = UUID(uuidString: sessionString)
        else {
            NSLog("hook-server: payload without valid planchette_session, ignored")
            return
        }
        let event = obj["event"] as? [String: Any] ?? [:]
        let hookEvent = event["hook_event_name"] as? String ?? ""

        // Not a Claude Code event: sent by the PEON_CLICK_COMMAND we inject,
        // when the user clicks a desktop notification for this session.
        if hookEvent == "PlanchetteFocus" {
            DispatchQueue.main.async { [weak self] in
                self?.appState?.focusSession(sessionID)
            }
            return
        }

        let claudeSessionID = event["session_id"] as? String
        let transcriptPath = event["transcript_path"] as? String
        let message = event["message"] as? String

        DispatchQueue.main.async { [weak self] in
            self?.appState?.applyHookEvent(
                sessionID: sessionID,
                hookEvent: hookEvent,
                claudeSessionID: claudeSessionID,
                transcriptPath: transcriptPath,
                message: message
            )
        }
    }
}

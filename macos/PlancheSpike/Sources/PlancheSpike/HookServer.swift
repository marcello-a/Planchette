import Foundation

/// Spike C: minimal unix-domain-socket server receiving one JSON line per
/// connection from `planchette-hook` (which Claude Code hooks invoke).
final class HookServer: ObservableObject {
    struct Event: Identifiable {
        let id = UUID()
        let session: String
        let hookEvent: String
        let message: String
        let receivedAt = Date()
    }

    @Published var lastEvent: Event?

    static let socketPath = "/tmp/planchette-spike.sock"
    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "planchette.hook-server")

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
        guard bindResult == 0, listen(fd, 16) == 0 else {
            NSLog("hook-server: bind/listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
        NSLog("hook-server: listening on \(Self.socketPath)")
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &buf, buf.count)
            guard n > 0 else { break }
            data.append(buf, count: n)
        }
        handle(data: data)
    }

    private func handle(data: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("hook-server: unparseable payload: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return
        }
        let session = obj["planchette_session"] as? String ?? "<unknown>"
        let inner = obj["event"] as? [String: Any] ?? [:]
        let event = Event(
            session: session,
            hookEvent: inner["hook_event_name"] as? String ?? "<unknown>",
            message: inner["message"] as? String ?? ""
        )
        NSLog("hook-server: event=\(event.hookEvent) session=\(event.session) message=\(event.message)")
        DispatchQueue.main.async { self.lastEvent = event }
    }
}

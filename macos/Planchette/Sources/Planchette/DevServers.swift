import Foundation

/// A development server listening on this machine, attributed to the project
/// whose checkout it runs in. Found by scanning processes, not terminal
/// output — so a server started in an IDE's integrated terminal (or anywhere
/// else) shows up exactly like one started in a Planchette terminal.
struct DevServer: Identifiable, Equatable {
    let port: Int
    /// The process name (`node`, `python`, …) — shown on hover so a chip can
    /// say what is actually serving.
    let processName: String
    /// The server process's working directory — the evidence that ties it to
    /// its project.
    let directory: String
    /// The address the server itself printed for this port — its network URL
    /// when it announced one, read off the terminal (see `bestURL`). Nil until
    /// one is found; only then can a chip know the scheme and the host, and
    /// `https://vite.myposter.de:8082` is a different page from
    /// `http://localhost:8082`.
    var resolvedURL: URL?

    var id: Int { port }

    /// Where a click goes: what the server announced, else the honest guess.
    var url: URL { resolvedURL ?? URL(string: "http://localhost:\(port)")! }

    /// The chip's text — the port alone. The host is what the tooltip and the
    /// click are for; a row of "localhost:" prefixes says nothing that the
    /// port does not.
    var label: String { "\(port)" }
}

/// Finds dev servers by asking the OS who is listening: one `lsof` for the
/// listening sockets, one for those processes' working directories, then a
/// pure match of directory → project. Everything that parses or matches is
/// pure and unit-tested; only `scan` touches the system.
enum DevServerScanner {
    /// One listening TCP socket: who, what, where.
    struct Listener: Equatable {
        let pid: Int
        let command: String
        let port: Int
    }

    /// Ports above this are ephemeral (macOS hands them to any process that
    /// asks); a dev server you would open in a browser sits below.
    static let ephemeralPortFloor = 49152

    /// Listeners that are never a page you'd open: debugger and IDE-internal
    /// ports that happen to run inside a checkout.
    static let ignoredPorts: Set<Int> = [9229]  // node --inspect

    /// IDE helper processes listen from inside the workspace; they serve the
    /// IDE, not the project.
    static let ignoredCommands: Set<String> = ["Code Helper", "Cursor Helper", "Electron"]

    /// Parse `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` field output: `p<pid>`,
    /// `c<command>`, then one `n<addr>` per socket. Dedupes IPv4/IPv6 twins of
    /// the same pid+port.
    static func parseListeners(_ output: String) -> [Listener] {
        var result: [Listener] = []
        var seen = Set<String>()
        var pid = 0
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]),
                      pid > 0
                else { continue }
                let key = "\(pid):\(port)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(Listener(pid: pid, command: command, port: port))
            default: break
            }
        }
        return result
    }

    /// Parse `lsof -a -d cwd -p <pids> -Fpn` field output into pid → cwd.
    static func parseCwds(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var pid = 0
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int(value) ?? 0
            case "n": if pid > 0 { result[pid] = value }
            default: break
            }
        }
        return result
    }

    /// Is `path` equal to `dir` or inside it? Compared on path boundaries, so
    /// `/a/bar` is not inside `/a/b`.
    static func isPath(_ path: String, under dir: String) -> Bool {
        path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// Attribute each listener to the project whose directories its cwd
    /// belongs to. A server counts for a project when its cwd sits inside one
    /// of the project's terminal directories — or when a terminal sits deeper
    /// inside the server's checkout (server at the repo root, terminal in a
    /// package), which is what `isProjectRoot` guards: without the marker
    /// check, a server started in `~/development` would claim every project.
    static func match(
        listeners: [Listener],
        cwds: [Int: String],
        projectDirs: [UUID: [String]],
        isProjectRoot: (String) -> Bool
    ) -> [UUID: [DevServer]] {
        var result: [UUID: [DevServer]] = [:]
        var rootCache: [String: Bool] = [:]
        for listener in listeners {
            guard listener.port < ephemeralPortFloor,
                  !ignoredPorts.contains(listener.port),
                  !ignoredCommands.contains(where: { listener.command.hasPrefix($0) }),
                  let cwd = cwds[listener.pid], cwd.count > 1
            else { continue }
            for (groupID, dirs) in projectDirs {
                let belongs = dirs.contains { dir in
                    if isPath(cwd, under: dir) { return true }
                    guard isPath(dir, under: cwd) else { return false }
                    if let cached = rootCache[cwd] { return cached }
                    let isRoot = isProjectRoot(cwd)
                    rootCache[cwd] = isRoot
                    return isRoot
                }
                guard belongs,
                      !(result[groupID] ?? []).contains(where: { $0.port == listener.port })
                else { continue }
                result[groupID, default: []].append(
                    DevServer(port: listener.port, processName: listener.command, directory: cwd))
            }
        }
        for key in result.keys { result[key]?.sort { $0.port < $1.port } }
        return result
    }

    /// Does this directory look like a checkout root? Enough evidence for the
    /// parent-direction match above; a plain collection folder has none of it.
    static func looksLikeProjectRoot(_ path: String) -> Bool {
        let markers = [".git", "package.json", "pnpm-workspace.yaml", "Cargo.toml", "Package.swift"]
        return markers.contains {
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0))
        }
    }

    /// Hosts that only name this machine — a link nobody can share.
    static let localHosts: Set<String> = [
        "localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]", "::",
    ]

    /// The URL a dev server announced for `port`, read off its terminal.
    ///
    /// The port comes from the OS (`lsof`), which knows it for certain but
    /// nothing else; the scheme and the host only exist in what the server
    /// printed. Vite serving `https://photo-frame-designer.myposter.de:8082`
    /// on port 8082 is the case that matters: guessing `http://localhost` there
    /// opens a page that does not answer.
    ///
    /// Preference, strongest first: the address the server labelled as its
    /// network address, then any non-local host, then a local one. Later lines
    /// win over earlier ones — a restarted server prints its banner again.
    static func bestURL(forPort port: Int, in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: "https?://[A-Za-z0-9._~%\\-\\[\\]]+:\(port)\\b[^\\s\"'<>]*")
        else { return nil }
        var best: (rank: Int, url: URL)?
        for line in text.split(whereSeparator: \.isNewline) {
            let isNetworkLine = line.range(of: "network", options: .caseInsensitive) != nil
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                // Trailing punctuation from prose ("… at http://x:3000.").
                let raw = String(text[matchRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}"))
                guard let url = URL(string: raw), let host = url.host else { continue }
                let isLocal = localHosts.contains(host.lowercased())
                let rank = isNetworkLine && !isLocal ? 3 : (!isLocal ? 2 : 1)
                // `>=` so a later line of equal rank replaces an earlier one.
                if best == nil || rank >= best!.rank { best = (rank, url) }
            }
        }
        return best?.url
    }

    /// The impure end: two `lsof` calls, then the pure match. Call off the
    /// main thread — each `lsof` costs ~100ms.
    static func scan(projectDirs: [UUID: [String]]) -> [UUID: [DevServer]] {
        guard !projectDirs.isEmpty else { return [:] }
        let listing = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        let listeners = parseListeners(listing)
        guard !listeners.isEmpty else { return [:] }
        let pids = Set(listeners.map(\.pid)).map(String.init).joined(separator: ",")
        let cwdListing = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids, "-Fpn"])
        return match(
            listeners: listeners,
            cwds: parseCwds(cwdListing),
            projectDirs: projectDirs,
            isProjectRoot: looksLikeProjectRoot)
    }

    private static func run(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

import AppKit

/// The outbound half of the socket: agents asking Planchette to do things,
/// instead of only reporting to it. Adapted from herdr's socket API, kept
/// deliberately narrow — the commands an agent needs to put a second agent to
/// work beside itself and collect the result.
///
/// One JSON object per connection, one JSON object back:
///
///     {"planchette_request": "session.list"}
///     → {"ok": true, "result": {"sessions": [...]}}
///
/// Requests are recognized by the `planchette_request` key, so hook events
/// (which carry `planchette_session`) keep flowing through untouched.
enum ControlAPI {
    /// Commands the API accepts. Anything else is an error, listed back to the
    /// caller — the binary is the authority on its own surface.
    enum Command: String, CaseIterable {
        case sessionList = "session.list"
        case sessionGet = "session.get"
        case sessionNew = "session.new"
        case sessionPrompt = "session.prompt"
        case sessionRead = "session.read"
        case sessionWait = "session.wait"
        case projectList = "project.list"
    }

    /// A parsed request: the command plus its raw arguments.
    struct Request {
        let command: Command
        let arguments: [String: Any]

        func string(_ key: String) -> String? { arguments[key] as? String }
        func int(_ key: String) -> Int? {
            arguments[key] as? Int ?? (arguments[key] as? NSNumber)?.intValue
        }
        func bool(_ key: String) -> Bool? { arguments[key] as? Bool }
        func strings(_ key: String) -> [String]? { arguments[key] as? [String] }
        func uuid(_ key: String) -> UUID? { string(key).flatMap(UUID.init(uuidString:)) }
    }

    /// Why a request could not be run. A plain message: the caller is a shell
    /// script, so the only useful thing to hand back is a sentence.
    struct Failure: Error, Equatable {
        let message: String
    }

    /// Pure: is this payload a control request, and is it one we know?
    /// Returns nil when the payload is not a request at all (a hook event).
    static func parse(_ payload: [String: Any]) -> Result<Request, Failure>? {
        guard let raw = payload["planchette_request"] as? String else { return nil }
        guard let command = Command(rawValue: raw) else {
            let known = Command.allCases.map(\.rawValue).sorted().joined(separator: ", ")
            return .failure(Failure(
                message: "unknown command \"\(raw)\". known commands: \(known)"))
        }
        var arguments = payload
        arguments.removeValue(forKey: "planchette_request")
        return .success(Request(command: command, arguments: arguments))
    }

    /// Pure: encode a response the CLI can read. Always valid JSON, always with
    /// an `ok` field, so a caller never has to guess.
    static func encode(ok: Bool, result: [String: Any]? = nil, error: String? = nil) -> Data {
        var payload: [String: Any] = ["ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        // Checked, not `try?`: JSONSerialization raises an ObjC *exception* for
        // values like NaN, which Swift cannot catch — it would take the socket
        // handler down instead of returning an error to the caller.
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            return Data(#"{"ok":false,"error":"response could not be encoded"}"#.utf8)
        }
        return data
    }

    /// How a terminal is described to an agent. Stable keys — an agent reads
    /// these instead of guessing from the UI.
    @MainActor
    static func describe(_ session: TerminalSession, in state: AppState) -> [String: Any] {
        var dict: [String: Any] = [
            "id": session.id.uuidString,
            "title": session.displayTitle,
            "path": session.currentDirectory,
            "state": session.state.rawValue,
            "agent": session.agentKind.rawValue,
            "seen": session.seen,
        ]
        if let task = session.currentTask { dict["task"] = task }
        if let message = session.lastMessage { dict["message"] = message }
        if let group = state.groups.first(where: { $0.id == session.groupID }) {
            dict["project"] = group.name
            dict["project_id"] = group.id.uuidString
        }
        return dict
    }

    // MARK: Dispatch

    /// Run a request. Returns the encoded response.
    @MainActor
    static func handle(_ request: Request, state: AppState) async -> Data {
        switch request.command {
        case .sessionList:
            let sessions = state.sessions.values
                .sorted { $0.displayTitle < $1.displayTitle }
                .map { describe($0, in: state) }
            return encode(ok: true, result: ["sessions": sessions])

        case .projectList:
            let projects = state.groups.map { group -> [String: Any] in
                [
                    "id": group.id.uuidString,
                    "name": group.name,
                    "favorite": group.favorite,
                    "sessions": group.sessionIDs.map(\.uuidString),
                    "worktree": group.worktreePath ?? "",
                ]
            }
            return encode(ok: true, result: ["projects": projects])

        case .sessionGet:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            return encode(ok: true, result: ["session": describe(session, in: state)])

        case .sessionNew:
            guard let directory = request.string("cwd") else {
                return encode(ok: false, error: "cwd is required")
            }
            // Default to the caller's own project, so "another terminal here"
            // does not scatter projects.
            let groupID: UUID
            if let explicit = request.uuid("project_id"),
               state.groups.contains(where: { $0.id == explicit }) {
                groupID = explicit
            } else if let caller = request.uuid("session"),
                      let session = state.sessions[caller] {
                groupID = session.groupID
            } else {
                groupID = state.addGroup(
                    name: (directory as NSString).lastPathComponent).id
            }
            let session = state.addSession(directory: directory, groupID: groupID)
            if request.bool("focus") == true { state.select(session: session) }
            return encode(ok: true, result: ["session": describe(session, in: state)])

        case .sessionPrompt:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            guard let text = request.string("text") else {
                return encode(ok: false, error: "text is required")
            }
            guard let view = TerminalRegistry.shared.existingView(session.id) else {
                return encode(ok: false, error: "session has no live terminal")
            }
            view.sendText(text)
            // Submit unless explicitly told not to, so the common case is one call.
            if request.bool("submit") != false { view.sendText("\r") }
            return encode(ok: true, result: ["session": describe(session, in: state)])

        case .sessionRead:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            guard let view = TerminalRegistry.shared.existingView(session.id) else {
                return encode(ok: false, error: "session has no live terminal")
            }
            let full = request.bool("scrollback") == true
                ? (view.readScrollback() ?? "")
                : (view.readViewport() ?? "")
            let lines = full.components(separatedBy: "\n")
            let wanted = request.int("lines") ?? 60
            let tail = lines.suffix(max(1, wanted)).joined(separator: "\n")
            return encode(ok: true, result: ["text": tail, "session": describe(session, in: state)])

        case .sessionWait:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            let wanted = Set(request.strings("until") ?? ["ready", "waiting", "error", "free"])
            let timeout = TimeInterval(request.int("timeout_ms") ?? 120_000) / 1000
            let result = await waitForState(
                session.id, until: wanted, timeout: timeout, state: state)
            switch result {
            case .some(let reached):
                return encode(
                    ok: true,
                    result: ["session": describe(reached, in: state), "timed_out": false])
            case .none:
                return encode(ok: false, error: "timed out waiting for \(wanted.sorted().joined(separator: "/"))")
            }
        }
    }

    /// A session by id, or the caller's own terminal when none is given.
    @MainActor
    private static func resolve(_ request: Request, state: AppState) -> TerminalSession? {
        if let id = request.uuid("id") { return state.sessions[id] }
        if let caller = request.uuid("session") { return state.sessions[caller] }
        return nil
    }

    /// Poll until the session's state is one of `until`. Polling (rather than a
    /// continuation registered in AppState) keeps the waiting entirely inside the
    /// API: no state-change plumbing to leak into the attention engine.
    @MainActor
    private static func waitForState(
        _ id: UUID, until: Set<String>, timeout: TimeInterval, state: AppState
    ) async -> TerminalSession? {
        let deadline = Date().addingTimeInterval(min(max(timeout, 1), 3600))
        while Date() < deadline {
            guard let session = state.sessions[id] else { return nil }
            if until.contains(session.state.rawValue) { return session }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }
}

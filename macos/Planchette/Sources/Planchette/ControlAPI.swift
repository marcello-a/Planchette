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
///
/// `notification.list` is the read side of the notifications panel: the same
/// sections, the same order, the same per-row facts, so a status bar, a Stream
/// Deck or another agent can show what the panel shows without scraping it.
enum ControlAPI {
    /// Commands the API accepts. Anything else is an error, listed back to the
    /// caller — the binary is the authority on its own surface.
    enum Command: String, CaseIterable {
        case sessionList = "session.list"
        case sessionGet = "session.get"
        case sessionNew = "session.new"
        case sessionFocus = "session.focus"
        case sessionPrompt = "session.prompt"
        case sessionRead = "session.read"
        case sessionWait = "session.wait"
        case sessionProgress = "session.progress"
        case projectList = "project.list"
        case notificationList = "notification.list"
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
        // A terminal that is `ready` may still be busy: a dev server, an agent.
        if let background = BackgroundTasks.summary(state.backgroundTasks[session.id] ?? []) {
            dict["background_tasks"] = background
        }
        if let progress = state.progress[session.id] {
            dict["progress"] = progress.describe(iso: iso)
        }
        if let group = state.groups.first(where: { $0.id == session.groupID }) {
            dict["project"] = group.name
            dict["project_id"] = group.id.uuidString
        }
        return dict
    }

    /// A terminal as the notifications panel shows it: everything on the row plus
    /// the project it sits under. Deliberately more than `describe` — a caller
    /// rendering its own notification list must not have to ask twice, or join
    /// three commands to fill one line.
    ///
    /// Raw values *and* the labels on screen: `state` is the stable key to branch
    /// on, `state_label` and `age` are the strings the panel prints, in the app's
    /// current language.
    @MainActor
    static func describeNotification(
        _ session: TerminalSession, in state: AppState
    ) -> [String: Any] {
        var dict = describe(session, in: state)
        let since = session.stateSince
        // The row's first line, verbatim — a caller drawing its own list gets the
        // same name the panel shows instead of re-deriving it from the branch.
        dict["headline"] = state.notificationHeadline(for: session)
        dict["state_label"] = session.state.label
        dict["needs_attention"] = session.state.needsAttention
        dict["unread"] = session.isUnread
        dict["state_since"] = iso.string(from: since)
        dict["age_seconds"] = Int(Date().timeIntervalSince(since))
        dict["age"] = WaitingTimeText.format(Date().timeIntervalSince(since))
        dict["short_path"] = session.shortPath
        dict["tags"] = session.tags
        dict["durable"] = session.durable
        dict["muted"] = state.isMuted(session)
        // The row's middle line — what the panel actually prints there.
        if let prompt = session.promptLine { dict["prompt"] = prompt }
        if let ticket = session.ticket { dict["ticket"] = ticket }
        if let branch = state.branches[session.id] { dict["branch"] = branch }
        if let summary = session.aiSummary { dict["ai_summary"] = summary }
        if let topic = session.aiTopic { dict["ai_topic"] = topic }
        if let until = state.snoozeEnd(for: session), until > Date() {
            dict["snoozed_until"] = iso.string(from: until)
        }
        if let group = state.group(of: session) {
            dict["project_favorite"] = group.favorite
            dict["project_active"] = group.active
            if let branch = state.sharedBranch(of: group) { dict["project_branch"] = branch }
        }
        return dict
    }

    /// The last `lines` lines of `text` (at least one), joined with "\n".
    ///
    /// Found by scanning back from the end for newlines instead of splitting the
    /// whole text: `session.read --scrollback` hands over a buffer of up to
    /// several megabytes, on the main actor, and splitting it into one string
    /// per line only to keep the last sixty was a long hitch for a short answer.
    /// The result is the same as `text.components(separatedBy: "\n").suffix(n)`
    /// joined — including the empty last line of a text that ends in a newline.
    static func tail(of text: String, lines: Int) -> String {
        let wanted = max(1, lines)
        let utf8 = text.utf8
        var index = utf8.endIndex
        var seen = 0
        while index > utf8.startIndex {
            index = utf8.index(before: index)
            // 0x0A never occurs inside a multi-byte UTF-8 sequence.
            if utf8[index] == 0x0A {
                seen += 1
                if seen == wanted { return String(text[utf8.index(after: index)...]) }
            }
        }
        return text
    }

    /// The most terminals the API will open. `session.new` starts a real process
    /// with a real PTY, so an agent stuck in a loop around it would otherwise
    /// fork until the machine objected. Far above anything a person arranges by
    /// hand; the user's own "new terminal" is not limited by this.
    static let maxTerminals = 200

    static func canOpenAnotherTerminal(open count: Int) -> Bool { count < maxTerminals }

    /// ISO 8601 with the offset, so a caller in another language and another
    /// timezone can parse a timestamp instead of a formatted date.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: Dispatch

    /// Run a request. Returns the encoded response.
    ///
    /// `clientAlive` says whether the caller is still on the other end of the
    /// connection. Only a request that waits for something consults it: a
    /// `session.wait` whose caller was killed is not worth finishing.
    @MainActor
    static func handle(
        _ request: Request, state: AppState,
        clientAlive: @escaping @Sendable () -> Bool = { true }
    ) async -> Data {
        switch request.command {
        case .sessionList:
            let sessions = state.sessions.values
                .sorted { $0.displayTitle < $1.displayTitle }
                .map { describe($0, in: state) }
            return encode(ok: true, result: ["sessions": sessions])

        case .projectList:
            let projects = state.groups.map { group -> [String: Any] in
                var dict: [String: Any] = [
                    "id": group.id.uuidString,
                    "name": group.name,
                    "favorite": group.favorite,
                    "active": group.active,
                    "sessions": group.sessionIDs.map(\.uuidString),
                ]
                // Absent rather than empty: a caller checks for the key.
                if let worktree = group.worktreePath { dict["worktree"] = worktree }
                return dict
            }
            return encode(ok: true, result: ["projects": projects])

        case .notificationList:
            // The panel's own sections, so this cannot drift from the UI —
            // including the window order: the panel lists the front window's
            // projects first, so the API passes that window along instead of
            // silently using persistence order.
            var sections = state.notificationSections(
                windowID: WindowRegistry.shared.keyWindowID() ?? state.windows.first?.id,
                unreadOnly: request.bool("unread_only") == true,
                activeOnly: request.bool("only_active") == true)
            if let projectID = request.uuid("project_id") {
                sections = sections.filter { $0.group.id == projectID }
            }
            var notifications = sections.flatMap { section in
                section.sessions.map { describeNotification($0, in: state) }
            }
            if let limit = request.int("limit"), limit >= 0 {
                notifications = Array(notifications.prefix(limit))
            }
            let counts: [String: Any] = [
                "unread": state.unreadCount,
                "waiting": state.waitingCount,
                "errors": state.errorCount,
                "unseen_ready": state.unseenReadyCount,
                "listed": notifications.count,
            ]
            return encode(
                ok: true, result: ["notifications": notifications, "counts": counts])

        case .sessionGet:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            return encode(ok: true, result: ["session": describe(session, in: state)])

        case .sessionNew:
            guard let directory = request.string("cwd") else {
                return encode(ok: false, error: "cwd is required")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return encode(ok: false, error: "cwd is not a directory: \(directory)")
            }
            guard canOpenAnotherTerminal(open: state.sessions.count) else {
                return encode(
                    ok: false,
                    error: "too many terminals are open (limit \(maxTerminals)); close some first")
            }
            // Default to the caller's own project, so "another terminal here"
            // does not scatter projects.
            let focus = request.bool("focus") == true
            let groupID: UUID
            if let explicit = request.uuid("project_id"),
               state.groups.contains(where: { $0.id == explicit }) {
                groupID = explicit
            } else if let caller = request.uuid("session"),
                      let session = state.sessions[caller] {
                groupID = session.groupID
            } else {
                // Without --focus the new project must not become the visible
                // one — the docs promise "leave the user where they are", and
                // switching the sidebar selection breaks that promise as much
                // as switching tabs does.
                groupID = state.addGroup(
                    name: (directory as NSString).lastPathComponent,
                    select: focus).id
            }
            // Same contract for the tab: creating a terminal in the project the
            // user is looking at used to swap their active tab out from under
            // them. `activate` only when the caller asked for focus.
            let session = state.addSession(
                directory: directory, groupID: groupID, activate: focus)
            // Start the terminal now. SwiftUI only builds a surface for what it
            // renders, so a session created into a background project would have
            // no PTY — and the very next `session.prompt` would fail.
            guard liveView(for: session, state: state) != nil else {
                // The caller is told no terminal exists, so none may be left behind
                // (an empty tab that a retry would start later, unasked).
                state.closeSession(session.id)
                return encode(
                    ok: false,
                    error: "terminal could not be started (is a display active?)")
            }
            if focus { state.select(session: session) }
            return encode(ok: true, result: ["session": describe(session, in: state)])

        case .sessionFocus:
            // `session.new --focus` could already do this, but only for a
            // terminal it had just created — there was no way to say "show me
            // that one". A status display outside the app (a dashboard, a strip,
            // an agent reporting on its siblings) can list what needs attention
            // and then take you to it, instead of naming a terminal you have to
            // go and find yourself.
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            // focusSession, not select: the docs promise "raises its window" —
            // the caller is outside the app (a dashboard, a Stream Deck), so
            // without activating the app the selection changed invisibly in
            // the background and nobody was taken anywhere.
            state.focusSession(session.id)
            return encode(ok: true, result: ["session": describe(session, in: state)])

        case .sessionPrompt:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            guard let text = request.string("text") else {
                return encode(ok: false, error: "text is required")
            }
            // Typing into a turn in flight interrupts it — and whatever the agent
            // was doing is the user's work, not the caller's to discard.
            if session.state == .running, request.bool("force") != true {
                return encode(
                    ok: false,
                    error: "session is running; wait for it or pass force")
            }
            guard let view = liveView(for: session, state: state) else {
                return encode(ok: false, error: "session has no live terminal")
            }
            let submit = request.bool("submit") != false
            await deliverPrompt(text, submit: submit, to: view, session: session.id)
            return encode(ok: true, result: ["session": describe(session, in: state)])

        case .sessionRead:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            guard let view = liveView(for: session, state: state) else {
                return encode(ok: false, error: "session has no live terminal")
            }
            let full = request.bool("scrollback") == true
                ? (view.readScrollback() ?? "")
                : (view.readViewport() ?? "")
            let tail = Self.tail(of: full, lines: request.int("lines") ?? 60)
            return encode(ok: true, result: ["text": tail, "session": describe(session, in: state)])

        case .sessionProgress:
            // A pipeline reporting where it stands — display only, so it may
            // write while a turn runs (that is when it has something to say).
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            if request.bool("clear") == true {
                state.setProgress(session.id, nil)
                return encode(ok: true, result: ["session": describe(session, in: state)])
            }
            switch TerminalProgress.resolve(
                steps: request.strings("steps"), total: request.int("total"),
                step: request.int("step"), label: request.string("label"),
                current: state.progress[session.id], now: Date()
            ) {
            case .success(let progress):
                state.setProgress(session.id, progress)
                return encode(ok: true, result: ["session": describe(session, in: state)])
            case .failure(let failure):
                return encode(ok: false, error: failure.message)
            }

        case .sessionWait:
            guard let session = resolve(request, state: state) else {
                return encode(ok: false, error: "no such session")
            }
            let wanted = Set(request.strings("until") ?? ["ready", "waiting", "error", "free"])
            let timeout = TimeInterval(request.int("timeout_ms") ?? 120_000) / 1000
            let result = await waitForState(
                session.id, until: wanted, timeout: timeout, state: state,
                clientAlive: clientAlive)
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

    /// The wait between the pasted text and the Enter that submits it, so a TUI has
    /// taken the paste into its input before Enter arrives. Measured against Claude
    /// Code 2.1.299: 0, 30 and 100 ms all submitted 30 prompts out of 30, so this is a
    /// margin for slower programs and a loaded machine, not a requirement.
    static let submitDelay: TimeInterval = 0.1

    /// Prompts to one terminal run one after the other. Text and Enter are two steps,
    /// and two prompts must not interleave (text, text, Enter, Enter would submit
    /// them as one message).
    @MainActor
    private static let prompts = KeyedSerializer<UUID>()

    /// Type `text` into the terminal and, unless told not to, submit it.
    ///
    /// The text goes in as a paste (that is what `ghostty_surface_text` is), framed in
    /// bracketed-paste markers when the program asked for that — zsh, fish and Claude
    /// Code do. A carriage return *inside* the frame is a newline in the text, not
    /// Enter, so the old `text + "\r"` in one write typed the prompt and left it
    /// waiting in the input box. Enter is therefore a key press after the paste.
    @MainActor
    private static func deliverPrompt(
        _ text: String, submit: Bool, to view: GhosttySurfaceNSView, session: UUID
    ) async {
        await prompts.run(session) {
            view.sendText(text)
            guard submit else { return }
            try? await Task.sleep(nanoseconds: UInt64(submitDelay * 1_000_000_000))
            view.pressReturn()
        }
    }

    /// The live terminal for a session, creating it if SwiftUI has not rendered
    /// that session yet. The registry owns surfaces independently of the view
    /// tree, so this is the same object SwiftUI will pick up when it does.
    ///
    /// Nil when there is no terminal to talk to — also when the view exists but
    /// libghostty could not build its surface yet (no display is active). That one
    /// gets another try right now; typing into it, or reading it, would otherwise
    /// be silently dropped while the API said "ok".
    @MainActor
    private static func liveView(
        for session: TerminalSession, state: AppState
    ) -> GhosttySurfaceNSView? {
        guard let view = TerminalRegistry.shared.existingView(session.id)
            ?? TerminalRegistry.shared.view(for: session, appState: state)
        else { return nil }
        return view.createSurface() ? view : nil
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
        _ id: UUID, until: Set<String>, timeout: TimeInterval, state: AppState,
        clientAlive: @Sendable () -> Bool
    ) async -> TerminalSession? {
        let deadline = Date().addingTimeInterval(min(max(timeout, 1), 3600))
        while Date() < deadline {
            guard let session = state.sessions[id] else { return nil }
            if until.contains(session.state.rawValue) { return session }
            // Nobody is left to read the answer: stop holding a task, and the
            // descriptor, for the rest of the timeout.
            guard clientAlive() else { return nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }
}

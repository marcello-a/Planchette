import Foundation

/// One piece of work Claude Code runs in the background of a terminal: a shell
/// it started with `run_in_background`, or an agent it launched without waiting
/// for the answer. The sidebar shows how many a terminal has, because a
/// terminal that looks idle may still be busy — a dev server, a long build, a
/// review agent — and the turn's end says nothing about it.
struct BackgroundTask: Equatable, Sendable {
    enum Kind: Sendable { case shell, agent }

    let id: String
    let kind: Kind
    /// What Claude called it, on one line. Display only — never acted on.
    let title: String
}

/// What one hook event says about the background tasks of a terminal.
enum BackgroundTaskSignal: Equatable, Sendable {
    /// The whole list, as Claude itself counts it. The `Stop` hook carries it:
    /// the one source that is complete and needs no guessing.
    case snapshot([BackgroundTask])
    /// A tool call that launched one. Ahead of the `Stop`, so a dev server
    /// started in the middle of a long turn shows at once.
    case started(BackgroundTask)
    /// A `<task-notification>` said these are over.
    case finished([String])
    /// A Claude process began or ended in this terminal, and took its tasks along.
    case reset
}

/// Reading Claude Code's background tasks off its hooks, and what to show.
///
/// What the hooks say was observed by running Claude Code 2.1.299 against a
/// local stand-in for the API (`scripts/perf/`), not taken from a manual:
///
/// - `Stop` carries `background_tasks`: `{id, type, status, description, …}`
///   with `type` `shell` or `subagent`. A task leaves the list when it ends.
///   `SubagentStop` carries it too, but still lists the agent that is stopping,
///   so only `Stop` is trusted.
/// - A task that ends while Claude waits at the prompt arrives as a
///   `UserPromptSubmit` whose prompt is a `<task-notification>` (`<task-id>`,
///   `<status>`) — the notification starts a turn, so it is a prompt to the
///   hook but not one the user wrote.
/// - The tasks belong to the Claude *process*, not to the conversation: after
///   `/clear` (a new session id) the same shell is still listed.
///
/// An older Claude Code has no `background_tasks`; the badge then never shows,
/// which is the honest answer to "do I know?".
enum BackgroundTasks {
    /// Statuses of a task that is over. Anything else (`running`, `pending`)
    /// counts as live.
    static let overStatuses: Set<String> = [
        "completed", "failed", "killed", "stopped", "cancelled", "canceled", "error", "timeout",
    ]

    // MARK: Reading a hook event

    static func signal(from event: [String: Any]) -> BackgroundTaskSignal? {
        switch event["hook_event_name"] as? String {
        case "Stop":
            guard let listed = event["background_tasks"] as? [[String: Any]] else { return nil }
            return .snapshot(listed.compactMap(task(fromListed:)))
        case "PostToolUse":
            return launched(by: event).map(BackgroundTaskSignal.started)
        case "UserPromptSubmit":
            let ids = (event["prompt"] as? String).map(finishedIDs(inNotification:)) ?? []
            return ids.isEmpty ? nil : .finished(ids)
        case "SessionStart":
            // `startup` and `resume` begin a Claude process; `clear`, `compact`
            // and `fork` continue the one that is running.
            let source = event["source"] as? String
            return source == "startup" || source == "resume" ? .reset : nil
        case "SessionEnd":
            // A `/clear` or an in-process `/resume` ends the session, not the
            // process, so the tasks go on.
            let reason = event["reason"] as? String
            return reason == "clear" || reason == "resume" ? nil : .reset
        default:
            return nil
        }
    }

    /// The list after a signal.
    static func apply(_ signal: BackgroundTaskSignal, to tasks: [BackgroundTask]) -> [BackgroundTask] {
        switch signal {
        case .snapshot(let all): all
        case .started(let task): tasks.filter { $0.id != task.id } + [task]
        case .finished(let ids): tasks.filter { !ids.contains($0.id) }
        case .reset: []
        }
    }

    private static func task(fromListed entry: [String: Any]) -> BackgroundTask? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        if let status = entry["status"] as? String, overStatuses.contains(status.lowercased()) {
            return nil
        }
        let type = (entry["type"] as? String)?.lowercased() ?? ""
        return BackgroundTask(
            id: id,
            kind: type.contains("agent") ? .agent : .shell,
            title: title(entry["description"], entry["command"], entry["agent_type"]))
    }

    /// The task a finished tool call started, if it started one: a `Bash` call
    /// with `run_in_background` answers with the id of its shell, an agent
    /// launched without waiting answers `isAsync` with its agent id.
    private static func launched(by event: [String: Any]) -> BackgroundTask? {
        let input = event["tool_input"] as? [String: Any] ?? [:]
        let response = event["tool_response"] as? [String: Any] ?? [:]
        if event["tool_name"] as? String == "Bash",
           let id = response["backgroundTaskId"] as? String, !id.isEmpty {
            return BackgroundTask(id: id, kind: .shell,
                                  title: title(input["description"], input["command"]))
        }
        if response["isAsync"] as? Bool == true,
           let id = response["agentId"] as? String, !id.isEmpty {
            return BackgroundTask(id: id, kind: .agent,
                                  title: title(response["description"], input["description"]))
        }
        return nil
    }

    /// The first of these that says something, collapsed to one short line.
    private static func title(_ candidates: Any?...) -> String {
        for candidate in candidates {
            if let text = candidate as? String, let line = Titles.taskLabel(text, max: 60) {
                return line
            }
        }
        return ""
    }

    // MARK: Notifications

    /// Whether a submitted prompt is Claude Code's own `<task-notification>`
    /// rather than something the user typed. It must not become the terminal's
    /// task line.
    static func isNotification(_ prompt: String) -> Bool {
        prompt.drop(while: \.isWhitespace).hasPrefix("<task-notification>")
    }

    /// The tasks a notification reports as over. A notification can also be
    /// news about a task that goes on (a monitor's output); it names no ending
    /// status then, and nothing is removed.
    static func finishedIDs(inNotification prompt: String) -> [String] {
        guard isNotification(prompt) else { return [] }
        var ids: [String] = []
        var rest = prompt[...]
        while let open = rest.range(of: "<task-notification>") {
            let afterOpen = rest[open.upperBound...]
            let block = afterOpen.range(of: "</task-notification>")
                .map { afterOpen[..<$0.lowerBound] } ?? afterOpen
            if let id = value(of: "task-id", in: block),
               let status = value(of: "status", in: block),
               overStatuses.contains(status.lowercased()) {
                ids.append(id)
            }
            rest = afterOpen[block.endIndex...]
        }
        return ids
    }

    private static func value(of tag: String, in text: Substring) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let value = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Showing

    static func count(_ tasks: [BackgroundTask], of kind: BackgroundTask.Kind) -> Int {
        tasks.filter { $0.kind == kind }.count
    }

    /// The control API's view of a terminal's tasks: counts by kind, `nil` when
    /// there are none, so the key is absent for a terminal that runs nothing.
    static func summary(_ tasks: [BackgroundTask]) -> [String: Int]? {
        guard !tasks.isEmpty else { return nil }
        return ["shells": count(tasks, of: .shell), "agents": count(tasks, of: .agent)]
    }

    /// Rows listed in the tooltip before the rest is summed up.
    static let tooltipRows = 6

    /// What the badge says on hover: what runs, one line per task.
    static func tooltip(for tasks: [BackgroundTask]) -> String {
        var lines = [L10n.t(.backgroundTasksTooltip)]
        for task in tasks.prefix(tooltipRows) {
            let kind = L10n.t(task.kind == .agent ? .backgroundAgent : .backgroundShell)
            lines.append(task.title.isEmpty ? kind : "\(kind): \(task.title)")
        }
        if tasks.count > tooltipRows {
            lines.append(L10n.t(.backgroundTasksMore, tasks.count - tooltipRows))
        }
        return lines.joined(separator: "\n")
    }
}

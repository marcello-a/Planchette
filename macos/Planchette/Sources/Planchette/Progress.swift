import Foundation

/// Where a long piece of work stands, as the work itself reports it: step 7 of 13,
/// "Verify", plus one line on what happens in it. Posted by a script or an agent
/// in the terminal (`session.progress`, `planchette session progress`).
///
/// The hooks say *whether* a terminal needs you; they cannot say how far a
/// pipeline of agents has come — a skill that plans, implements, reviews and
/// waits for CI is `running` for an hour. Progress fills that gap and nothing
/// else: it never changes the attention state, which stays the hooks' call.
///
/// Never persisted, like `backgroundTasks`: after a restart the work reports
/// again on its next step, and a stale step is worse than none.
struct TerminalProgress: Equatable {
    /// Step names, when the caller has them. Empty when only a count is known.
    var steps: [String]
    var total: Int
    /// 1-based: step 1 of `total` is the first.
    var step: Int
    var label: String?
    /// When the step or the label last changed — a repeat of the same report
    /// does not move it (equal writes stay no-ops).
    var since: Date

    static let maxSteps = 32
    static let maxStepName = 24
    static let maxLabel = 200

    /// The name of the current step, when names were given.
    var stepName: String? { steps.indices.contains(step - 1) ? steps[step - 1] : nil }

    /// Pure: the progress a request asks for, given what the terminal shows now.
    /// `steps` or `total` may be left out to keep the current sequence, and
    /// `step` to only change the label.
    static func resolve(
        steps rawSteps: [String]?, total rawTotal: Int?, step rawStep: Int?,
        label rawLabel: String?, current: TerminalProgress?, now: Date
    ) -> Result<TerminalProgress, ControlAPI.Failure> {
        var steps = current?.steps ?? []
        var total = current?.total
        if let rawSteps {
            let names = rawSteps.map { clean($0, limit: maxStepName) }
            guard !names.isEmpty, names.count <= maxSteps else {
                return .failure(.init(message: "steps must hold 1 to \(maxSteps) names"))
            }
            guard names.allSatisfy({ !$0.isEmpty }) else {
                return .failure(.init(message: "a step name is empty"))
            }
            if let rawTotal, rawTotal != names.count {
                return .failure(.init(message: "total (\(rawTotal)) does not match steps (\(names.count))"))
            }
            steps = names
            total = names.count
        } else if let rawTotal {
            guard (1...maxSteps).contains(rawTotal) else {
                return .failure(.init(message: "total must be 1 to \(maxSteps)"))
            }
            // A new count without names drops names that no longer fit it.
            if rawTotal != steps.count { steps = [] }
            total = rawTotal
        }
        guard let total else {
            return .failure(.init(message: "steps or total is required for the first report"))
        }
        guard let step = rawStep ?? current?.step else {
            return .failure(.init(message: "step is required for the first report"))
        }
        guard (1...total).contains(step) else {
            return .failure(.init(message: "step must be 1 to \(total)"))
        }
        let label: String?
        if let rawLabel {
            let cleaned = clean(rawLabel, limit: maxLabel)
            label = cleaned.isEmpty ? nil : cleaned
        } else {
            label = current?.label
        }
        var next = TerminalProgress(steps: steps, total: total, step: step, label: label, since: now)
        if let current, current.sameReport(as: next) { next.since = current.since }
        return .success(next)
    }

    /// Equal apart from when it was reported.
    func sameReport(as other: TerminalProgress) -> Bool {
        steps == other.steps && total == other.total && step == other.step && label == other.label
    }

    /// The dictionary `session.get` and friends report under `progress`.
    func describe(iso: ISO8601DateFormatter) -> [String: Any] {
        var dict: [String: Any] = ["step": step, "total": total, "since": iso.string(from: since)]
        if !steps.isEmpty { dict["steps"] = steps }
        if let stepName { dict["step_name"] = stepName }
        if let label { dict["label"] = label }
        return dict
    }

    /// One line, whitespace collapsed, cut at `limit` characters. The text comes
    /// from whatever runs in the terminal and is drawn into a one-line row.
    private static func clean(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }
}

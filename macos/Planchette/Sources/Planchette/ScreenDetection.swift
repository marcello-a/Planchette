import Foundation

/// What the *screen* says an agent is doing — a fallback signal, never the
/// primary one. Hooks tell us what an agent decided; the screen only shows what
/// it drew. See `AttentionState.arbitrate` for who wins.
enum ScreenState: String, Codable {
    case idle      // at its prompt, nothing pending
    case working   // a turn is in flight
    case blocked   // a question or permission prompt is on screen
    case unknown   // recognized chrome, but nothing conclusive
}

/// One pattern rule over a region of the terminal tail. Rules are data, not
/// code: agent TUIs change weekly, and a wrong pattern must be fixable with a
/// JSON edit instead of a release. Modelled on herdr's detection manifests.
struct ScreenRule: Codable, Equatable {
    let id: String
    let state: ScreenState
    /// Higher wins. The first match in priority order decides.
    let priority: Int
    /// How many non-empty lines from the bottom the rule may look at.
    var tailLines: Int = 6
    /// Every string must appear (case-insensitive) in the region.
    var contains: [String] = []
    /// At least one group must have all of its strings present.
    var any: [[String]] = []
    /// None of these may appear.
    var none: [String] = []
    /// At least one line must match one of these regexes.
    var lineRegex: [String] = []
    /// A question/permission UI is visibly on screen. This is the one signal
    /// strong enough to override a hook that says otherwise — a hook can miss a
    /// prompt, the screen cannot.
    var visibleBlocker: Bool = false
    /// The screen is showing history (a transcript viewer, a pager), so nothing
    /// on it describes the live state. Suppresses the whole reading.
    var skipStateUpdate: Bool = false
}

/// The verdict for one screen reading.
struct ScreenDetection: Equatable {
    let state: ScreenState
    let ruleID: String
    var visibleBlocker: Bool = false
    var skipStateUpdate: Bool = false
}

/// Rules per agent, versioned so an override file can be recognized (and
/// rejected) across engine changes.
struct ScreenRuleSet: Codable {
    /// Bumped when the *engine* changes in a way rules depend on.
    static let engineVersion = 1

    var version: Int
    var engine: Int
    /// Keyed by `AgentKind.rawValue`.
    var agents: [String: [ScreenRule]]

    func rules(for kind: AgentKind) -> [ScreenRule] {
        agents[kind.rawValue] ?? []
    }
}

enum ScreenDetector {
    /// Match the tail of a terminal against an agent's rules.
    /// Pure: the caller supplies the lines, so this is fully unit-testable.
    static func detect(lines: [String], rules: [ScreenRule]) -> ScreenDetection? {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for rule in rules.sorted(by: { $0.priority > $1.priority }) {
            let region = Array(nonEmpty.suffix(rule.tailLines))
            guard !region.isEmpty else { continue }
            let haystack = region.joined(separator: "\n").lowercased()

            if !rule.contains.allSatisfy({ haystack.contains($0.lowercased()) }) { continue }
            if rule.none.contains(where: { haystack.contains($0.lowercased()) }) { continue }
            if !rule.any.isEmpty {
                let groupMatched = rule.any.contains { group in
                    group.allSatisfy { haystack.contains($0.lowercased()) }
                }
                if !groupMatched { continue }
            }
            if !rule.lineRegex.isEmpty {
                let matched = rule.lineRegex.contains { pattern in
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                    return region.contains { line in
                        let range = NSRange(line.startIndex..<line.endIndex, in: line)
                        return regex.firstMatch(in: line, range: range) != nil
                    }
                }
                if !matched { continue }
            }
            return ScreenDetection(
                state: rule.state, ruleID: rule.id,
                visibleBlocker: rule.visibleBlocker,
                skipStateUpdate: rule.skipStateUpdate)
        }
        return nil
    }

    /// Where a user-supplied ruleset overrides the built-in one. Editing this
    /// file is the supported way to fix a pattern without waiting for a release.
    @MainActor
    static var overrideURL: URL {
        AppState.stateURL.deletingLastPathComponent()
            .appendingPathComponent("screen-rules.json")
    }

    /// The active ruleset: the override file when it parses and matches this
    /// engine, otherwise the built-in defaults.
    @MainActor
    static func loadRuleSet() -> ScreenRuleSet {
        guard let data = try? Data(contentsOf: overrideURL) else { return builtIn }
        guard let set = try? JSONDecoder().decode(ScreenRuleSet.self, from: data) else {
            NSLog("screen-rules.json unparseable — using built-in rules")
            return builtIn
        }
        guard set.engine == ScreenRuleSet.engineVersion else {
            NSLog("screen-rules.json targets engine \(set.engine), we are \(ScreenRuleSet.engineVersion) — using built-in rules")
            return builtIn
        }
        return set
    }

    /// Built-in rules.
    ///
    /// **Claude Code** needs exactly one thing from the screen: the visible
    /// blocker. Its hooks report every transition, so working/idle come from
    /// there — but a hook can miss a permission prompt, and then only the screen
    /// knows. The markers below are the literal strings Claude Code renders
    /// (verified against the 2.1.x bundle), not guesses.
    ///
    /// **Codex** has no rules yet on purpose: its integration only claims the
    /// session, so its lifecycle *should* come from here — but the patterns must
    /// be verified against a real Codex install before they can be trusted, and
    /// a wrong pattern is worse than none (it would move the indicator on
    /// unrelated output). Add them to `screen-rules.json` and they take effect
    /// without a release.
    static let builtIn = ScreenRuleSet(
        version: 1,
        engine: ScreenRuleSet.engineVersion,
        agents: [
            AgentKind.claude.rawValue: [
                // A pager/transcript view shows history: the screen says nothing
                // about the live state.
                ScreenRule(
                    id: "claude_transcript_viewer", state: .unknown, priority: 1000,
                    tailLines: 4, contains: ["showing detailed transcript"],
                    skipStateUpdate: true),
                // Permission / confirmation prompt.
                ScreenRule(
                    id: "claude_permission_prompt", state: .blocked, priority: 900,
                    tailLines: 12,
                    any: [
                        ["do you want to proceed"],
                        ["do you want to allow"],
                        ["do you want to continue"],
                        ["do you want to use this"],
                        ["no, and tell claude"],
                    ],
                    visibleBlocker: true),
                // A selection list waiting on a keypress.
                ScreenRule(
                    id: "claude_selection_prompt", state: .blocked, priority: 880,
                    tailLines: 8, contains: ["esc to cancel"],
                    any: [["enter to select"], ["to navigate"]],
                    visibleBlocker: true),
                // The idle prompt footer, with no prompt open.
                ScreenRule(
                    id: "claude_idle_footer", state: .idle, priority: 700,
                    tailLines: 6, contains: ["? for shortcuts"],
                    none: ["esc to cancel", "do you want to"]),
            ],
            AgentKind.codex.rawValue: [],
        ])
}

extension AttentionState {
    /// Reconcile a screen reading with what the hooks already told us.
    ///
    /// - `hookAuthority` is true when a full-lifecycle agent (Claude Code) has a
    ///   live session here. Then hooks own the indicator and the screen may only
    ///   escalate to `waiting` on a visible blocker — never invent `running`,
    ///   never resolve a state the hooks are managing.
    /// - Without hook authority (no integration, an agent that only claims its
    ///   session, a plain shell running an agent we don't hook) the screen is
    ///   all we have, so it drives every state.
    ///
    /// Returns nil to keep the current state.
    static func fromScreen(
        _ screen: ScreenDetection?,
        agent: AgentKind,
        hookAuthority: Bool,
        current: AttentionState
    ) -> AttentionState? {
        guard let screen, !screen.skipStateUpdate else { return nil }

        if hookAuthority {
            // The one case the screen knows better: something is visibly waiting
            // on the human while the hooks think otherwise.
            guard screen.visibleBlocker, !current.needsAttention else { return nil }
            return .waiting
        }

        switch screen.state {
        case .working:
            return current == .running ? nil : .running
        case .blocked:
            return current == .waiting ? nil : .waiting
        case .idle:
            // A turn that was in flight and is now at the prompt produced
            // something to look at; an already-quiet terminal stays as it is.
            return (current == .running || current == .waiting) ? .ready : nil
        case .unknown:
            return nil
        }
    }
}

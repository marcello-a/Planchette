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
    /// The user aborted the turn (Esc) and the agent is back at its prompt.
    /// No hook fires for that — Claude Code's `Stop` skips user interrupts — so
    /// without this a hooked terminal would show `running` until the next turn.
    var interrupted: Bool = false
    /// The agent sits at an idle, open prompt — nothing is running. Under hook
    /// authority that frees a terminal the hooks still call `running`: a turn can
    /// end without a hook (Esc or Ctrl+C before anything was printed puts the
    /// prompt text back into the input and prints no "Interrupted" line; a `Stop`
    /// can be lost). Never `waiting`: a question is a dialog, not an idle prompt.
    var idlePrompt: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, state, priority, tailLines, contains, any, none, lineRegex
        case visibleBlocker, skipStateUpdate, interrupted, idlePrompt
    }

    init(id: String, state: ScreenState, priority: Int, tailLines: Int = 6,
         contains: [String] = [], any: [[String]] = [], none: [String] = [],
         lineRegex: [String] = [], visibleBlocker: Bool = false,
         skipStateUpdate: Bool = false, interrupted: Bool = false, idlePrompt: Bool = false) {
        self.id = id; self.state = state; self.priority = priority
        self.tailLines = tailLines; self.contains = contains; self.any = any
        self.none = none; self.lineRegex = lineRegex
        self.visibleBlocker = visibleBlocker; self.skipStateUpdate = skipStateUpdate
        self.interrupted = interrupted; self.idlePrompt = idlePrompt
    }

    // Hand-written so the in-line defaults apply during decode. Synthesized
    // Decodable ignores them and throws on any missing key, which would make an
    // override screen-rules.json that omits an optional field (the documented,
    // supported way to fix a pattern) silently reject the WHOLE file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(ScreenState.self, forKey: .state)
        priority = try c.decode(Int.self, forKey: .priority)
        tailLines = try c.decodeIfPresent(Int.self, forKey: .tailLines) ?? 6
        contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
        any = try c.decodeIfPresent([[String]].self, forKey: .any) ?? []
        none = try c.decodeIfPresent([String].self, forKey: .none) ?? []
        lineRegex = try c.decodeIfPresent([String].self, forKey: .lineRegex) ?? []
        visibleBlocker = try c.decodeIfPresent(Bool.self, forKey: .visibleBlocker) ?? false
        skipStateUpdate = try c.decodeIfPresent(Bool.self, forKey: .skipStateUpdate) ?? false
        interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        idlePrompt = try c.decodeIfPresent(Bool.self, forKey: .idlePrompt) ?? false
    }
}

/// The verdict for one screen reading.
struct ScreenDetection: Equatable {
    let state: ScreenState
    let ruleID: String
    var visibleBlocker: Bool = false
    var skipStateUpdate: Bool = false
    var interrupted: Bool = false
    var idlePrompt: Bool = false
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
            // One line of single spaces: in a narrow pane "What should Claude do
            // instead?" wraps over two lines, and a phrase that wraps must still
            // be the phrase (a marker that fails to match leaves a terminal stuck).
            let haystack = region.joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()

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
                    guard let regex = compiled(pattern) else { return false }
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
                skipStateUpdate: rule.skipStateUpdate,
                interrupted: rule.interrupted,
                idlePrompt: rule.idlePrompt)
        }
        return nil
    }

    /// Regexes compiled once. Detection runs every 1.5s per terminal, and
    /// NSRegularExpression compilation is the expensive part — an override file
    /// full of patterns would otherwise recompile all of them on every tick.
    private static let regexCache = RegexCache()

    private final class RegexCache: @unchecked Sendable {
        private var cache: [String: NSRegularExpression?] = [:]
        private let lock = NSLock()

        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = cache[pattern] { return cached }
            let compiled = try? NSRegularExpression(pattern: pattern)
            cache[pattern] = compiled
            return compiled
        }
    }

    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        regexCache.regex(pattern)
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
        return validated(data) ?? builtIn
    }

    /// Pure: accept a ruleset only if it parses, targets this engine, and has at
    /// least one rule. Returns nil for anything else — a bad file must degrade to
    /// "keep the rules we have", never to "stop detecting".
    static func validated(_ data: Data) -> ScreenRuleSet? {
        guard let set = try? JSONDecoder().decode(ScreenRuleSet.self, from: data) else {
            NSLog("screen rules: unparseable, keeping current rules")
            return nil
        }
        guard set.engine == ScreenRuleSet.engineVersion else {
            NSLog("screen rules: target engine \(set.engine), we are \(ScreenRuleSet.engineVersion) — ignored")
            return nil
        }
        guard set.agents.values.contains(where: { !$0.isEmpty }) else {
            NSLog("screen rules: no rules in file, ignored")
            return nil
        }
        return set
    }

    /// Pure: should `candidate` replace `current`? Only a newer version for the
    /// same engine — so a re-download, or an older asset on a rolled-back
    /// release, is a no-op rather than a downgrade.
    static func isNewer(_ candidate: ScreenRuleSet, than current: ScreenRuleSet) -> Bool {
        candidate.engine == current.engine && candidate.version > current.version
    }

    /// mtime of the override file, or nil when there is none. The detection poll
    /// compares this to decide whether to re-read — one stat per tick, which is
    /// what makes an edit take effect without a restart.
    @MainActor
    static func overrideModified() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: overrideURL.path)[.modificationDate] as? Date
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
        // 2: claude_interrupted — a newer version, so installs holding the
        // fetched v1 file take the release asset that carries it.
        // 3: claude_idle_footer reads every permission mode's footer and frees a
        // turn the hooks never closed (an abort before the first output).
        // 4: claude_working reads the footer of a turn in flight, which is how a
        // question that was answered is noticed (no hook says so).
        version: 4,
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
                // A turn aborted with Esc: Claude Code prints "Interrupted ·
                // What should Claude do instead?" and returns to its prompt,
                // without a hook. The spinner's "esc to interrupt" means a new
                // turn already runs below a stale marker.
                // "What should Claude do" and no further: a narrow pane clips the
                // line (it does not wrap it), and the question mark is not needed
                // to know whose line it is.
                ScreenRule(
                    id: "claude_interrupted", state: .idle, priority: 800,
                    tailLines: 10, contains: ["what should claude do"],
                    none: ["esc to interrupt", "enter to interrupt", "esc to cancel",
                           "do you want to"],
                    interrupted: true),
                // The idle prompt: the footer under an open input box, nothing
                // running. "esc to interrupt" is what the footer says while a
                // turn is live, so its absence is the evidence. The label differs
                // per permission mode ("manual mode on", "auto mode on (shift+tab
                // to cycle)", "accept edits on", …), and the empty input adds
                // "? for shortcuts" — which an input with text in it (a prompt put
                // back after an abort) does not show, so that alone is not enough.
                // Verified against Claude Code 2.1.300.
                ScreenRule(
                    id: "claude_idle_footer", state: .idle, priority: 700,
                    tailLines: 6,
                    any: [
                        ["? for shortcuts"],
                        ["mode on"],
                        ["shift+tab to cycle"],
                        ["accept edits on"],
                        ["bypass permissions on"],
                    ],
                    none: ["esc to cancel", "do you want to", "esc to interrupt",
                           "enter to interrupt"],
                    idlePrompt: true),
                // A turn in flight: the footer says "esc to interrupt" for as long as
                // Claude works — a tool that takes a minute, an MCP call, included. A
                // dialog never does (its footer is "Esc to cancel · Tab to amend"), so
                // the marker with no question on the screen is what an ANSWERED
                // question looks like: granting a permission fires no hook of its own,
                // and a terminal that raised "waiting" stayed blue through the whole
                // call. Verified against Claude Code 2.1.300, Bash and MCP.
                ScreenRule(
                    id: "claude_working", state: .working, priority: 600,
                    tailLines: 4,
                    any: [["esc to interrupt"], ["enter to interrupt"]],
                    none: ["esc to cancel", "do you want to", "no, and tell claude",
                           "enter to select", "to navigate", "what should claude do"]),
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
    /// Whether the screen rules are worth applying to this terminal at all.
    ///
    /// Claude's patterns describe Claude's screen. Where no Claude is live — a
    /// plain shell in a terminal Claude once ran in, which keeps its `claude`
    /// claim for good — they read whatever any program prints, and "Do you want
    /// to continue? (y/n)" from `apt` or `brew` raised a question that the
    /// finished command left on the screen, over and over, on every poll. So: a
    /// live agent, or a durable terminal, whose Claude may have outlived a restart
    /// and has not sent a hook yet. Nothing else.
    static func screenRulesApply(hookAuthority: Bool, durable: Bool) -> Bool {
        hookAuthority || durable
    }

    /// - `raisedByScreen`: the `waiting` this terminal shows came from the screen
    ///   (no hook said so). The screen may then take it back: the question left
    ///   the screen — answered, scrolled away, the program gone — and no rule
    ///   sees one any more. A `waiting` a hook raised is the hook's to end.
    ///
    /// Returns nil to keep the current state.
    static func fromScreen(
        _ screen: ScreenDetection?,
        agent: AgentKind,
        hookAuthority: Bool,
        current: AttentionState,
        raisedByScreen: Bool = false
    ) -> AttentionState? {
        if !hookAuthority, raisedByScreen, current == .waiting, screen == nil {
            return .free
        }
        guard let screen, !screen.skipStateUpdate else { return nil }

        // An aborted turn is the one end of work no hook reports, so the screen
        // may close it even under hook authority — but only a turn in flight or
        // a question you just dismissed with Esc. Nothing was produced to
        // review, so it is free, not ready.
        if screen.interrupted {
            return (current == .running || current == .waiting) ? .free : nil
        }

        if hookAuthority {
            // An idle, open prompt while the hooks say a turn runs: the turn ended
            // without a hook (an abort before any output, a lost Stop). Nothing
            // was produced to review, so it is free, not ready — and only a
            // running turn: a waiting one asks through a dialog.
            if screen.idlePrompt { return current == .running ? .free : nil }
            // A question that was answered. The permission was granted (no hook says
            // so) and the tool runs: the dialog is gone and the footer of a live turn
            // is there. Only a `waiting` — a running terminal is already right, and
            // an idle one is the hooks' to start, so the screen never invents running.
            if screen.state == .working { return current == .waiting ? .running : nil }
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

/// A reading of the screen that moves a terminal on its own word has to hold on
/// consecutive polls before it counts.
///
/// Three readings are that bold: "the prompt is idle, so the turn you call running
/// is over", "the question I raised is gone", and "the footer of a live turn is where
/// the question was". Each can be true for a moment without being true — a turn that
/// has just begun shows an idle-looking prompt for a split second before its spinner,
/// a program redraws, a dialog is about to be drawn over a footer that still says
/// "esc to interrupt" — and a wrong "free" would hide a turn that is still running.
/// Two polls (1.5 s apart or more) rule the blink out, and an abort that is real is
/// still there on the second.
struct ScreenConfirmation {
    enum Reading: Equatable {
        case idlePrompt
        case questionGone
        /// The footer of a live turn where a question was: it was answered.
        case answered
    }

    /// Polls in a row a reading must hold.
    static let polls = 2

    private var streaks: [UUID: (reading: Reading, polls: Int)] = [:]

    /// Feed this poll's reading of a terminal (nil = nothing bold to say, which
    /// ends any streak). True once the reading has held on `polls` polls in a row.
    mutating func confirm(_ reading: Reading?, for id: UUID) -> Bool {
        guard let reading else {
            streaks[id] = nil
            return false
        }
        let held = (streaks[id]?.reading == reading ? streaks[id]?.polls ?? 0 : 0) + 1
        streaks[id] = (reading, held)
        return held >= Self.polls
    }

    mutating func forget(_ id: UUID) {
        streaks[id] = nil
    }
}

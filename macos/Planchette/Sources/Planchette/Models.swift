import SwiftUI

/// Attention state of a terminal session — the heart of Planchette.
/// Color system: green = done (result ready for review), purple = running,
/// blue = waiting for your input, red = error, gray = free (nothing to do).
enum AttentionState: String, Codable {
    case ready    // green  — turn/command finished, result awaits your review
    case running  // purple — an agent or command is running
    case waiting  // blue   — waiting for YOUR input (question / permission)
    case error    // red    — the last command or agent exited with an error
    case free     // gray   — empty prompt, nothing to review, take me

    var symbol: String {
        switch self {
        case .ready: "circle.fill"
        case .running: "circle.dotted"
        case .waiting: "questionmark.bubble.fill"
        case .error: "exclamationmark.triangle.fill"
        case .free: "circle"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .running: .purple
        case .waiting: .blue
        case .error: .red
        case .free: .gray
        }
    }

    /// Localized name for the settings legend / inbox.
    var label: String {
        switch self {
        case .ready: L10n.t(.stateReady)
        case .running: L10n.t(.stateRunning)
        case .waiting: L10n.t(.stateWaiting)
        case .error: L10n.t(.stateError)
        case .free: L10n.t(.stateFree)
        }
    }

    /// Does this state belong in the attention inbox?
    var needsAttention: Bool { self == .waiting || self == .error }

    /// Sort priority (lower = more urgent) — the notifications panel's order,
    /// and what decides which state stands for a whole project.
    var rank: Int {
        switch self {
        case .error: 0
        case .waiting: 1
        case .running: 2
        case .ready: 3
        case .free: 4
        }
    }

    /// The single state that represents a set of terminals: the most urgent
    /// one, so a project badge can never hide an error behind a calm green.
    /// Empty (a project without terminals) is `free` — there is nothing going on.
    static func mostUrgent(of states: [AttentionState]) -> AttentionState {
        states.min { $0.rank < $1.rank } ?? .free
    }

    /// Is this terminal actively doing / holding something (not idle)?
    var isActive: Bool { self != .ready && self != .free }

    /// Migrate old raw values: v0.1.x used "working/asking/done/free"; until
    /// v0.2.x "free" was folded into ready — now it's a state of its own.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running", "working": self = .running
        case "waiting", "asking": self = .waiting
        case "error": self = .error
        case "ready", "done": self = .ready
        default: self = .free   // "free" or anything unknown → idle
        }
    }

    // MARK: State machine (pure + unit-tested so the colors stay reliable)

    /// The state a Claude Code hook event transitions to (nil = no change).
    /// running = an agent turn is working, waiting = it needs you, ready = the
    /// turn finished (result to review), free = nothing pending for you.
    ///
    /// `source` is the SessionStart source (`startup`, `clear`, `resume`,
    /// `compact`, `fork`). A conversation that just began has nothing to review
    /// and nothing to answer, so it is free on its own evidence — `/clear`
    /// (SessionEnd `clear` + SessionStart `clear`) must land on gray even if one
    /// of the two events is lost. `compact` and `fork` are the exception: they
    /// happen *mid-turn*, so the running/waiting state must survive them.
    static func forHookEvent(_ event: String, source: String? = nil) -> AttentionState? {
        switch event {
        case "UserPromptSubmit": .running
        case "Notification", "PermissionRequest": .waiting
        case "Stop", "SubagentStop": .ready
        case "SessionEnd": .free
        case "SessionStart": (source == "compact" || source == "fork") ? nil : .free
        default: nil
        }
    }

    /// The state after a shell command finishes (OSC 133). Returns nil to keep
    /// the current state — an active agent turn (running/waiting) owns the
    /// indicator and a plain command result must not stomp it. Exit 130
    /// (Ctrl+C) is a deliberate stop — e.g. killing a dev server — not an
    /// error and nothing to review: the terminal is free again.
    static func afterCommandFinish(exitCode: Int, current: AttentionState) -> AttentionState? {
        if current == .running || current == .waiting { return nil }
        if exitCode == 130 { return .free }
        return exitCode > 0 ? .error : .ready
    }
}

/// "n sessions in this state" count badge — THE one way such a count is
/// rendered (project sidebar, notifications panel), so the state colors are
/// identical everywhere. Colors come solely from `AttentionState.tint`.
struct StateCountBadge: View {
    let state: AttentionState
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(state.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(state.tint)
    }
}

/// "running" / "waiting for input" / "free" — THE one way a state is named on
/// screen (notifications panel, folder overview), so a chip always reads and
/// colors the same. Colors come solely from `AttentionState.tint`.
struct StateChip: View {
    let state: AttentionState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(state.tint.opacity(0.16), in: Capsule())
            .foregroundStyle(state.tint)
    }
}

/// Named palette so colors persist as stable strings.
enum SessionColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, teal, blue, purple, pink

    var id: String { rawValue }

    var color: Color? {
        switch self {
        case .none: nil
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }
}

enum GroupViewMode: String, Codable {
    case tabs
    case cluster
}

/// Which coding agent a terminal is running. Claude Code reports its whole
/// lifecycle through hooks; other agents report less (or nothing) and lean on
/// screen detection, so the kind decides how much a hook event is worth.
enum AgentKind: String, Codable, CaseIterable {
    case claude
    case codex
    /// A plain shell, or an agent we don't recognize.
    case none

    /// Display name — a proper noun, so deliberately not localized.
    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .none: "—"
        }
    }

    /// Whether this agent tells us about *every* state change (prompt
    /// submitted, question asked, turn finished, session ended). Only then are
    /// hooks the sole authority; otherwise the screen fills the gaps.
    var reportsFullLifecycle: Bool { self == .claude }

    /// Parse the label a hook script sends us.
    init(hookLabel: String?) {
        self = AgentKind(rawValue: (hookLabel ?? "").lowercased()) ?? .none
    }
}

struct TerminalSession: Identifiable, Codable, Equatable {
    let id: UUID
    var groupID: UUID
    var workingDirectory: String
    var currentDirectory: String  // live, updated via OSC pwd reports
    var customTitle: String?
    var oscTitle: String?         // title reported by the shell/program
    var color: SessionColor = .none
    /// The agent last seen in this terminal. Persisted so the inbox still knows
    /// what a restored terminal runs before its first hook arrives.
    var agentKind: AgentKind = .none
    var claudeSessionID: String?
    var startupCommand: String?   // re-run after restore (e.g. `npm run dev`)
    var resumeClaudeOnRestore: Bool = true
    /// This terminal runs its shell inside tmux, so the agent survives a quit,
    /// a crash and Install & Relaunch (see Durable.swift). Fixed at creation:
    /// the multiplexer has to be there from the first process, so flipping it
    /// on a live terminal would do nothing until it is closed and reopened.
    var durable: Bool = false

    // Attention (persisted so a restart doesn't lose the inbox)
    var state: AttentionState = .free
    var stateSince: Date = .init()
    var lastMessage: String?
    /// What I asked the agent to do — first line of the last submitted prompt.
    /// The instant, deterministic answer to "working on WHAT?".
    var currentTask: String?
    /// False when this terminal finished something you have not looked at yet.
    /// `ready` alone means "a turn ended at some point"; unseen `ready` is the
    /// honest answer to "what is waiting for my review?" (herdr calls it `done`
    /// as opposed to `idle`). Only set for work that finished in the background —
    /// watching a turn finish counts as having seen it.
    var seen: Bool = true

    // Tags: what should happen with this terminal ("to test", "review", …)
    var tags: [String] = []

    /// "Not now — remind me then." Until this moment the terminal is out of the
    /// inbox, the badges and every notification (see `AppState.isSnoozed`); when
    /// it passes, one reminder brings it back. Nil = not snoozed.
    var snoozedUntil: Date?

    // AI assist
    var transcriptPath: String?   // Claude transcript JSONL, from hook events
    var aiSummary: String?        // one-liner, only when AI assist is enabled
    var aiTopic: String?          // one-word topic label for grouping

    static let suggestedTags = ["to test", "review", "blocked", "wip"]

    init(id: UUID = UUID(), groupID: UUID, workingDirectory: String) {
        self.id = id
        self.groupID = groupID
        self.workingDirectory = workingDirectory
        self.currentDirectory = workingDirectory
    }

    // Backwards-compatible decoding: every field added after v1 falls back to
    // its default when missing in an older state.json.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        groupID = try c.decode(UUID.self, forKey: .groupID)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        currentDirectory = try c.decodeIfPresent(String.self, forKey: .currentDirectory) ?? workingDirectory
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        oscTitle = try c.decodeIfPresent(String.self, forKey: .oscTitle)
        color = try c.decodeIfPresent(SessionColor.self, forKey: .color) ?? .none
        agentKind = try c.decodeIfPresent(AgentKind.self, forKey: .agentKind) ?? .none
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        resumeClaudeOnRestore = try c.decodeIfPresent(Bool.self, forKey: .resumeClaudeOnRestore) ?? true
        durable = try c.decodeIfPresent(Bool.self, forKey: .durable) ?? false
        state = try c.decodeIfPresent(AttentionState.self, forKey: .state) ?? .free
        stateSince = try c.decodeIfPresent(Date.self, forKey: .stateSince) ?? Date()
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        currentTask = try c.decodeIfPresent(String.self, forKey: .currentTask)
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? true
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        aiSummary = try c.decodeIfPresent(String.self, forKey: .aiSummary)
        aiTopic = try c.decodeIfPresent(String.self, forKey: .aiTopic)
    }

    /// Short display title: manual > ticket from git branch > OSC title > folder name.
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let ticket = Titles.ticket(forDirectory: currentDirectory) { return ticket }
        if let oscTitle {
            // Strip a leading status glyph (Claude Code prefixes "✳ "/"●",
            // which reads as a stray star/dot next to the name). Return the full
            // title — each view truncates it to the width it actually has.
            let cleaned = String(oscTitle.drop(while: { $0.isSymbol || $0.isWhitespace }))
                .trimmingCharacters(in: .whitespaces)
            // Skip the shell's default prompt (user@host:path) — it's not a name.
            if !cleaned.isEmpty && !Titles.looksLikeShellPrompt(cleaned) { return cleaned }
        }
        // Nothing meaningful running: a free terminal says so, otherwise the
        // folder name.
        return state == .free ? L10n.t(.free) : (currentDirectory as NSString).lastPathComponent
    }

    /// Last two path components, full path shown on hover.
    var shortPath: String { Titles.shortPath(currentDirectory) }

    /// What this terminal currently reports: for waiting/error the question or
    /// the error itself, otherwise what it works on (the AI summary when there
    /// is one). Nil when there is nothing real to say — the state chip already
    /// names the state, and "free" has no message worth a line.
    var notificationLine: String? {
        let line: String? = switch state {
        case .waiting, .error: lastMessage ?? currentTask
        case .free: nil
        case .running, .ready: aiSummary ?? currentTask ?? lastMessage
        }
        return (line?.isEmpty ?? true) ? nil : line
    }

    /// Condense a submitted prompt to a one-line task label ("working on …").
    static func taskLine(fromPrompt prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}

/// "What happened here lately" — the newest reports of a set of terminals,
/// newest first. Pure, so the folder overview's feed is unit-tested rather than
/// eyeballed. Terminals with nothing to report are left out: a feed that lists
/// idle shells is a terminal list with timestamps, not a feed.
enum ActivityFeed {
    static func entries(_ sessions: [TerminalSession], limit: Int = 6) -> [TerminalSession] {
        sessions
            .filter { $0.notificationLine != nil }
            .sorted { $0.stateSince > $1.stateSince }
            .prefix(limit)
            .map { $0 }
    }
}

/// Where a dragged terminal is dropped relative to a target pane.
enum LayoutEdge { case top, bottom, left, right }

/// A recursive split arrangement of terminals in cluster mode (like iTerm2's
/// split panes). `row` lays children left→right, `column` top→bottom.
indirect enum SplitLayout: Codable, Equatable {
    case leaf(UUID)               // a terminal session
    case row([SplitLayout])       // horizontal splits
    case column([SplitLayout])    // vertical splits

    var leaves: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .row(let c), .column(let c): c.flatMap(\.leaves)
        }
    }

    /// Identity for SwiftUI's ForEach. Derived from the node's leaves so a view's
    /// @State (e.g. the drop highlight) follows its content when panes reorder,
    /// instead of leaking to whatever lands at the same index. Unique among
    /// siblings because a leaf can only appear in one child.
    var stableID: String { leaves.map(\.uuidString).joined(separator: "+") }

    /// Remove a leaf, collapsing empty/single-child nodes.
    func removingLeaf(_ id: UUID) -> SplitLayout? {
        switch self {
        case .leaf(let l): return l == id ? nil : self
        case .row(let c):
            let n = c.compactMap { $0.removingLeaf(id) }
            return n.isEmpty ? nil : (n.count == 1 ? n[0] : .row(n))
        case .column(let c):
            let n = c.compactMap { $0.removingLeaf(id) }
            return n.isEmpty ? nil : (n.count == 1 ? n[0] : .column(n))
        }
    }

    /// Split the target leaf, placing `newID` on the given edge.
    func splitting(_ target: UUID, with newID: UUID, edge: LayoutEdge) -> SplitLayout {
        switch self {
        case .leaf(let l):
            guard l == target else { return self }
            switch edge {
            case .left:   return .row([.leaf(newID), .leaf(target)])
            case .right:  return .row([.leaf(target), .leaf(newID)])
            case .top:    return .column([.leaf(newID), .leaf(target)])
            case .bottom: return .column([.leaf(target), .leaf(newID)])
            }
        case .row(let c):   return .row(c.map { $0.splitting(target, with: newID, edge: edge) })
        case .column(let c): return .column(c.map { $0.splitting(target, with: newID, edge: edge) })
        }
    }

    /// Flatten nested same-axis nodes and collapse singletons.
    func normalized() -> SplitLayout {
        func flatten(_ children: [SplitLayout], isRow: Bool) -> [SplitLayout] {
            var out: [SplitLayout] = []
            for child in children.map({ $0.normalized() }) {
                switch child {
                case .row(let g) where isRow: out.append(contentsOf: g)
                case .column(let g) where !isRow: out.append(contentsOf: g)
                default: out.append(child)
                }
            }
            return out
        }
        switch self {
        case .leaf: return self
        case .row(let c):
            let f = flatten(c, isRow: true); return f.count == 1 ? f[0] : .row(f)
        case .column(let c):
            let f = flatten(c, isRow: false); return f.count == 1 ? f[0] : .column(f)
        }
    }

    /// Ensure the tree contains exactly `ids` (append new, drop removed).
    func synced(to ids: [UUID]) -> SplitLayout {
        var tree: SplitLayout? = self
        for gone in leaves where !ids.contains(gone) { tree = tree?.removingLeaf(gone) }
        var result = tree ?? .row(ids.isEmpty ? [] : [.leaf(ids[0])])
        let present = Set(result.leaves)
        for id in ids where !present.contains(id) {
            result = (result.normalized().appendingRight(id))
        }
        return result.normalized()
    }

    private func appendingRight(_ id: UUID) -> SplitLayout {
        switch self {
        case .row(let c): return .row(c + [.leaf(id)])
        default: return .row([self, .leaf(id)])
        }
    }
}

struct SessionGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var color: SessionColor = .none
    var viewMode: GroupViewMode = .tabs
    var favorite: Bool = false   // "Hauptprojekt": high priority
    var sessionIDs: [UUID] = []
    var activeSessionID: UUID?
    var clusterLayout: SplitLayout?   // custom split arrangement (cluster mode)
    /// Set when this project is a git worktree Planchette created: the checkout
    /// path, so closing the project can offer to remove it again. Optional, so
    /// older state decodes unchanged.
    var worktreePath: String?
    /// The repo the worktree belongs to — `git worktree remove` has to run there.
    var worktreeRepoRoot: String?
    /// Snooze for the whole project: every terminal in it is quiet until then
    /// (see `TerminalSession.snoozedUntil`). Optional, so older state decodes.
    var snoozedUntil: Date?

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A named box of projects in one window's sidebar ("myposter", "side"). It
/// owns the order of the projects inside it; projects listed in no folder stay
/// at the top level. Deliberately per window (`WindowModel.folders`): the
/// sidebar is a per-window view, and moving a project to another window means
/// putting it somewhere else.
struct ProjectFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var color: SessionColor = .none
    /// Collapsed in the sidebar. Persisted — a folder you closed stays closed.
    var collapsed: Bool = false
    var groupIDs: [UUID] = []

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(SessionColor.self, forKey: .color) ?? .none
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        groupIDs = try c.decodeIfPresent([UUID].self, forKey: .groupIDs) ?? []
    }
}

/// One app window: owns a set of groups and its own selection. Groups can be
/// moved to a new window and windows merged back together.
struct WindowModel: Identifiable, Codable, Equatable {
    let id: UUID
    var groupIDs: [UUID] = []
    var selectedGroupID: UUID?
    /// Named boxes over this window's projects, in sidebar order. A project may
    /// appear in at most one of them; `AppState.sanitizeWindows` enforces that.
    var folders: [ProjectFolder] = []
    /// The folder whose overview page fills the main area. Set by clicking a
    /// folder in the sidebar and cleared the moment a project or terminal is
    /// picked: the overview is a place you pass through on the way to a tab,
    /// never a second thing shown beside one. `selectedGroupID` is deliberately
    /// left standing while it is set, so leaving the overview lands back on the
    /// project you came from.
    var selectedFolderID: UUID?

    init(id: UUID = UUID()) {
        self.id = id
    }

    /// Show a project — the only way `selectedGroupID` changes, so a project and
    /// a folder overview can never both claim the main area.
    mutating func selectGroup(_ id: UUID) {
        selectedGroupID = id
        selectedFolderID = nil
    }

    // Custom, so a state written before folders existed still decodes (the
    // synthesized decoder would demand the key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        groupIDs = try c.decodeIfPresent([UUID].self, forKey: .groupIDs) ?? []
        selectedGroupID = try c.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        folders = try c.decodeIfPresent([ProjectFolder].self, forKey: .folders) ?? []
        selectedFolderID = try c.decodeIfPresent(UUID.self, forKey: .selectedFolderID)
    }

    /// The folder holding this project, if any.
    func folder(of groupID: UUID) -> ProjectFolder? {
        folders.first { $0.groupIDs.contains(groupID) }
    }

    /// Projects that are in no folder — shown at the sidebar's top level.
    var looseGroupIDs: [UUID] {
        let filed = Set(folders.flatMap(\.groupIDs))
        return groupIDs.filter { !filed.contains($0) }
    }

    /// Move projects into `folderID` (nil = out of every folder, back to the top
    /// level), landing before `before` or at the end. One operation for both
    /// halves of a sidebar drag: which box a project is in, and where in it —
    /// dropping on a folder means "into this folder", dropping on a project
    /// means "next to this one, wherever it lives".
    ///
    /// The moved projects keep their relative order, and `ids` may name several:
    /// a drag of a multi-selection is one move, not n moves.
    mutating func move(_ ids: [UUID], toFolder folderID: UUID?, before: UUID? = nil) {
        // Only projects of this window, in the window's own order.
        let moving = groupIDs.filter { ids.contains($0) }
        guard !moving.isEmpty else { return }
        // Dropped on one of the projects being dragged: there is no "before
        // itself" to land on, and treating it as "at the end" would reshuffle
        // the list for a gesture that meant nothing.
        if let before, moving.contains(before) { return }
        for idx in folders.indices {
            folders[idx].groupIDs.removeAll { moving.contains($0) }
        }
        if let folderID, let fidx = folders.firstIndex(where: { $0.id == folderID }) {
            var target = folders[fidx].groupIDs
            // A `before` from another folder (or none) means "at the end".
            let at = before.flatMap { target.firstIndex(of: $0) } ?? target.count
            target.insert(contentsOf: moving, at: at)
            folders[fidx].groupIDs = target
        } else {
            var loose = looseGroupIDs.filter { !moving.contains($0) }
            let at = before.flatMap { loose.firstIndex(of: $0) } ?? loose.count
            loose.insert(contentsOf: moving, at: at)
            groupIDs = folders.flatMap(\.groupIDs) + loose
            return
        }
        normalizeGroupOrder()
    }

    /// `groupIDs` mirrors the sidebar: filed projects first (in folder order),
    /// then the loose ones. Keeping the two in step is what lets `looseGroupIDs`
    /// carry the top-level order without a second list to maintain.
    mutating func normalizeGroupOrder() {
        let filed = folders.flatMap(\.groupIDs)
        let filedSet = Set(filed)
        groupIDs = filed + groupIDs.filter { !filedSet.contains($0) }
    }
}

/// Persisted snapshot of everything.
struct PersistedState: Codable {
    var groups: [SessionGroup] = []
    var sessions: [TerminalSession] = []
    var windows: [WindowModel] = []
    var selectedGroupID: UUID?   // legacy (pre-multi-window)
    var aiEnabled: Bool = false
    var language: AppLanguage = .system
    var appearance: AppAppearance = .system
    var autoUpdateCheck: Bool = true
    /// Whether new terminals are created durable (tmux-backed). Opt-in, and it
    /// has to stay that way: tmux cannot pass the terminal's keyboard protocol
    /// through, so `Shift+Enter` and friends reach an agent as a plain `Enter`
    /// (verified against tmux 3.7b at both `extended-keys on` and `always`).
    /// Durability is worth that trade for a long-running agent; it is not worth
    /// imposing on every terminal.
    var durableTerminals: Bool = false
    /// Kept only so states written by 0.2.13 still decode. That version briefly
    /// forced the setting on; nothing acts on this now.
    var durableDefaultApplied: Bool = true

    init(
        groups: [SessionGroup],
        sessions: [TerminalSession],
        windows: [WindowModel],
        aiEnabled: Bool,
        language: AppLanguage,
        appearance: AppAppearance,
        autoUpdateCheck: Bool,
        durableTerminals: Bool,
        durableDefaultApplied: Bool = true
    ) {
        self.durableDefaultApplied = durableDefaultApplied
        self.groups = groups
        self.sessions = sessions
        self.windows = windows
        self.aiEnabled = aiEnabled
        self.language = language
        self.appearance = appearance
        self.autoUpdateCheck = autoUpdateCheck
        self.durableTerminals = durableTerminals
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([SessionGroup].self, forKey: .groups) ?? []
        sessions = try c.decodeIfPresent([TerminalSession].self, forKey: .sessions) ?? []
        windows = try c.decodeIfPresent([WindowModel].self, forKey: .windows) ?? []
        selectedGroupID = try c.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? true
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        autoUpdateCheck = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateCheck) ?? true
        durableTerminals = try c.decodeIfPresent(Bool.self, forKey: .durableTerminals) ?? false
        durableDefaultApplied =
            try c.decodeIfPresent(Bool.self, forKey: .durableDefaultApplied) ?? true
    }
}

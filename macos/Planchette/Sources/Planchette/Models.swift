import SwiftUI

/// Attention state of a terminal session — the heart of Planchette.
/// Color system: green = ready for input, purple = running,
/// blue = waiting for your input, red = error.
enum AttentionState: String, Codable {
    case ready    // green  — idle at the prompt / finished, ready for input
    case running  // purple — an agent or command is running
    case waiting  // blue   — waiting for YOUR input (question / permission)
    case error    // red    — the last command or agent exited with an error

    var symbol: String {
        switch self {
        case .ready: "circle.fill"
        case .running: "circle.dotted"
        case .waiting: "questionmark.bubble.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .running: .purple
        case .waiting: .blue
        case .error: .red
        }
    }

    /// Localized name for the settings legend / inbox.
    var label: String {
        switch self {
        case .ready: L10n.t(.stateReady)
        case .running: L10n.t(.stateRunning)
        case .waiting: L10n.t(.stateWaiting)
        case .error: L10n.t(.stateError)
        }
    }

    /// Does this state belong in the attention inbox?
    var needsAttention: Bool { self == .waiting || self == .error }

    /// Migrate v0.1.x raw values ("working/asking/done/free") to the new set.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running", "working": self = .running
        case "waiting", "asking": self = .waiting
        case "error": self = .error
        default: self = .ready   // "ready", "done", "free", or anything unknown
        }
    }

    // MARK: State machine (pure + unit-tested so the colors stay reliable)

    /// The state a Claude Code hook event transitions to (nil = no change).
    /// running = an agent turn is working, waiting = it needs you, ready = idle.
    static func forHookEvent(_ event: String) -> AttentionState? {
        switch event {
        case "UserPromptSubmit": .running
        case "Notification", "PermissionRequest": .waiting
        case "Stop", "SubagentStop", "SessionEnd": .ready
        default: nil
        }
    }

    /// The state after a shell command finishes (OSC 133). Returns nil to keep
    /// the current state — an active agent turn (running/waiting) owns the
    /// indicator and a plain command result must not stomp it. Exit 130
    /// (Ctrl+C) is a deliberate stop — e.g. killing a dev server — not an error.
    static func afterCommandFinish(exitCode: Int, current: AttentionState) -> AttentionState? {
        if current == .running || current == .waiting { return nil }
        return exitCode > 0 && exitCode != 130 ? .error : .ready
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

struct TerminalSession: Identifiable, Codable, Equatable {
    let id: UUID
    var groupID: UUID
    var workingDirectory: String
    var currentDirectory: String  // live, updated via OSC pwd reports
    var customTitle: String?
    var oscTitle: String?         // title reported by the shell/program
    var color: SessionColor = .none
    var claudeSessionID: String?
    var startupCommand: String?   // re-run after restore (e.g. `npm run dev`)
    var resumeClaudeOnRestore: Bool = true

    // Attention (persisted so a restart doesn't lose the inbox)
    var state: AttentionState = .ready
    var stateSince: Date = .init()
    var lastMessage: String?

    // Tags: what should happen with this terminal ("to test", "review", …)
    var tags: [String] = []

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
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        resumeClaudeOnRestore = try c.decodeIfPresent(Bool.self, forKey: .resumeClaudeOnRestore) ?? true
        state = try c.decodeIfPresent(AttentionState.self, forKey: .state) ?? .ready
        stateSince = try c.decodeIfPresent(Date.self, forKey: .stateSince) ?? Date()
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
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
        // Nothing meaningful running: an idle terminal is "free", otherwise the
        // folder name.
        return state == .ready ? L10n.t(.free) : (currentDirectory as NSString).lastPathComponent
    }

    /// Last two path components, full path shown on hover.
    var shortPath: String { Titles.shortPath(currentDirectory) }
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

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// One app window: owns a set of groups and its own selection. Groups can be
/// moved to a new window and windows merged back together.
struct WindowModel: Identifiable, Codable, Equatable {
    let id: UUID
    var groupIDs: [UUID] = []
    var selectedGroupID: UUID?

    init(id: UUID = UUID()) {
        self.id = id
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

    init(
        groups: [SessionGroup],
        sessions: [TerminalSession],
        windows: [WindowModel],
        aiEnabled: Bool,
        language: AppLanguage,
        appearance: AppAppearance,
        autoUpdateCheck: Bool
    ) {
        self.groups = groups
        self.sessions = sessions
        self.windows = windows
        self.aiEnabled = aiEnabled
        self.language = language
        self.appearance = appearance
        self.autoUpdateCheck = autoUpdateCheck
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
    }
}

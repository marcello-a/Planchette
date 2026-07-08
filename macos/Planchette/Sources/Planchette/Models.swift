import SwiftUI

/// Attention state of a terminal session — the heart of Planchette.
enum AttentionState: String, Codable {
    case working  // agent/process is busy
    case asking   // Claude asked a question / needs permission
    case done     // Claude finished its turn
    case free     // nothing needs this terminal

    var symbol: String {
        switch self {
        case .working: "circle.dotted"
        case .asking: "questionmark.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .free: "moon.zzz"
        }
    }

    var tint: Color {
        switch self {
        case .working: .blue
        case .asking: .orange
        case .done: .green
        case .free: .secondary
        }
    }

    /// Does this state belong in the attention inbox?
    var needsAttention: Bool { self == .asking || self == .done }
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
    var state: AttentionState = .free
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
        state = try c.decodeIfPresent(AttentionState.self, forKey: .state) ?? .free
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
        if let oscTitle, !oscTitle.isEmpty { return Titles.shorten(oscTitle) }
        return (currentDirectory as NSString).lastPathComponent
    }

    /// Last two path components, full path shown on hover.
    var shortPath: String { Titles.shortPath(currentDirectory) }
}

struct SessionGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var color: SessionColor = .none
    var viewMode: GroupViewMode = .tabs
    var favorite: Bool = false   // "Hauptprojekt": high priority
    var sessionIDs: [UUID] = []
    var activeSessionID: UUID?

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

    init(
        groups: [SessionGroup],
        sessions: [TerminalSession],
        windows: [WindowModel],
        aiEnabled: Bool,
        language: AppLanguage
    ) {
        self.groups = groups
        self.sessions = sessions
        self.windows = windows
        self.aiEnabled = aiEnabled
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([SessionGroup].self, forKey: .groups) ?? []
        sessions = try c.decodeIfPresent([TerminalSession].self, forKey: .sessions) ?? []
        windows = try c.decodeIfPresent([WindowModel].self, forKey: .windows) ?? []
        selectedGroupID = try c.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? false
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
    }
}

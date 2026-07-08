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

    init(id: UUID = UUID(), groupID: UUID, workingDirectory: String) {
        self.id = id
        self.groupID = groupID
        self.workingDirectory = workingDirectory
        self.currentDirectory = workingDirectory
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

/// Persisted snapshot of everything.
struct PersistedState: Codable {
    var groups: [SessionGroup] = []
    var sessions: [TerminalSession] = []
    var selectedGroupID: UUID?
}

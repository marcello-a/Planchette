import Foundation

/// What a sidebar detail describes. Settings → Project panel puts the details
/// of one group under one heading, so a switch is found by what it is about —
/// where a terminal is, what it is doing, what you marked on it, what Claude
/// reports — instead of by whether it happens to be on by default.
enum SidebarDetailGroup: String, CaseIterable, Identifiable {
    // On a terminal row.
    case location, activity, marks, claude
    // On a project row.
    case projectRow

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .location: .sidebarGroupLocation
        case .activity: .sidebarGroupActivity
        case .marks: .sidebarGroupMarks
        case .claude: .sidebarGroupClaude
        case .projectRow: .sidebarGroupProjectRow
        }
    }

    /// Whether the details of this group are drawn on a terminal's row.
    var isTerminal: Bool { self != .projectRow }

    static var terminalGroups: [SidebarDetailGroup] { allCases.filter(\.isTerminal) }
}

/// Every extra piece of information the project panel (the left sidebar) can
/// show next to a project or a terminal. Each one can be turned off in
/// Settings → Project panel; the list there is exactly this enum, grouped by
/// `group`, in this order within a group.
///
/// On by default — except the model and the context usage, which cost a
/// transcript read and are opinionated about what a row should say.
enum SidebarDetail: String, CaseIterable, Identifiable {
    case path, branch, pullRequest, task, age, tags, note, finished, snooze, attentionCounts
    case backgroundTasks
    case model, contextUsage, cacheTimer

    var id: String { rawValue }

    /// The heading this detail sits under in Settings.
    var group: SidebarDetailGroup {
        switch self {
        case .path, .branch, .pullRequest: .location
        case .task, .age, .backgroundTasks: .activity
        case .tags, .note, .finished, .snooze: .marks
        case .model, .contextUsage, .cacheTimer: .claude
        case .attentionCounts: .projectRow
        }
    }

    var defaultOn: Bool {
        switch self {
        case .model, .contextUsage, .cacheTimer: false
        default: true
        }
    }

    var titleKey: LKey {
        switch self {
        case .path: .detailPath
        case .branch: .detailBranch
        case .pullRequest: .detailPullRequest
        case .task: .detailTask
        case .age: .detailAge
        case .tags: .detailTags
        case .note: .detailNote
        case .finished: .detailFinished
        case .snooze: .detailSnooze
        case .attentionCounts: .detailAttentionCounts
        case .backgroundTasks: .detailBackgroundTasks
        case .model: .detailModel
        case .contextUsage: .detailContextUsage
        case .cacheTimer: .detailCacheTimer
        }
    }

    /// One line in Settings under the switch: what this detail says.
    var helpKey: LKey {
        switch self {
        case .path: .detailPathHelp
        case .branch: .detailBranchHelp
        case .pullRequest: .detailPullRequestHelp
        case .task: .detailTaskHelp
        case .age: .detailAgeHelp
        case .tags: .detailTagsHelp
        case .note: .detailNoteHelp
        case .finished: .detailFinishedHelp
        case .snooze: .detailSnoozeHelp
        case .attentionCounts: .detailAttentionCountsHelp
        case .backgroundTasks: .detailBackgroundTasksHelp
        case .model: .detailModelHelp
        case .contextUsage: .detailContextUsageHelp
        case .cacheTimer: .detailCacheTimerHelp
        }
    }
}

/// Which details are shown. Stored as the choices that differ from the
/// defaults, keyed by raw value, so a detail added later starts at its own
/// default instead of an old file's silence, and a renamed or removed one is
/// ignored rather than breaking the decode.
struct SidebarDetails: Codable, Equatable {
    var overrides: [String: Bool] = [:]

    func shows(_ detail: SidebarDetail) -> Bool {
        overrides[detail.rawValue] ?? detail.defaultOn
    }

    mutating func set(_ detail: SidebarDetail, _ on: Bool) {
        overrides[detail.rawValue] = on == detail.defaultOn ? nil : on
    }
}

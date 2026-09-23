import Foundation

/// Every extra piece of information the project panel (the left sidebar) can
/// show next to a project or a terminal. Each one can be turned off in
/// Settings → Project panel; the list there is exactly this enum, in this order.
///
/// On by default — except the model and the context usage, which cost a
/// transcript read and are opinionated about what a row should say.
enum SidebarDetail: String, CaseIterable, Identifiable {
    case path, branch, pullRequest, task, age, tags, note, finished, snooze, attentionCounts
    case model, contextUsage

    var id: String { rawValue }

    var defaultOn: Bool {
        switch self {
        case .model, .contextUsage: false
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
        case .model: .detailModel
        case .contextUsage: .detailContextUsage
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
        case .model: .detailModelHelp
        case .contextUsage: .detailContextUsageHelp
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

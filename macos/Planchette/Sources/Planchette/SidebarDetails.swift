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

/// Where a branch name gives way when the row is too narrow for it. Three
/// answers because there is no one right one: which part of a branch identifies
/// a checkout depends on how the branches are named.
///
/// The default drops the end: `feature/mvt/VOLL-1234-…` keeps the prefix and
/// the ticket, which is what names the work, while the slug at the end only
/// repeats the ticket. Teams whose branches differ only in their last segment
/// want `.front`, and `.middle` is the compromise that keeps both ends.
enum BranchTrim: String, Codable, CaseIterable, Identifiable {
    /// Cut at the front — `…/VOLL-1234-poster-frame`.
    case front
    /// Cut in the middle — `feature/mvt/VOL…ce-poster-frame`.
    case middle
    /// Cut at the end — `feature/mvt/VOLL-1234-…`.
    case back

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .front: .branchTrimFront
        case .middle: .branchTrimMiddle
        case .back: .branchTrimBack
        }
    }
}

/// What the line under a terminal says it is working on. All three are there
/// already — the only question is which one answers "what is this terminal for"
/// best for the way you work.
enum PromptSource: String, Codable, CaseIterable, Identifiable {
    /// The prompt that opened the session: the assignment, which does not move
    /// when the conversation does.
    case firstPrompt
    /// The prompt you last sent — the default, and what the row said before
    /// there was a choice.
    case lastPrompt
    /// The name Claude Code gives the conversation itself (`AgentTitle`): read
    /// from the transcript, so it costs nothing, and it is the only one of the
    /// three that keeps up with a session that moved on from both prompts.
    case agentTitle

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .firstPrompt: .promptSourceFirst
        case .lastPrompt: .promptSourceLast
        case .agentTitle: .promptSourceAgentTitle
        }
    }

    var helpKey: LKey {
        switch self {
        case .firstPrompt: .promptSourceFirstHelp
        case .lastPrompt: .promptSourceLastHelp
        case .agentTitle: .promptSourceAgentTitleHelp
        }
    }
}

/// Which details are shown, and the two that are not a yes/no — how a branch is
/// trimmed and where the prompt line gets its text.
///
/// The switches are stored as the choices that differ from the defaults, keyed
/// by raw value, so a detail added later starts at its own default instead of
/// an old file's silence, and a renamed or removed one is ignored rather than
/// breaking the decode. The two choices decode the same way: absent (every
/// state file written before them) means the default, and a value no version
/// knows any more falls back to it instead of failing the whole state.
struct SidebarDetails: Codable, Equatable {
    var overrides: [String: Bool] = [:]
    var branchTrim: BranchTrim = .back
    var promptSource: PromptSource = .lastPrompt

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try c.decodeIfPresent([String: Bool].self, forKey: .overrides) ?? [:]
        // `try?`, not `decodeIfPresent`: that one throws on a value it cannot
        // name, which would take the whole state.json down when a file written
        // by a newer version is opened by an older one. A choice we cannot read
        // is a choice we do not have — the default stands.
        branchTrim = (try? c.decode(BranchTrim.self, forKey: .branchTrim)) ?? .back
        promptSource = (try? c.decode(PromptSource.self, forKey: .promptSource)) ?? .lastPrompt
    }

    func shows(_ detail: SidebarDetail) -> Bool {
        overrides[detail.rawValue] ?? detail.defaultOn
    }

    mutating func set(_ detail: SidebarDetail, _ on: Bool) {
        overrides[detail.rawValue] = on == detail.defaultOn ? nil : on
    }

    /// Whether anything on a row is read out of a transcript — the sweep runs
    /// only for what is actually shown (see `AppState.refreshContextUsage`).
    var readsTranscripts: Bool {
        shows(.model) || shows(.contextUsage) || shows(.cacheTimer)
            || (shows(.task) && promptSource == .agentTitle)
    }
}

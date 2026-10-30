import SwiftUI

/// What a merged row shows: a project of one terminal, and that terminal. Plain values, so the
/// sidebar feeds it a live terminal and Settings → Project panel feeds it a sample — one view,
/// and the example cannot drift from the row.
struct MergedRowFacts {
    var projectName: String
    var favorite = false
    /// False for a parked project: it reads dimmed and carries the pause glyph.
    var active = true
    var state: AttentionState
    /// Running only because of background work: the globe, not the robot.
    var inBackground = false
    var stateSince: Date
    /// A name you gave the terminal itself, when it differs from the project's.
    var terminalName: String?
    var directory: String
    var shortPath: String
    var color: SessionColor = .none
    var branch: String?
    var pullRequest: PullRequest?
    var prompt: String?
    var tags: [String] = []
    var note: String?
    var snoozedUntil: Date?
    var backgroundTasks: [BackgroundTask]?
    var usage: ContextUsage?
}

/// One row for a project with one terminal (Settings → Project panel → Layout). The project
/// row and the terminal row said the same thing twice — the name and the path, the state as a
/// sprite and again as a count — so they are one: the state sprite, the name, then what it is
/// doing. Every detail follows the same switches as a terminal row (`SidebarDetails`); the
/// branch shows only when it is a work branch, the path only when it differs from the name.
struct MergedProjectRow<Trailing: View>: View {
    let facts: MergedRowFacts
    let details: SidebarDetails
    /// What sits at the right end of the first line: the close button on hover in the sidebar.
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let shownBranch = facts.branch.flatMap { details.showsBranch($0) ? $0 : nil }
        let shownPrompt = details.shows(.task) ? facts.prompt.flatMap { $0.isEmpty ? nil : $0 } : nil
        let showsAge = details.shows(.age)
        let hasSecondLine = shownPrompt != nil
        // A terminal named after its branch's ticket says it twice once the branch is on the row.
        let shownName = facts.terminalName.flatMap { name in
            shownBranch.map { $0.localizedCaseInsensitiveContains(name) } == true ? nil : name
        }
        HStack(alignment: .top, spacing: 6) {
            // The state, and under it what Claude still runs in the background — with one
            // terminal the sprite is the project's count as well.
            VStack(spacing: 3) {
                StateIcon(state: facts.state, size: 13, inBackground: facts.inBackground)
                if details.shows(.backgroundTasks), let tasks = facts.backgroundTasks {
                    BackgroundTasksBadge(tasks: tasks)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let color = facts.color.color {
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                    Text(facts.projectName)
                        .fontWeight(facts.favorite ? .semibold : .regular)
                        .foregroundStyle(facts.active ? .primary : .secondary)
                        .lineLimit(1)
                    if facts.favorite {
                        PixelIcon(sprite: PixelSprites.star, size: 11, tint: .yellow)
                    }
                    if !facts.active {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(L10n.t(.inactiveProject))
                    }
                    // Which checkout, right after the name: the branch, or a name of its own. It
                    // gives way first — the name and the pills on the right stay whole.
                    if let shownBranch {
                        BranchText(branch: shownBranch, trim: details.branchTrim)
                            .layoutPriority(-1)
                    } else if let name = shownName {
                        Text("· \(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 4)
                    // Without a prompt line the age moves up: a minimal row is one line.
                    if showsAge, !hasSecondLine {
                        WaitingTimeText(since: facts.stateSince)
                    }
                    if let usage = facts.usage {
                        if details.shows(.model) { ModelLabel(model: usage.model) }
                        if details.shows(.contextUsage) { ContextRing(usage: usage) }
                        // A running turn keeps the cache warm — no clock then.
                        if details.shows(.cacheTimer), facts.state != .running,
                           let expires = usage.cacheExpiresAt {
                            CacheTimer(expiresAt: expires)
                        }
                    }
                    if details.shows(.pullRequest), let pr = facts.pullRequest {
                        PullRequestPill(pr: pr)
                    }
                    if details.shows(.snooze), let until = facts.snoozedUntil, until > Date() {
                        SnoozeBadge(until: until)
                    }
                    trailing()
                }
                if details.showsPath(directory: facts.directory, projectName: facts.projectName) {
                    Text(facts.shortPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if details.shows(.note), let note = facts.note {
                    NoteLine(note: note)
                }
                // What it is doing, over the whole width, and how long ago — the age at the right
                // edge, where every list keeps it.
                if let shownPrompt {
                    HStack(spacing: 5) {
                        Text(shownPrompt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if showsAge {
                            WaitingTimeText(since: facts.stateSince)
                        }
                    }
                }
                if details.shows(.tags) {
                    TagChips(tags: facts.tags)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MergedRowFacts {
    /// A terminal as the sidebar knows it.
    @MainActor
    init(group: SessionGroup, session: TerminalSession, state appState: AppState) {
        let ownName = session.rowName.flatMap {
            $0.localizedCaseInsensitiveCompare(group.name) == .orderedSame ? nil : $0
        }
        self.init(
            projectName: group.name, favorite: group.favorite, active: group.active,
            state: session.state, inBackground: appState.runsInBackground(session),
            stateSince: session.stateSince, terminalName: ownName,
            directory: session.currentDirectory, shortPath: session.shortPath, color: session.color,
            branch: appState.branches[session.id], pullRequest: appState.pullRequests[session.id],
            prompt: appState.rowPrompt(for: session), tags: session.tags, note: session.note,
            snoozedUntil: appState.snoozeEnd(for: session) ?? group.snoozedUntil,
            backgroundTasks: appState.backgroundTasks[session.id],
            usage: appState.contextUsage[session.id])
    }

    /// The sample Settings shows: a project with something to say in every detail.
    static func sample(promptSource: PromptSource) -> MergedRowFacts {
        MergedRowFacts(
            projectName: "designer-library", favorite: true, state: .waiting,
            stateSince: Date().addingTimeInterval(-4 * 60),
            directory: "/Users/me/dev/designer-library.worktrees/NIE-2008",
            shortPath: "designer-library.worktrees/NIE-2008",
            branch: "marcello/feat/NIE-2008-gallery-wall-menu",
            pullRequest: PullRequest(number: 5576, status: .open, review: .approved,
                                     url: URL(string: "https://github.com")!, title: ""),
            prompt: SidebarDetailExample.samplePrompt(promptSource),
            tags: ["review"], note: "Wait for QA on staging before merge",
            backgroundTasks: [BackgroundTask(id: "sample", kind: .shell, title: "npm run dev")],
            usage: ContextUsage(model: "claude-opus-5-5", usedTokens: 120_000, windowTokens: 200_000))
    }
}

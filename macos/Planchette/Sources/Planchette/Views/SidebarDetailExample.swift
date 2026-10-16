import SwiftUI

/// What one sidebar detail looks like, for Settings → Project panel. Built from
/// the views the sidebar itself uses, fed with sample data, so the example is
/// the real thing and changes with it. Not interactive: a sample PR pill must
/// not open a browser.
struct SidebarDetailExample: View {
    @EnvironmentObject var appState: AppState
    let detail: SidebarDetail

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.t(.detailExample))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            sample
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var sample: some View {
        switch detail {
        case .path:
            Text("mp/designer-library")
                .font(.caption2).foregroundStyle(.secondary)
        case .branch:
            // Shortened the way the sidebar will shorten it: the example is
            // what the choice above it does, not a picture of one setting.
            BranchText(branch: "marcello/feat/NIE-2008-gallery-wall-menu",
                       trim: appState.sidebarDetails.branchTrim)
                .frame(maxWidth: 190, alignment: .leading)
        case .pullRequest:
            HStack(spacing: 4) {
                PullRequestPill(pr: Self.samplePR(.open, .approved, 5576))
                PullRequestPill(pr: Self.samplePR(.open, .changesRequested, 5581))
                PullRequestPill(pr: Self.samplePR(.merged, nil, 5579))
            }
        case .task:
            Text(Self.samplePrompt(appState.sidebarDetails.promptSource))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        case .age:
            WaitingTimeText(since: Date().addingTimeInterval(-4 * 60))
        case .tags:
            TagChips(tags: ["review", "wip"])
        case .note:
            NoteLine(note: "Wait for QA on staging before merge")
        case .snooze:
            SnoozeBadge(until: Date().addingTimeInterval(3600))
        case .attentionCounts:
            HStack(spacing: 4) {
                StateCountBadge(state: .waiting, count: 1)
                StateCountBadge(state: .ready, count: 2)
            }
        case .backgroundTasks:
            HStack(spacing: 8) {
                BackgroundTasksBadge(tasks: Self.sampleTasks(1))
                BackgroundTasksBadge(tasks: Self.sampleTasks(3))
                BackgroundTasksBadge(tasks: Self.sampleTasks(12))
            }
        case .model:
            ModelLabel(model: "claude-opus-5-5")
        case .contextUsage:
            HStack(spacing: 6) {
                ContextRing(usage: ContextUsage(model: "claude-opus-5-5",
                                                usedTokens: 40_000, windowTokens: 200_000))
                ContextRing(usage: ContextUsage(model: "claude-opus-5-5",
                                                usedTokens: 150_000, windowTokens: 200_000))
                ContextRing(usage: ContextUsage(model: "claude-opus-5-5",
                                                usedTokens: 188_000, windowTokens: 200_000))
            }
        case .cacheTimer:
            HStack(spacing: 8) {
                CacheTimer(expiresAt: Date().addingTimeInterval(42 * 60))
                CacheTimer(expiresAt: Date().addingTimeInterval(3 * 60))
                CacheTimer(expiresAt: Date().addingTimeInterval(-10 * 60))
            }
        }
    }

    /// The same terminal, said three ways — so the picker shows what it picks.
    private static func samplePrompt(_ source: PromptSource) -> String {
        switch source {
        case .firstPrompt: "Add a gallery wall to the designer"
        case .lastPrompt: "Fix preview proportions for the reland"
        case .agentTitle: "NIE-2008 gallery wall menu"
        }
    }

    private static func sampleTasks(_ count: Int) -> [BackgroundTask] {
        (1...count).map {
            BackgroundTask(id: "sample-\($0)", kind: $0 % 2 == 0 ? .agent : .shell,
                           title: $0 % 2 == 0 ? "Review the diff" : "npm run dev")
        }
    }

    private static func samplePR(_ status: PullRequest.Status, _ review: PullRequest.Review?,
                                 _ number: Int) -> PullRequest {
        PullRequest(number: number, status: status, review: review,
                    url: URL(string: "https://github.com")!, title: "")
    }
}

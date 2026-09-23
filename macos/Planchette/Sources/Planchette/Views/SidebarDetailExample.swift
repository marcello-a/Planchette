import SwiftUI

/// What one sidebar detail looks like, for Settings → Project panel. Built from
/// the views the sidebar itself uses, fed with sample data, so the example is
/// the real thing and changes with it. Not interactive: a sample PR pill must
/// not open a browser.
struct SidebarDetailExample: View {
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
            BranchText(branch: "marcello/feat/NIE-2008-gallery-wall-menu")
        case .pullRequest:
            HStack(spacing: 4) {
                PullRequestPill(pr: Self.samplePR(.open, .approved, 5576))
                PullRequestPill(pr: Self.samplePR(.open, .changesRequested, 5581))
                PullRequestPill(pr: Self.samplePR(.merged, nil, 5579))
            }
        case .task:
            Text("Fix preview proportions for the reland")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        case .age:
            WaitingTimeText(since: Date().addingTimeInterval(-4 * 60))
        case .tags:
            TagChips(tags: ["review", "wip"])
        case .note:
            NoteLine(note: "Wait for QA on staging before merge")
        case .finished:
            FinishedBadge(since: Date().addingTimeInterval(-2 * 3600))
        case .snooze:
            SnoozeBadge(until: Date().addingTimeInterval(3600))
        case .attentionCounts:
            HStack(spacing: 4) {
                StateCountBadge(state: .waiting, count: 1)
                StateCountBadge(state: .ready, count: 2)
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
        }
    }

    private static func samplePR(_ status: PullRequest.Status, _ review: PullRequest.Review?,
                                 _ number: Int) -> PullRequest {
        PullRequest(number: number, status: status, review: review,
                    url: URL(string: "https://github.com")!, title: "")
    }
}

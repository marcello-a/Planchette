import AppKit
import SwiftUI

/// The pull request of a branch, next to where the branch is named: a glyph for
/// its state, its number, and a second glyph for the review decision. The state
/// is said in words in the tooltip, never by colour alone. Clicking opens it.
struct PullRequestPill: View {
    let pr: PullRequest

    var body: some View {
        Button {
            NSWorkspace.shared.open(pr.url)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: Self.symbol(pr.status))
                    .font(.system(size: 8, weight: .semibold))
                Text(verbatim: "#\(pr.number)")
                    .font(.caption2.monospacedDigit())
                if let review = pr.review, let symbol = Self.symbol(review) {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private var tint: Color {
        switch pr.status {
        case .draft: .secondary
        case .open: pr.review == .changesRequested ? .orange : .green
        case .merged: .purple
        case .closed: .red
        }
    }

    static func symbol(_ status: PullRequest.Status) -> String {
        switch status {
        case .draft: "pencil"
        case .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark"
        }
    }

    static func symbol(_ review: PullRequest.Review) -> String? {
        switch review {
        case .approved: "checkmark"
        case .changesRequested: "exclamationmark"
        case .reviewRequired: nil   // the normal case of an open PR — no news
        }
    }

    static func label(_ status: PullRequest.Status) -> String {
        switch status {
        case .draft: L10n.t(.prDraft)
        case .open: L10n.t(.prOpen)
        case .merged: L10n.t(.prMerged)
        case .closed: L10n.t(.prClosed)
        }
    }

    static func label(_ review: PullRequest.Review) -> String {
        switch review {
        case .approved: L10n.t(.prApproved)
        case .changesRequested: L10n.t(.prChangesRequested)
        case .reviewRequired: L10n.t(.prReviewRequired)
        }
    }

    private var tooltip: String {
        var state = Self.label(pr.status)
        if let review = pr.review { state += " · " + Self.label(review) }
        return [L10n.t(.prTooltip, pr.number, state), pr.title, L10n.t(.prOpenHelp)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// "You closed this one": a check on a terminal whose work you marked finished.
struct FinishedBadge: View {
    let since: Date

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 10))
            .foregroundStyle(.green)
            .help(L10n.t(.finishedSince,
                         since.formatted(date: .abbreviated, time: .shortened)))
    }
}

/// The note you wrote on a terminal, one line, the whole text on hover.
struct NoteLine: View {
    let note: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "note.text")
                .font(.system(size: 9))
            Text(note)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.orange)
        .help(note)
    }
}

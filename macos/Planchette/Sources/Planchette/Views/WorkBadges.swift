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

/// The model a Claude terminal runs on, by its short name (`Opus 5.5`).
struct ModelLabel: View {
    let model: String

    var body: some View {
        Text(ModelName.short(model))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .help(model)
    }
}

/// How full a Claude terminal's context is: a ring that fills with the window.
/// It turns orange from 70 % and red from 90 % — the point where `/compact` (or
/// a fresh session) is due. The exact figures are on hover.
struct ContextRing: View {
    let usage: ContextUsage

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, usage.fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .help(L10n.t(.contextTooltip,
                     ModelName.short(usage.model),
                     ModelName.tokens(usage.usedTokens),
                     ModelName.tokens(usage.windowTokens),
                     usage.percent))
    }

    private var tint: Color {
        if usage.fraction >= ContextUsage.criticalFraction { return .red }
        if usage.fraction >= ContextUsage.warnFraction { return .orange }
        return .secondary
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

import SwiftUI

/// The attention inbox: everything that asks or finished, most urgent first.
struct InboxView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let queue = appState.attentionQueue
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t(.attention))
                .font(.headline)
                .padding(10)
            Divider()
            if queue.isEmpty {
                HStack {
                    Image(systemName: "moon.zzz")
                    Text(L10n.t(.allQuiet))
                }
                .foregroundStyle(.secondary)
                .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(queue) { session in
                            row(session)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
    }

    private func row(_ session: TerminalSession) -> some View {
        Button {
            appState.select(session: session)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: session.state.symbol)
                    .foregroundStyle(session.state.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.displayTitle).bold()
                        if appState.group(of: session)?.favorite == true {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                        Spacer()
                        WaitingTimeText(since: session.stateSince)
                    }
                    Text(session.state == .asking
                        ? (session.lastMessage ?? L10n.t(.waitingForAnswer))
                        : L10n.t(.doneSeeResult))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let summary = session.aiSummary {
                        Text("🔮 \(summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 4) {
                        Text(session.shortPath).font(.caption2).foregroundStyle(.tertiary)
                        TagChips(tags: session.tags)
                    }
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

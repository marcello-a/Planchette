import SwiftUI

/// Persistent right-hand notification sidebar: shows every session across all
/// projects with its status and timestamp, most urgent first. Click to jump.
/// Resizable via the enclosing HSplitView.
struct AttentionPanel: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("inboxOnlyActive") private var onlyActive = false

    private var rows: [TerminalSession] {
        let all = Array(appState.sessions.values)
        let filtered = onlyActive ? all.filter { $0.state != .ready } : all
        return filtered.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            return a.stateSince > b.stateSince
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t(.notificationsPanel)).font(.headline)
                Spacer()
                Toggle(L10n.t(.onlyActive), isOn: $onlyActive)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider()

            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz").font(.title2)
                    Text(L10n.t(.allQuiet)).font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { session in
                            row(session)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func row(_ session: TerminalSession) -> some View {
        Button {
            appState.select(session: session)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(session.state.tint)
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.displayTitle).fontWeight(.semibold).lineLimit(1)
                        if appState.group(of: session)?.favorite == true {
                            Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                        }
                        Spacer(minLength: 4)
                        Text(session.stateSince, style: .time)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    let detail = session.state == .waiting
                        ? (session.lastMessage ?? session.state.label)
                        : (session.aiSummary ?? session.state.label)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(appState.group(of: session)?.name ?? "")
                        Text("·"); Text(session.shortPath)
                        Spacer()
                        WaitingTimeText(since: session.stateSince)
                    }
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session.state.needsAttention {
                Button(L10n.t(.markReady)) { appState.markReady(session.id) }
            }
        }
    }
}

extension AttentionState {
    /// Sort priority for the notifications panel (lower = more urgent).
    var rank: Int {
        switch self {
        case .error: 0
        case .waiting: 1
        case .running: 2
        case .ready: 3
        }
    }
}

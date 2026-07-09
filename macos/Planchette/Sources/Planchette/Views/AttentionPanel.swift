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
        let group = appState.group(of: session)
        let folder = group?.name ?? (session.currentDirectory as NSString).lastPathComponent
        // What I'm working on: the git ticket, else the running program.
        let context = Titles.ticket(forDirectory: session.currentDirectory) ?? runningProgram(session)
        // What's happening / what the error is.
        let detail = session.state == .waiting
            ? (session.lastMessage ?? session.state.label)
            : (session.aiSummary ?? session.lastMessage ?? session.state.label)

        return Button {
            appState.select(session: session)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(session.state.tint)
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    // Folder name (small) + time.
                    HStack(spacing: 5) {
                        Text(folder)
                            .font(.caption).fontWeight(.medium)
                            .foregroundStyle(.secondary).lineLimit(1)
                        if group?.favorite == true {
                            Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                        }
                        Spacer(minLength: 4)
                        Text(session.stateSince, style: .time)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    // What the error / status is.
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.primary).lineLimit(2)
                    // Ticket / working context (bottom-left) + time-ago.
                    HStack(spacing: 6) {
                        if let context, !context.isEmpty {
                            Text(context)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(session.state.tint.opacity(0.16), in: Capsule())
                                .foregroundStyle(session.state.tint)
                        }
                        Spacer(minLength: 0)
                        WaitingTimeText(since: session.stateSince)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session.state.needsAttention {
                Button(L10n.t(.markReady)) { appState.markReady(session.id) }
            }
        }
    }

    /// The running program from the OSC title, stripped of any leading status
    /// glyph (Claude Code prefixes "✳ ", which reads as a stray dot).
    private func runningProgram(_ session: TerminalSession) -> String? {
        guard let osc = session.oscTitle else { return nil }
        let cleaned = String(osc.drop(while: { !$0.isLetter && !$0.isNumber }))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
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

import SwiftUI

/// What a project holds, as a page: every tab with its state, what it works on,
/// its branch and PR, and your note. Shown in the main area when the project row
/// itself is clicked in the sidebar — clicking a tab (here, in the sidebar or in
/// the tab bar) goes straight to that terminal.
struct ProjectOverviewView: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup

    private var tabs: [TerminalSession] { appState.sessions(in: group) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tabs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.largeTitle)
                    Text(L10n.t(.noTerminalsInGroup)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(tabs) { session in
                            OverviewTabRow(session: session,
                                           isActive: session.id == group.activeSessionID,
                                           showsDetails: true)
                                .background(Color.primary.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.secondary.opacity(0.18)))
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        let state = AttentionState.mostUrgent(of: tabs.map(\.state))
        return HStack(spacing: 8) {
            if let color = group.color.color {
                Circle().fill(color).frame(width: 11, height: 11)
            }
            Text(group.name).font(.title2.bold())
            if group.favorite {
                PixelIcon(sprite: PixelSprites.star, size: 13, tint: .yellow)
            }
            StateChip(state: state)
            DevServerChips(groupID: group.id)
            Spacer()
            Text(tabs.count == 1 ? L10n.t(.terminalCountOne) : L10n.t(.terminalsCount, tabs.count))
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(group.color.color?.opacity(0.12) ?? Color.clear)
    }
}

/// One tab of a project on an overview page — click lands on exactly this
/// terminal. The folder overview shows it compact; the project overview adds
/// the branch, the PR and the note (`showsDetails`).
struct OverviewTabRow: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    let isActive: Bool
    var showsDetails = false

    var body: some View {
        Button {
            appState.select(session: session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                StateIcon(state: session.state)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if let color = session.color.color {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(session.displayTitle)
                            .fontWeight(isActive ? .semibold : .regular)
                            .lineLimit(1)
                        Text(session.shortPath)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        TagChips(tags: session.tags)
                    }
                    if showsDetails, let branch = appState.branches[session.id] {
                        HStack(spacing: 4) {
                            BranchText(branch: branch)
                            if let pr = appState.pullRequests[session.id] {
                                PullRequestPill(pr: pr)
                            }
                        }
                    }
                    if let line = session.notificationLine {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if showsDetails, let note = session.note {
                        NoteLine(note: note)
                    }
                }
                Spacer(minLength: 4)
                if let finished = session.finishedAt {
                    FinishedBadge(since: finished)
                }
                if let until = appState.snoozeEnd(for: session), until > Date() {
                    SnoozeBadge(until: until)
                } else if session.state.needsAttention {
                    WaitingTimeText(since: session.stateSince)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
            // Same mark as the tab bar and the sidebar: the terminal this
            // project is showing, in the colour of what it is doing.
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? session.state.tint : .clear, lineWidth: 1.5)
                    .padding(.horizontal, 6).padding(.vertical, 3)
            )
            .opacity(session.isFinished ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .help(session.currentDirectory)
        .contextMenu {
            SessionAttentionMenu(session: session)
            Divider()
            TagMenu(session: session)
            Divider()
            Button(L10n.t(.rename)) { appState.promptRename(session: session) }
        }
    }
}

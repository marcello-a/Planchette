import SwiftUI

/// Persistent right-hand notification sidebar, mirroring the projects and
/// tabs structure: one section per project (same order as the sidebar), one
/// row per tab with its current state and notification. Click a row to jump
/// straight to that tab; click a project header to jump to the project.
/// Resizable via the enclosing HSplitView.
struct AttentionPanel: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("inboxOnlyActive") private var onlyActive = false
    let windowID: UUID

    /// Projects in display order: this window's groups first (favorites
    /// before normal, exactly like its sidebar), then the other windows'
    /// groups so nothing happening elsewhere is invisible.
    private var orderedGroups: [SessionGroup] {
        var ordered: [SessionGroup] = []
        let windows = appState.windows.sorted { a, _ in a.id == windowID }
        for window in windows {
            let groups = appState.groups(inWindow: window)
            ordered.append(contentsOf: groups.filter(\.favorite))
            ordered.append(contentsOf: groups.filter { !$0.favorite })
        }
        return ordered
    }

    /// The tabs shown for a project — tab order, optionally only active ones.
    private func visibleTabs(_ group: SessionGroup) -> [TerminalSession] {
        let tabs = appState.sessions(in: group)
        return onlyActive ? tabs.filter { $0.state != .ready } : tabs
    }

    var body: some View {
        let sections = orderedGroups
            .map { (group: $0, tabs: visibleTabs($0)) }
            .filter { !$0.tabs.isEmpty }

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

            if sections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz").font(.title2)
                    Text(L10n.t(.allQuiet)).font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections, id: \.group.id) { section in
                            projectHeader(section.group)
                            ForEach(section.tabs) { session in
                                tabRow(session)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: Project section header

    private func projectHeader(_ group: SessionGroup) -> some View {
        // Most urgent tab state colors the attention badge.
        let tabs = appState.sessions(in: group)
        let attention = tabs.filter { $0.state.needsAttention }
        let urgent = attention.min { $0.state.rank < $1.state.rank }?.state

        return Button {
            appState.select(group: group)
        } label: {
            HStack(spacing: 6) {
                if let color = group.color.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(group.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if group.favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8)).foregroundStyle(.yellow)
                }
                Spacer(minLength: 4)
                if let urgent {
                    StateCountBadge(state: urgent, count: attention.count)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tab row

    private func tabRow(_ session: TerminalSession) -> some View {
        // The tab's current notification (what's happening / what the error
        // is). Nil when there's no real message — the state chip below already
        // names the state, no need to repeat it.
        let detail = session.state == .waiting
            ? session.lastMessage
            : (session.aiSummary ?? session.lastMessage)

        return Button {
            appState.select(session: session)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(session.state.tint)
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.displayTitle)
                            .font(.subheadline).fontWeight(.medium)
                            .foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(session.stateSince, style: .time)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(session.state.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(session.state.tint.opacity(0.16), in: Capsule())
                            .foregroundStyle(session.state.tint)
                        Spacer(minLength: 0)
                        WaitingTimeText(since: session.stateSince)
                    }
                }
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session.state.needsAttention {
                Button(L10n.t(.markReady)) { appState.markReady(session.id) }
                Divider()
            }
            Button(L10n.t(.rename)) { appState.promptRename(session: session) }
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

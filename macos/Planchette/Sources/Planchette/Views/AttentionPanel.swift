import SwiftUI

/// Persistent right-hand notification sidebar, mirroring the projects and
/// tabs structure: one section per project (same order as the sidebar), one
/// row per tab with its current state and notification. Click a row to jump
/// straight to that tab; click a project header to jump to the project.
/// Resizable via the enclosing HSplitView.
struct AttentionPanel: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("inboxOnlyActive") private var onlyActive = false
    /// On by default: the panel's job is "what needs me", and a list that also
    /// holds everything already dealt with buries that. Unticking it shows the
    /// full mirror again, and the choice is remembered.
    @AppStorage("inboxOnlyUnread") private var onlyUnread = true
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

    /// The tabs shown for a project — tab order, narrowed by the two filters.
    /// "Only unread" is about what you have looked at, "only active" about what
    /// the terminal is doing; both can be on, and then both have to hold.
    private func visibleTabs(_ group: SessionGroup) -> [TerminalSession] {
        var tabs = appState.sessions(in: group)
        if onlyActive { tabs = tabs.filter(\.state.isActive) }
        if onlyUnread { tabs = tabs.filter { isUnread($0) } }
        return tabs
    }

    /// A terminal is unread while its last report — a question, an error, a
    /// finished turn — has not been looked at.
    private func isUnread(_ session: TerminalSession) -> Bool {
        !session.seen && session.state.isReport
    }

    var body: some View {
        let sections = orderedGroups
            .map { (group: $0, tabs: visibleTabs($0)) }
            .filter { !$0.tabs.isEmpty }

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.t(.notificationsPanel)).font(.headline)
                    // How much is unread, which is what the filter below acts on.
                    if appState.unreadCount > 0 {
                        Text("\(appState.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Button {
                        appState.markAllRead()
                    } label: {
                        Image(systemName: "envelope.open")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(appState.unreadCount == 0)
                    .help(L10n.t(.markAllRead))
                }
                HStack(spacing: 10) {
                    Toggle(L10n.t(.onlyUnread), isOn: $onlyUnread)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help(L10n.t(.onlyUnreadHelp))
                    Toggle(L10n.t(.onlyActive), isOn: $onlyActive)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Spacer()
                }
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
                        triageBlock
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

    // MARK: Triage — what needs me RIGHT NOW, across all projects

    /// Compact "Needs you" block above the project mirror: errors before
    /// questions, favorites first, longest-waiting on top (`attentionQueue`).
    @ViewBuilder
    private var triageBlock: some View {
        let queue = appState.attentionQueue
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(L10n.t(.needsYou).uppercased()) (\(queue.count))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8).padding(.bottom, 2)
                ForEach(queue) { session in
                    triageRow(session)
                }
            }
            .background(Color.primary.opacity(0.04))
            Divider()
        }
    }

    private func triageRow(_ session: TerminalSession) -> some View {
        Button {
            appState.select(session: session)
        } label: {
            HStack(spacing: 7) {
                Circle().fill(session.state.tint).frame(width: 8, height: 8)
                Text(session.displayTitle)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .layoutPriority(1)
                Text(session.lastMessage ?? session.currentTask ?? session.state.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                WaitingTimeText(since: session.stateSince)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hoverDetail(session))
    }

    // MARK: Project section header

    private func projectHeader(_ group: SessionGroup) -> some View {
        // Most urgent tab state colors the attention badge.
        let tabs = appState.sessions(in: group)
        // Snoozed tabs keep their color in the list but stop counting here —
        // the badge is "what is asking for you", and they aren't.
        let attention = tabs.filter { $0.state.needsAttention && !appState.isSnoozed($0) }
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
                if let until = group.snoozedUntil, until > Date() {
                    SnoozeBadge(until: until)
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
        .contextMenu { GroupAttentionMenu(group: group) }
    }

    // MARK: Tab row

    /// Full context for a hover tooltip: the whole question/error (rows clip
    /// it to 2 lines), the task it belongs to, and the path.
    private func hoverDetail(_ session: TerminalSession) -> String {
        var lines: [String] = []
        if let message = session.lastMessage { lines.append(message) }
        if let task = session.currentTask { lines.append("→ \(task)") }
        lines.append(session.currentDirectory)
        return lines.joined(separator: "\n\n")
    }

    private func tabRow(_ session: TerminalSession) -> some View {
        // The tab's current notification: for waiting the question itself; for
        // running/done what it works on / worked on — the submitted prompt
        // (currentTask), refined by the AI summary when available. Nil when
        // there's nothing real to say — the state chip already names the state.
        let detail = session.notificationLine

        let unread = isUnread(session)
        return Button {
            appState.select(session: session)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                // Unread is carried by the ring around the state dot and the
                // weight of the title, not by color alone — the dot's color is
                // already spoken for by the state.
                Circle().fill(session.state.tint)
                    .frame(width: 9, height: 9)
                    .overlay {
                        if unread {
                            Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                                .frame(width: 15, height: 15)
                        }
                    }
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.displayTitle)
                            .font(.subheadline).fontWeight(unread ? .bold : .medium)
                            .foregroundStyle(unread ? .primary : .secondary).lineLimit(1)
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
                        StateChip(state: session.state)
                        Spacer(minLength: 0)
                        if let until = appState.snoozeEnd(for: session), until > Date() {
                            SnoozeBadge(until: until)
                        } else {
                            WaitingTimeText(since: session.stateSince)
                        }
                    }
                }
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hoverDetail(session))
        .contextMenu {
            // Read/unread by hand, so a row can be kept for later without
            // opening it, or dismissed without opening it either.
            if unread {
                Button(L10n.t(.markRead)) { appState.markSeen(session.id) }
            } else if session.state.isReport {
                Button(L10n.t(.markUnread)) { appState.markUnread(session.id) }
            }
            Divider()
            SessionAttentionMenu(session: session)
            Divider()
            Button(L10n.t(.rename)) { appState.promptRename(session: session) }
        }
    }
}

import SwiftUI

/// What a project folder holds, as a page: one card per project with its state
/// badge and every one of its tabs, and below that the folder's latest
/// notifications. Shown in the main area when a folder is selected in the
/// sidebar — where an empty "no terminals" hint used to be.
///
/// Everything on it is a way in: a card header opens the project, a tab row
/// opens that exact tab, a feed entry jumps to the terminal that reported it.
struct FolderOverviewView: View {
    @EnvironmentObject var appState: AppState
    let folder: ProjectFolder
    let windowID: UUID

    private var projects: [SessionGroup] { appState.groups(inFolder: folder) }

    /// Every terminal in the folder, in project order.
    private var allSessions: [TerminalSession] {
        projects.flatMap { appState.sessions(in: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if projects.isEmpty {
                emptyHint
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(projects) { project in
                            projectCard(project)
                        }
                        activitySection
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(folder.color.color ?? .secondary)
            Text(folder.name).font(.title2.bold())
            Text(L10n.t(.arrangementSummary, projects.count, allSessions.count))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            attentionSummary
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(folder.color.color?.opacity(0.12) ?? Color.clear)
    }

    /// The same badge row the sidebar shows for this folder — snoozed terminals
    /// left out, since they are meant to be quiet.
    private var attentionSummary: some View {
        let sessions = allSessions.filter { !appState.isMuted($0) }
        let errors = sessions.filter { $0.state == .error }.count
        let waiting = sessions.filter { $0.state == .waiting }.count
        let done = sessions.filter { $0.state == .ready && !$0.seen }.count
        return HStack(spacing: 4) {
            if errors > 0 { StateCountBadge(state: .error, count: errors) }
            if waiting > 0 { StateCountBadge(state: .waiting, count: waiting) }
            if done > 0 { StateCountBadge(state: .ready, count: done) }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(.largeTitle)
            Text(L10n.t(.folderEmpty)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: One project

    private func projectCard(_ project: SessionGroup) -> some View {
        let tabs = appState.sessions(in: project)
        return VStack(alignment: .leading, spacing: 0) {
            projectHeader(project, tabs: tabs)
            if tabs.isEmpty {
                Text(L10n.t(.noTerminalsInGroup))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 9)
            } else {
                ForEach(tabs) { session in
                    Divider()
                    tabRow(session, isActive: session.id == project.activeSessionID)
                }
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(project.color.color?.opacity(0.5) ?? Color.secondary.opacity(0.18))
        )
    }

    /// Project name with the badge that says what it is doing — the most urgent
    /// state among its terminals, so an error is never hidden behind a green.
    private func projectHeader(_ project: SessionGroup, tabs: [TerminalSession]) -> some View {
        let state = AttentionState.mostUrgent(of: tabs.map(\.state))
        return Button {
            appState.select(group: project)
        } label: {
            HStack(spacing: 7) {
                if let color = project.color.color {
                    Circle().fill(color).frame(width: 9, height: 9)
                }
                Text(project.name).font(.headline)
                if project.favorite {
                    PixelIcon(sprite: PixelSprites.star, size: 11, tint: .yellow)
                }
                StateChip(state: state)
                if let until = project.snoozedUntil, until > Date() {
                    SnoozeBadge(until: until)
                }
                DevServerChips(groupID: project.id)
                Spacer(minLength: 4)
                Text(tabs.count == 1 ? L10n.t(.terminalCountOne) : L10n.t(.terminalsCount, tabs.count))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(.openProjectHelp))
        .contextMenu { GroupAttentionMenu(group: project) }
    }

    /// One tab of a project — click lands on exactly this terminal.
    private func tabRow(_ session: TerminalSession, isActive: Bool) -> some View {
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
                    if let line = session.notificationLine {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
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

    // MARK: Latest notifications

    /// What this folder reported last, newest first — across all its projects.
    /// Snoozed terminals stay out: they were sent away on purpose.
    @ViewBuilder
    private var activitySection: some View {
        let entries = ActivityFeed.entries(allSessions.filter { !appState.isMuted($0) })
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t(.latestNotifications).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            if entries.isEmpty {
                Text(L10n.t(.nothingReported))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { session in
                    activityRow(session)
                }
            }
        }
        .padding(.top, 2)
    }

    private func activityRow(_ session: TerminalSession) -> some View {
        Button {
            appState.select(session: session)
        } label: {
            HStack(spacing: 7) {
                StateIcon(state: session.state, size: 12)
                Text(appState.group(of: session)?.name ?? session.displayTitle)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .layoutPriority(1)
                Text(session.displayTitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(1)
                Text(session.notificationLine ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(session.stateSince, style: .time)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.notificationLine ?? session.currentDirectory)
    }
}

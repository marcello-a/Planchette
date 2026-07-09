import SwiftUI

/// Main area for the selected group: tab bar + one terminal, or a cluster
/// grid showing all of the group's terminals at once.
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup

    var body: some View {
        let sessions = appState.sessions(in: group)
        VStack(spacing: 0) {
            header(sessions: sessions)
            Divider()
            switch group.viewMode {
            case .tabs:
                if let active = activeSession(sessions) {
                    TerminalHostView(session: active)
                        .id(active.id)
                } else {
                    emptyHint
                }
            case .cluster:
                if sessions.isEmpty {
                    emptyHint
                } else {
                    ClusterView(group: group)
                }
            }
        }
    }

    private func activeSession(_ sessions: [TerminalSession]) -> TerminalSession? {
        if let id = group.activeSessionID, let session = appState.sessions[id] { return session }
        return sessions.first
    }

    private func header(sessions: [TerminalSession]) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessions) { session in
                        tab(session, isActive: session.id == activeSession(sessions)?.id)
                    }
                    // Add a terminal in this project's folder.
                    Button {
                        appState.addTerminalToGroup(group.id)
                    } label: {
                        Image(systemName: "plus")
                            .padding(.horizontal, 6).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t(.addTerminalHelp))
                }
                .padding(.horizontal, 8)
            }
            Spacer()
            Picker("", selection: viewModeBinding) {
                Image(systemName: "rectangle").tag(GroupViewMode.tabs)
                Image(systemName: "square.grid.2x2").tag(GroupViewMode.cluster)
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
            .padding(.trailing, 8)
        }
        .padding(.vertical, 5)
        .background(group.color.color?.opacity(0.12) ?? Color.clear)
    }

    private var viewModeBinding: Binding<GroupViewMode> {
        Binding(
            get: { group.viewMode },
            set: { mode in appState.updateGroup(group.id) { $0.viewMode = mode } }
        )
    }

    private func tab(_ session: TerminalSession, isActive: Bool) -> some View {
        Button {
            appState.updateGroup(group.id) { $0.activeSessionID = session.id }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: session.state.symbol)
                    .foregroundStyle(session.state.tint)
                    .font(.caption)
                if let color = session.color.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(session.displayTitle)
                Text(session.shortPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TagChips(tags: session.tags)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .help(session.aiSummary.map { "\(session.currentDirectory)\n🔮 \($0)" } ?? session.currentDirectory)
        .contextMenu {
            TagMenu(session: session)
            Divider()
            Button(L10n.t(.close), role: .destructive) { appState.closeSession(session.id) }
                .help(L10n.t(.closeHelp))
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "ghost").font(.largeTitle)
            Text(L10n.t(.noTerminalsInGroup))
            Text(L10n.t(.newTerminalHint)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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
            // Dev servers running in this checkout — the link is always here.
            DevServerChips(groupID: group.id)
                .padding(.trailing, 6)
            // Hand the project to an IDE.
            IDEButton(group: group)
                .padding(.trailing, 6)
            // Font size lives in the terminal's own right-click menu, next to
            // copy and paste: it belongs to the text you are looking at, and
            // three permanent buttons for something you touch twice a month
            // crowded the row that has to carry the dev-server links.
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
                StateIcon(state: session.state, size: 13)
                if let color = session.color.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(session.displayTitle)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                Text(session.shortPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TagChips(tags: session.tags)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            // The tab you are in, outlined in what that terminal is doing —
            // on the tab, not around the terminal: a frame drawn around the
            // content boxes in the text you are reading.
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isActive ? session.state.tint : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        // Drag a tab onto another to reorder terminals within the project.
        .onDrag {
            NSItemProvider(object: session.id.uuidString as NSString)
        } preview: {
            Text(session.displayTitle).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .onDrop(of: [.plainText, .text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            let targetID = session.id
            let groupID = group.id
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let str = obj as? String, let dragged = UUID(uuidString: str) else { return }
                DispatchQueue.main.async {
                    appState.reorderSession(dragged, before: targetID, groupID: groupID)
                }
            }
            return true
        }
        .help(session.aiSummary.map { "\(session.currentDirectory)\n🔮 \($0)" } ?? session.currentDirectory)
        .contextMenu {
            Button(L10n.t(.rename)) { appState.promptRename(session: session) }
            Divider()
            SessionAttentionMenu(session: session)
            Divider()
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

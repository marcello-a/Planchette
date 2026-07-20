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
            // Font zoom for the active terminal.
            HStack(spacing: 1) {
                Button { fontZoom(sessions, .decrease) } label: {
                    Image(systemName: "textformat.size.smaller").padding(.horizontal, 4).padding(.vertical, 3)
                }
                .help(L10n.t(.fontSmaller))
                Button { fontZoom(sessions, .reset) } label: {
                    Image(systemName: "textformat.size").padding(.horizontal, 4).padding(.vertical, 3)
                }
                .help(L10n.t(.fontReset))
                Button { fontZoom(sessions, .increase) } label: {
                    Image(systemName: "textformat.size.larger").padding(.horizontal, 4).padding(.vertical, 3)
                }
                .help(L10n.t(.fontLarger))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 6)

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

    private enum FontZoom { case increase, decrease, reset }

    /// Zoom the font of the group's active terminal (the focused pane).
    private func fontZoom(_ sessions: [TerminalSession], _ action: FontZoom) {
        guard let active = activeSession(sessions),
              let view = TerminalRegistry.shared.existingView(active.id) else { return }
        switch action {
        case .increase: view.increaseFontSize()
        case .decrease: view.decreaseFontSize()
        case .reset: view.resetFontSize()
        }
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
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
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

import SwiftUI

/// Main area for the selected group: tab bar + one terminal, or a cluster
/// grid showing all of the group's terminals at once.
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup
    /// The tab the user just clicked: it is under their pointer already, so the strip
    /// must not slide it somewhere else to make it visible.
    @State private var clickedTab: UUID?

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
            // The tabs and the +, which take whatever the controls on the right leave.
            HStack(spacing: 4) {
                tabStrip(sessions, activeID: activeSession(sessions)?.id)
                // Add a terminal in this project's folder. Outside the scrolling
                // strip, so it is in reach however many tabs there are.
                Button {
                    appState.addTerminalToGroup(group.id)
                } label: {
                    Image(systemName: "plus")
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help(L10n.t(.addTerminalHelp))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(ProjectGradient(color: group.color, look: appState.projectColor))
    }

    /// The tabs as a plain row while they fit, and a strip that scrolls once they
    /// do not: with a wheel, a swipe, or — to keep the one you are in on screen —
    /// by itself when the active tab changes.
    @ViewBuilder
    private func tabStrip(_ sessions: [TerminalSession], activeID: UUID?) -> some View {
        let row = HStack(spacing: 4) {
            ForEach(sessions) { session in
                tab(session, isActive: session.id == activeID).id(session.id)
            }
        }
        .padding(.horizontal, 8)
        ViewThatFits(in: .horizontal) {
            row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row.background(WheelToHorizontalScroll())
                }
                .onAppear { reveal(activeID, with: proxy, animated: false) }
                .onChange(of: activeID) { _, id in
                    // A click keeps the tab where it is; a shortcut, the search or a new
                    // terminal brings the tab into view.
                    let byClick = id == clickedTab
                    clickedTab = nil
                    if !byClick { reveal(id, with: proxy, animated: true) }
                }
                .onChange(of: sessions.count) { _, _ in reveal(activeID, with: proxy, animated: true) }
                // The strip's width settles after the first frame, and changes when a
                // panel is dragged: the tab you are in stays on screen through both.
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width) { _, _ in
                        reveal(activeID, with: proxy, animated: false)
                    }
                })
            }
        }
    }

    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy, animated: Bool) {
        guard let id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
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
            clickedTab = session.id
            appState.updateGroup(group.id) { $0.activeSessionID = session.id }
        } label: {
            HStack(spacing: 5) {
                StateIcon(state: session.state, size: 13)
                if let color = session.color.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(appState.tabName(for: session))
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                if appState.tabLayout.showsPath {
                    Text(session.shortPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if appState.tabLayout.showsBranch, let branch = appState.branches[session.id] {
                    BranchText(branch: branch, trim: appState.sidebarDetails.branchTrim)
                        .frame(maxWidth: 140, alignment: .leading)
                }
                if appState.tabLayout.showsTags {
                    TagChips(tags: session.tags)
                }
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
            Text(appState.tabName(for: session)).lineLimit(1)
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

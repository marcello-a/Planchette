import SwiftUI

/// Main area for the selected group: the tab bar, and the tab in front — one terminal, or a
/// split of several (see `TabStrip`).
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup
    /// The tab the user just clicked: it is under their pointer already, so the strip
    /// must not slide it somewhere else to make it visible.
    @State private var clickedTab: UUID?
    /// The tab a drag is over, which gets a marker on its left edge: the drag lands before it.
    @State private var dropBefore: UUID?
    /// A drag is over the free space after the last tab.
    @State private var dropAtEnd = false
    /// The width of the notepad while its handle is being dragged (nil when it is not).
    @State private var padWidth: Double?

    var body: some View {
        let strip = appState.tabs(of: group)
        let current = appState.currentTab(of: group)
        VStack(spacing: 0) {
            header(strip: strip, current: current)
            Divider()
            if let current {
                tabWithNotepad(current)
            } else {
                emptyHint
            }
        }
    }

    /// The tab in front, and — when the notepad is open — the notepad of the terminal that has the
    /// keyboard at its right, behind a handle that changes its width.
    @ViewBuilder
    private func tabWithNotepad(_ tab: SplitLayout) -> some View {
        if appState.notepad.isOpen,
           let id = appState.paneToFocus(in: tab, groupID: group.id),
           let session = appState.sessions[id] {
            GeometryReader { geometry in
                let width = padWidth ?? NotepadLook.clamped(width: appState.notepad.width, in: geometry.size.width)
                HStack(spacing: 0) {
                    SplitTabView(tab: tab, group: group)
                    NotepadResizeHandle(live: $padWidth, available: geometry.size.width)
                    NotepadPanel(session: session, text: appState.notepadText(for: id))
                        // One pad per terminal: another terminal is a new panel, with its own state.
                        .id(session.id)
                        .frame(width: width)
                }
            }
        } else {
            SplitTabView(tab: tab, group: group)
        }
    }

    /// A tab is named by its first terminal.
    private func key(_ tab: SplitLayout) -> UUID? { tab.leaves.first }

    private func header(strip: [SplitLayout], current: SplitLayout?) -> some View {
        HStack(spacing: 4) {
            // The tabs and the +, which take whatever the controls on the right leave.
            HStack(spacing: 4) {
                tabStrip(strip, current: current)
                // Add a terminal in this project's folder. Outside the scrolling
                // strip, so it is in reach however many tabs there are.
                Button {
                    appState.addTerminalToGroup(group.id)
                } label: {
                    Image(systemName: "plus")
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t(.addTerminalHelp))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Dev servers running in this checkout — the link is always here.
            DevServerChips(groupID: group.id)
                .padding(.trailing, 6)
            // The way a tab splits and comes apart: new terminal beside the one you are in,
            // and every tab in one view or every pane in its own tab.
            // Font size lives in the terminal's own right-click menu, next to
            // copy and paste: it belongs to the text you are looking at.
            splitControls(strip)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 5)
        .background(ProjectGradient(color: group.color, look: appState.projectColor))
    }

    private func splitControls(_ strip: [SplitLayout]) -> some View {
        HStack(spacing: 2) {
            splitButton("rectangle.split.2x1", help: .splitRightHelp, label: .splitRight) {
                appState.splitTerminal(in: group.id, edge: .right)
            }
            splitButton("rectangle.split.1x2", help: .splitDownHelp, label: .splitDown) {
                appState.splitTerminal(in: group.id, edge: .bottom)
            }
            Divider().frame(height: 14).padding(.horizontal, 3)
            splitButton("square.grid.2x2", help: .combineTabsHelp, label: .combineTabs) {
                appState.combineTabs(groupID: group.id)
            }
            .disabled(strip.count < 2)
            splitButton("rectangle.stack", help: .separateTabsHelp, label: .separateTabs) {
                appState.separateTabs(groupID: group.id)
            }
            .disabled(!strip.contains { $0.leaves.count > 1 })
            Divider().frame(height: 14).padding(.horizontal, 3)
            splitButton("note.text", help: .notepadHelp, label: .notepad) {
                appState.toggleNotepad()
            }
            .foregroundStyle(appState.notepad.isOpen ? Color.accentColor : Color.primary)
        }
    }

    private func splitButton(
        _ symbol: String, help: LKey, label: LKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(label))
    }

    /// The tabs as a plain row while they fit, and a strip that scrolls once they
    /// do not: with a wheel, a swipe, or — to keep the one you are in on screen —
    /// by itself when the active tab changes.
    @ViewBuilder
    private func tabStrip(_ strip: [SplitLayout], current: SplitLayout?) -> some View {
        let activeKey = current.flatMap(key)
        let row = HStack(spacing: 4) {
            ForEach(Array(strip.enumerated()), id: \.element.stableID) { index, tab in
                tabItem(tab, at: index, in: strip, isCurrent: tab == current)
                    .id(key(tab))
            }
            // The free space after the last tab: a drag that lands here goes to the end.
            Color.clear
                .frame(width: 28, height: 24)
                .overlay(alignment: .leading) { insertionMarker(dropAtEnd) }
                .onDrop(of: [TabDragType.utType], isTargeted: $dropAtEnd) { providers in
                    drop(providers, before: nil)
                }
        }
        .padding(.horizontal, 8)
        ViewThatFits(in: .horizontal) {
            row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row.background(WheelToHorizontalScroll())
                }
                .onAppear { reveal(activeKey, with: proxy, animated: false) }
                .onChange(of: activeKey) { _, id in
                    // A click keeps the tab where it is; a shortcut, the search or a new
                    // terminal brings the tab into view.
                    let byClick = id == clickedTab
                    clickedTab = nil
                    if !byClick { reveal(id, with: proxy, animated: true) }
                }
                .onChange(of: strip.count) { _, _ in reveal(activeKey, with: proxy, animated: true) }
                // The strip's width settles after the first frame, and changes when a
                // panel is dragged: the tab you are in stays on screen through both.
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width) { _, _ in
                        reveal(activeKey, with: proxy, animated: false)
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

    /// A line where a dragged tab or pane will stand.
    @ViewBuilder
    private func insertionMarker(_ shown: Bool) -> some View {
        if shown {
            Capsule().fill(Color.accentColor).frame(width: 3, height: 20)
        }
    }

    /// A drop on the tab bar: a tab moves there, a pane leaves its tab and becomes one. `before`
    /// is the tab it lands before, nil for the end.
    private func drop(_ providers: [NSItemProvider], before target: UUID?) -> Bool {
        let groupID = group.id, state = appState
        return TabDragType.load(from: providers) { item in
            state.draggingTabItem = nil
            switch item {
            case .tab(let tab): state.moveTab(tab, before: target, groupID: groupID)
            case .pane(let pane): state.extractPane(pane, before: target, groupID: groupID)
            }
        }
    }

    private func tabItem(_ tab: SplitLayout, at index: Int, in strip: [SplitLayout], isCurrent: Bool) -> some View {
        let sessions = tab.leaves.compactMap { appState.sessions[$0] }
        // The terminal that speaks for the tab, whose name the tab carries: the tab's own, not the
        // one that has the keyboard — moving a terminal into the tab must not rename it.
        let speaker = appState.speaker(of: tab, in: group) ?? sessions.first
        // The one a click brings the keyboard to: where it was in that tab last.
        let landing = appState.paneToFocus(in: tab, groupID: group.id).flatMap { appState.sessions[$0] }
            ?? speaker
        let tabKey = key(tab)
        return Group {
            if let session = speaker {
                tabBody(tab, sessions: sessions, session: session, isCurrent: isCurrent)
                    .overlay(alignment: .leading) { insertionMarker(dropBefore == tabKey) }
                    .onTapGesture {
                        clickedTab = tabKey
                        appState.select(session: landing ?? session)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isButton)
                    // Drag a tab onto another to reorder, or onto a terminal to split it.
                    .onDrag {
                        let item = TabDragItem.tab(tab.leaves[0])
                        appState.draggingTabItem = item
                        return TabDragType.provider(for: item)
                    } preview: {
                        DragPreview(title: appState.tabName(for: session), symbol: "rectangle.split.2x1")
                    }
                    .onDrop(of: [TabDragType.utType], isTargeted: Binding(
                        get: { dropBefore == tabKey },
                        set: { targeted in
                            if targeted { dropBefore = tabKey } else if dropBefore == tabKey { dropBefore = nil }
                        })
                    ) { providers in
                        drop(providers, before: tabKey)
                    }
                    .help(session.aiSummary.map { "\(session.currentDirectory)\n🔮 \($0)" }
                          ?? session.currentDirectory)
                    .contextMenu {
                        Button(L10n.t(.rename)) { appState.promptRename(session: session) }
                        Divider()
                        SessionAttentionMenu(session: session)
                        Divider()
                        // Hand the project to an IDE: it left the header, which the dev-server
                        // links need, and it belongs to the project the tab is in.
                        IDEMenuItems(group: group)
                        Divider()
                        TagMenu(session: session)
                        Divider()
                        closeMenu(at: index, in: strip, session: session)
                    }
            }
        }
    }

    private func tabBody(
        _ tab: SplitLayout, sessions: [TerminalSession], session: TerminalSession, isCurrent: Bool
    ) -> some View {
        // A tab with several panes shows what the most urgent of them is doing: a question in
        // a pane you cannot see must not hide behind the calm one you can.
        let state = AttentionState.mostUrgent(of: sessions.map(\.state))
        return HStack(spacing: 5) {
            StateIcon(
                state: state, size: 13,
                inBackground: sessions.contains { appState.runsInBackground($0) })
            if let color = session.color.color {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(appState.tabName(for: session))
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
            if sessions.count > 1 {
                Label("\(sessions.count)", systemImage: "rectangle.split.2x1")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
            // At the end of the tab, as in every tabbed app. It asks first: closing ends
            // the terminals' sessions, and a tab is too easy to hit while aiming at its name.
            Button {
                TabCloser.confirmAndClose(
                    tab.leaves, title: L10n.t(.closeTabAlertTitle, appState.tabName(for: session)),
                    appState: appState)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(.closeTabHelp))
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Clear padding and the gaps between the icon, the name and the chips do not take
        // a click unless the tab says its whole shape is hit.
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .background(
            isCurrent ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        // The tab you are in, outlined in what that terminal is doing —
        // on the tab, not around the terminal: a frame drawn around the
        // content boxes in the text you are reading.
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isCurrent ? state.tint : .clear, lineWidth: 2)
        )
    }

    /// Three separate items, so "close the ones to my left" never takes the tab itself.
    /// Each asks first, like the button on the tab.
    @ViewBuilder
    private func closeMenu(at index: Int, in strip: [SplitLayout], session: TerminalSession) -> some View {
        let tabs = strip.map(\.leaves)
        ForEach([TabCloseScope.left, .this, .right], id: \.self) { scope in
            let ids = TabClosing.terminals(scope, at: index, in: tabs)
            let count = TabClosing.tabCount(scope, at: index, in: tabs)
            Button(L10n.t(Self.closeLabel[scope] ?? .close), role: .destructive) {
                TabCloser.confirmAndClose(
                    ids,
                    title: scope == .this
                        ? L10n.t(.closeTabAlertTitle, appState.tabName(for: session))
                        : L10n.t(.closeTabsAlertTitle, count),
                    appState: appState)
            }
            .disabled(ids.isEmpty)
        }
    }

    private static let closeLabel: [TabCloseScope: LKey] = [
        .left: .closeTabsToLeft, .this: .closeThisTab, .right: .closeTabsToRight,
    ]

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "ghost").font(.largeTitle)
            Text(L10n.t(.noTerminalsInGroup))
            Text(L10n.t(.newTerminalHint)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Closing from a tab: always asked first, because it ends the terminals' sessions.
@MainActor
enum TabCloser {
    /// Ask, then close the terminals. `ids` is every terminal the tabs hold; the body
    /// names how many that is.
    static func confirmAndClose(_ ids: [UUID], title: String, appState: AppState) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = L10n.t(.closeTabAlertBody, ids.count)
        alert.addButton(withTitle: L10n.t(.close))
        alert.addButton(withTitle: L10n.t(.cancel))
        // From a button's action: see `ModalAlert` for why it is not `runModal()`.
        Task { @MainActor in
            guard await ModalAlert.run(alert) == .alertFirstButtonReturn else { return }
            for id in ids { appState.closeSession(id) }
        }
    }
}

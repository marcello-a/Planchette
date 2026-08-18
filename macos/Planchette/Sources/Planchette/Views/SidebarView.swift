import SwiftUI
import UniformTypeIdentifiers

/// What a sidebar project drag carries: the ids of the projects being moved —
/// several of them when a multi-selection is dragged, so the whole batch is one
/// drag and one move.
///
/// Exported as plain text rather than a custom UTI: a custom type would have to
/// be declared in Info.plist to survive a real drag session, and the payload is
/// just ids. Text from elsewhere yields no valid UUIDs, so it is a no-op.
struct ProjectDragPayload: Transferable {
    let ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { (payload: ProjectDragPayload) in
                payload.ids.map(\.uuidString).joined(separator: "\n")
            },
            importing: { (text: String) in
                ProjectDragPayload(
                    ids: text.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
            })
    }
}

/// Drop handling for one project row. `dropDestination` only reports whether a
/// drag is over a view, never where — and "where" is the whole point of dropping
/// a project into a list: above this row or below it. `DropDelegate` reports the
/// live location, which is what lets the insertion line follow the pointer and a
/// project land exactly in the gap you aimed at, in any folder.
private struct ProjectDropDelegate: DropDelegate {
    let rowID: UUID
    /// Row height, read from the row itself — the midpoint decides the gap.
    let height: () -> CGFloat
    let slot: (SidebarView.DropSlot?) -> Void
    let perform: (_ ids: [UUID], _ below: Bool) -> Void

    private func below(_ info: DropInfo) -> Bool {
        info.location.y > height() / 2
    }

    func dropEntered(info: DropInfo) {
        slot(SidebarView.DropSlot(rowID: rowID, below: below(info)))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        slot(SidebarView.DropSlot(rowID: rowID, below: below(info)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        slot(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let landsBelow = below(info)
        let providers = info.itemProviders(for: [.plainText, .utf8PlainText, .text])
        guard let provider = providers.first else { slot(nil); return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let ids = text.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async { perform(ids, landsBelow) }
        }
        return true
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarMinified") private var minified = false
    let windowID: UUID
    @State private var isDropTargeted = false
    @State private var hoveredGroup: UUID?
    /// Folder row under the pointer — it shows a "+" while hovered.
    @State private var hoveredFolder: UUID?
    /// Projects picked with ⌘/⇧-click, to act on together. Ephemeral by design —
    /// a batch is something you assemble, use and forget, not workspace state.
    @State private var multiSelection: Set<UUID> = []
    /// Row currently under the drag (folder id or project id).
    @State private var dropTarget: UUID?
    /// Which gap a project drag would land in, updated as the pointer moves.
    @State private var dropSlot: DropSlot?
    /// Row heights, so a drop knows which half of a row the pointer is in.
    @State private var rowHeights: [UUID: CGFloat] = [:]
    /// Projects whose terminal list is folded away. Ephemeral, like the
    /// multi-selection: a folder's state is worth persisting, a project you
    /// closed for a minute is not. Absent = expanded, which is the default the
    /// sidebar always had.
    @State private var collapsedGroups: Set<UUID> = []

    /// The List's selection. One row selected means "show me this" — a project
    /// in the terminal area, a folder as its overview page. Several means a
    /// batch, and switching the main area to whatever was clicked last would
    /// just be noise.
    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: {
                if multiSelection.count > 1 { return multiSelection }
                guard let window = appState.window(for: windowID) else { return [] }
                if let folderID = window.selectedFolderID { return [folderID] }
                if let id = window.selectedGroupID { return [id] }
                return []
            },
            set: { newValue in
                multiSelection = newValue
                guard newValue.count == 1, let id = newValue.first else { return }
                let isFolder = appState.window(for: windowID)?.folders.contains { $0.id == id } ?? false
                if isFolder {
                    appState.select(folder: id, inWindow: windowID)
                } else {
                    appState.updateWindow(windowID) { $0.selectGroup(id) }
                }
            }
        )
    }

    /// The projects a menu or a drag started on `group` should act on: the whole
    /// multi-selection when `group` is part of it, otherwise just `group`.
    private func actionTargets(_ group: SessionGroup) -> [UUID] {
        guard multiSelection.count > 1, multiSelection.contains(group.id) else { return [group.id] }
        // In sidebar order, so a batch keeps the order you see.
        let ordered = appState.window(for: windowID)?.groupIDs ?? []
        return ordered.filter { multiSelection.contains($0) }
    }

    var body: some View {
        let windowGroups = appState.window(for: windowID).map { appState.groups(inWindow: $0) } ?? []
        VStack(spacing: 0) {
            if minified {
                minifiedRail(windowGroups)
                    .transition(.opacity)
            } else {
                // Header sits in the body (below the toolbar), mirroring the
                // Notifications panel on the right — same font and insets.
                projectsHeader
                Divider()
                fullList(windowGroups)
                    .transition(.opacity)
            }
            SidebarBottomBar(windowID: windowID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .animation(.easeInOut(duration: 0.25), value: minified)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: Header

    /// Matches AttentionPanel's header (font + 12/10/6 insets) so the left and
    /// right panels line up exactly.
    private var projectsHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.t(.projects)).font(.headline)
            Button {
                appState.promptNewProject(inWindow: windowID)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t(.newProjectHelp))
            Button {
                appState.promptNewFolder(inWindow: windowID)
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t(.newFolderHelp))
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.25)) { minified = true } } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t(.minifySidebar))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Full list

    @ViewBuilder
    private func fullList(_ windowGroups: [SessionGroup]) -> some View {
        // Folders first, then the projects that are in none — those keep the
        // familiar favorites-before-the-rest order.
        let folders = appState.window(for: windowID)?.folders ?? []
        let loose = looseGroups(windowGroups)
        let favorites = loose.filter(\.favorite)
        let normal = loose.filter { !$0.favorite }
        List(selection: selectionBinding) {
            ForEach(folders) { folder in folderSection(folder) }
            ForEach(favorites) { group in projectRows(group, siblings: loose) }
                .onMove { moveGroups(favorites, other: normal, favoritesSection: true, from: $0, to: $1) }
            ForEach(normal) { group in projectRows(group, siblings: loose) }
                .onMove { moveGroups(normal, other: favorites, favoritesSection: false, from: $0, to: $1) }
            // The way back out of a folder. Shown whenever there is a folder to
            // come out of — a target that appears only mid-drag is a target you
            // have to discover by accident, and one that hides again on a
            // cancelled drag would have to be un-stuck by hand.
            if !folders.isEmpty {
                looseDropZone
            }
        }
        .listStyle(.sidebar)
        // Drop the translucent sidebar material so the panel is the same solid
        // background as the terminal and the Notifications panel.
        .scrollContentBackground(.hidden)
        .background(.background)
        .overlay {
            // Centered empty state — can't clip like an inset list row.
            if windowGroups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(L10n.t(.noProjectsYet))
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(
                        Label(L10n.t(.dropHint), systemImage: "folder.badge.plus")
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    )
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Dragging projects between folders

    private func dragPreview(for group: SessionGroup) -> some View {
        let ids = actionTargets(group)
        return Label(
            ids.count > 1 ? L10n.t(.selectedProjects, ids.count) : group.name,
            systemImage: ids.count > 1 ? "square.stack" : "folder")
            .padding(.horizontal, 8).padding(.vertical, 4)
    }

    /// Accept a project drag. `folderID` nil means the top level; `before` the
    /// row it was dropped on (the model rejects a drop on the dragged rows).
    @discardableResult
    private func acceptProjectDrop(_ payloads: [ProjectDragPayload],
                                   toFolder folderID: UUID?, before: UUID?) -> Bool {
        let ids = payloads.flatMap(\.ids)
        guard !ids.isEmpty else { return false }
        appState.moveGroups(ids, toFolder: folderID, before: before, inWindow: windowID)
        dropTarget = nil
        return true
    }

    /// Highlight for the row a drag is hovering over.
    private func dropHighlight(_ id: UUID) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.accentColor, lineWidth: dropTarget == id ? 2 : 0)
    }

    /// Where a project would land: which row the pointer is over, and whether it
    /// would go above or below it. Tracked live, so the insertion line moves with
    /// the pointer instead of the drop being a guess you only see afterwards.
    struct DropSlot: Equatable {
        let rowID: UUID
        let below: Bool
    }

    /// Insert a dragged batch next to `target`. `below` picks the gap under the
    /// row rather than the one above it, which is the only way to reach the last
    /// place in a folder — and the reason dropping is positional at all.
    private func dropNext(to target: SessionGroup, below: Bool,
                          ids: [UUID], siblings: [SessionGroup]) {
        let folderID = appState.window(for: windowID)?.folder(of: target.id)?.id
        // Landing "below X" is the same move as "before whatever follows X";
        // nothing following means the end of that list.
        var before: UUID? = target.id
        if below {
            let rest = siblings.drop { $0.id != target.id }.dropFirst()
            before = rest.first { !ids.contains($0.id) }?.id
        }
        appState.moveGroups(ids, toFolder: folderID, before: before, inWindow: windowID)
        dropSlot = nil
        dropTarget = nil
    }

    /// The line drawn in the gap a drop would land in.
    @ViewBuilder
    private func insertionLine(_ group: SessionGroup) -> some View {
        if let slot = dropSlot, slot.rowID == group.id {
            VStack(spacing: 0) {
                if !slot.below { line } else { Spacer(minLength: 0) }
                if slot.below { line } else { Spacer(minLength: 0) }
            }
        }
    }

    private var line: some View {
        Capsule().fill(Color.accentColor).frame(height: 2)
    }

    /// Drop a project here to take it out of its folder. Deliberately quiet
    /// until a drag is actually over it.
    private var looseDropZone: some View {
        let active = dropTarget == Self.looseZoneID
        return HStack(spacing: 6) {
            Image(systemName: "tray").font(.caption2)
            Text(L10n.t(.noFolder)).font(.caption2)
            Spacer()
        }
        .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.55))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    active ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: [3]))
        )
        .dropDestination(for: ProjectDragPayload.self) { payloads, _ in
            acceptProjectDrop(payloads, toFolder: nil, before: nil)
        } isTargeted: { setDropTarget(Self.looseZoneID, over: $0) }
    }

    /// Stable id for the "no folder" zone — it is a drop target, not a project.
    private static let looseZoneID = UUID(uuidString: "00000000-0000-0000-0000-00000000d403")!

    /// Track which row a drag is over, for the highlight.
    private func setDropTarget(_ id: UUID, over: Bool) {
        if over { dropTarget = id } else if dropTarget == id { dropTarget = nil }
    }

    /// The window's projects that sit in no folder, in the window's order.
    private func looseGroups(_ windowGroups: [SessionGroup]) -> [SessionGroup] {
        guard let window = appState.window(for: windowID) else { return windowGroups }
        let looseIDs = Set(window.looseGroupIDs)
        return windowGroups.filter { looseIDs.contains($0.id) }
    }

    /// Reorder within a section (favorites or normal) and write the combined
    /// order back to the window — favorites always stored first. Projects
    /// inside folders keep their place: their order lives in the folder, and
    /// dropping them from `groupIDs` here would take them out of the window.
    private func moveGroups(_ section: [SessionGroup], other: [SessionGroup],
                            favoritesSection: Bool, from: IndexSet, to: Int) {
        var moved = section
        moved.move(fromOffsets: from, toOffset: to)
        let ordered = favoritesSection ? moved + other : other + moved
        appState.updateWindow(windowID) { window in
            let filed = window.folders.flatMap(\.groupIDs)
            window.groupIDs = filed + ordered.map(\.id)
        }
    }

    // MARK: Folders

    private func folderSection(_ folder: ProjectFolder) -> some View {
        let projects = appState.groups(inFolder: folder)
        return DisclosureGroup(isExpanded: expansion(of: folder)) {
            ForEach(projects) { group in projectRows(group, siblings: projects) }
                .onMove { from, to in
                    var ids = projects.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    appState.updateFolder(folder.id, inWindow: windowID) { $0.groupIDs = ids }
                }
        } label: {
            folderLabel(folder, projects: projects)
        }
        // Selecting the folder row shows its overview in the main area: what is
        // in this box, what each project is doing, what it reported last.
        .tag(folder.id)
        // On the row, not the label — see groupRow. A project row inside the
        // folder is nested deeper, so its own target still wins over this one.
        .dropDestination(for: ProjectDragPayload.self) { payloads, _ in
            acceptProjectDrop(payloads, toFolder: folder.id, before: nil)
        } isTargeted: { setDropTarget(folder.id, over: $0) }
    }

    /// A folder's open/closed state lives in the model, so it survives a
    /// restart like everything else in the sidebar.
    private func expansion(of folder: ProjectFolder) -> Binding<Bool> {
        Binding(
            get: { !folder.collapsed },
            set: { open in
                appState.updateFolder(folder.id, inWindow: windowID) { $0.collapsed = !open }
            }
        )
    }

    private func folderLabel(_ folder: ProjectFolder, projects: [SessionGroup]) -> some View {
        let sessions = projects.flatMap { appState.sessions(in: $0) }
        return HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(folder.color.color ?? .secondary)
            Text(folder.name).fontWeight(.semibold)
            Text("\(projects.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            // On hover the folder offers the one thing you want from it while
            // pointing at it: another project *in here*. It replaces the counts
            // rather than sitting next to them, so the row never gets wider.
            if hoveredFolder == folder.id {
                Button {
                    appState.promptNewProject(inWindow: windowID, intoFolder: folder.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t(.newProjectInFolder, folder.name))
            } else {
                attentionSummary(sessions)
            }
        }
        .contentShape(Rectangle())
        .onHover { hoveredFolder = $0 ? folder.id : (hoveredFolder == folder.id ? nil : hoveredFolder) }
        .overlay(dropHighlight(folder.id))
        // Both things this row does: click opens the overview, a drag files
        // projects into it.
        .help("\(L10n.t(.folderOverviewHelp))\n\(L10n.t(.dropIntoFolder, folder.name))")
        .contextMenu {
            Button(L10n.t(.rename)) { renameFolder(folder) }
            colorPicker(current: folder.color) { color in
                appState.updateFolder(folder.id, inWindow: windowID) { $0.color = color }
            }
            Divider()
            Button(L10n.t(.dissolveFolder)) { appState.removeFolder(folder.id, inWindow: windowID) }
                .help(L10n.t(.dissolveFolderHelp))
        }
    }

    private func renameFolder(_ folder: ProjectFolder) {
        appState.promptText(title: L10n.t(.renameFolder), value: folder.name) { name in
            guard !name.isEmpty else { return }
            appState.updateFolder(folder.id, inWindow: windowID) { $0.name = name }
        }
    }

    /// "Move to folder ▸" — the way a project changes box (drag-and-drop across
    /// List sections isn't reliable enough to be the only route).
    @ViewBuilder
    private func folderPicker(for group: SessionGroup) -> some View {
        let window = appState.window(for: windowID)
        let current = window?.folder(of: group.id)
        Menu(L10n.t(.moveToFolder)) {
            ForEach(window?.folders ?? []) { folder in
                Button {
                    appState.moveGroup(group.id, toFolder: folder.id, inWindow: windowID)
                } label: {
                    HStack {
                        Text(folder.name)
                        if folder.id == current?.id { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button(L10n.t(.newFolder)) {
                appState.promptNewFolder(inWindow: windowID, containing: group.id)
            }
            if current != nil {
                Button(L10n.t(.noFolder)) {
                    appState.moveGroup(group.id, toFolder: nil, inWindow: windowID)
                }
            }
        }
        .help(L10n.t(.newFolderHelp))
    }

    // MARK: Minified rail

    private static let railWidth: CGFloat = 60
    private static let railTile: CGFloat = 38

    @ViewBuilder
    private func minifiedRail(_ windowGroups: [SessionGroup]) -> some View {
        VStack(spacing: 0) {
            // Expand control, aligned to the same height as the full header.
            Button { withAnimation(.easeInOut(duration: 0.25)) { minified = false } } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.railTile, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.t(.expandSidebar))
            .padding(.top, 6)
            .padding(.bottom, 4)

            Divider().frame(width: Self.railTile)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(windowGroups) { group in
                        minifiedProjectItem(group)
                    }
                    Button {
                        appState.promptNewProject(inWindow: windowID)
                    } label: {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.secondary.opacity(0.4),
                                          style: StrokeStyle(lineWidth: 1.2, dash: [3]))
                            .frame(width: Self.railTile, height: Self.railTile)
                            .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t(.newProjectHelp))
                }
                .frame(maxWidth: .infinity)   // center tiles in the rail
                .padding(.vertical, 10)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.railWidth)
    }

    /// A single project tile in the minified rail: initial + color, with a
    /// status dot when any of its terminals needs attention.
    private func minifiedProjectItem(_ group: SessionGroup) -> some View {
        let isSelected = appState.window(for: windowID)?.selectedGroupID == group.id
        let sessions = appState.sessions(in: group)
        // A snoozed terminal keeps its state but stops asking for attention.
        let states = sessions.filter { !appState.isMuted($0) }.map(\.state)
        let badge: AttentionState? = states.contains(.error) ? .error
            : (states.contains(.waiting) ? .waiting : nil)
        let initial = String(group.name.prefix(1)).uppercased()
        let fill = group.color.color ?? Color.secondary.opacity(0.22)
        return Button {
            if let active = sessions.first(where: { $0.id == group.activeSessionID }) ?? sessions.first {
                appState.select(session: active)
            } else {
                appState.updateWindow(windowID) { $0.selectGroup(group.id) }
            }
        } label: {
            RoundedRectangle(cornerRadius: 9)
                .fill(fill)
                .frame(width: Self.railTile, height: Self.railTile)
                .overlay(
                    Text(initial)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(group.color.color != nil ? .white : .primary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                )
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        // The same sprite as everywhere else, on a plain plate:
                        // a ring drawn around pixel art fights the pixels.
                        StateIcon(state: badge, size: 12)
                            .padding(2)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .padding(2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(group.name)
    }

    /// Accept folders dropped from Finder (or a terminal's proxy icon) and open
    /// a terminal in each. A live terminal window can't be adopted across apps,
    /// but dropping its folder brings that workspace into Planchette.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handledAny = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handledAny = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let path = url.path
                DispatchQueue.main.async {
                    appState.openTerminals(inDirectories: [resolveDirectory(path)], windowID: windowID)
                }
            }
        }
        return handledAny
    }

    /// If a file was dropped, use its containing folder.
    private func resolveDirectory(_ path: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// A project and whatever has to be visible under it: the row itself, plus
    /// the terminals that peek out of it while it is folded away.
    @ViewBuilder
    private func projectRows(_ group: SessionGroup, siblings: [SessionGroup]) -> some View {
        groupRow(group, siblings: siblings)
        ForEach(peeking(group)) { session in
            sessionRow(session,
                       isActive: false,
                       showBranch: appState.sharedBranch(of: group) == nil)
        }
    }

    /// What a folded project cannot hide: the terminals asking for you — a
    /// question or an error — that you have not looked at yet. They stand under
    /// the closed project row and go away by themselves the moment the terminal
    /// is read, so folding a project stays a way to get space, never a way to
    /// lose a prompt. An expanded project already shows everything, and a parked
    /// or snoozed one is silent on purpose (`AppState.isMuted`).
    private func peeking(_ group: SessionGroup) -> [TerminalSession] {
        guard collapsedGroups.contains(group.id) else { return [] }
        return appState.sessions(in: group).filter {
            $0.state.needsAttention && $0.isUnread && !appState.isMuted($0)
        }
    }

    /// A project's open/closed state. Not persisted (see `collapsedGroups`).
    private func expansion(of group: SessionGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group.id) },
            set: { open in
                if open {
                    collapsedGroups.remove(group.id)
                } else {
                    collapsedGroups.insert(group.id)
                }
            }
        )
    }

    /// A project row. `siblings` is the list it is displayed in (a folder's
    /// projects, or the loose ones), which is what "the gap below this row"
    /// resolves against.
    private func groupRow(_ group: SessionGroup, siblings: [SessionGroup] = []) -> some View {
        // The branch sits on the project row while every terminal of it is on
        // that branch, and moves into the terminal rows as soon as they differ —
        // it is stated once, where it is true.
        let shared = appState.sharedBranch(of: group)
        // Only the terminal actually on screen is marked. The mark answers
        // "which one am I looking at", so exactly one row in the whole sidebar
        // may carry it: the active terminal of the project this window shows —
        // in cluster mode the focused pane, since that is the same id. A project
        // you are not in has no visible terminal, and neither has a window
        // showing a folder overview.
        let visible = appState.window(for: windowID).map { window in
            window.selectedFolderID == nil && window.selectedGroupID == group.id
        } ?? false
        return DisclosureGroup(isExpanded: expansion(of: group)) {
            ForEach(appState.sessions(in: group)) { session in
                sessionRow(session,
                           isActive: visible && session.id == group.activeSessionID,
                           showBranch: shared == nil)
            }
        } label: {
            HStack(spacing: 6) {
                if let color = group.color.color {
                    Circle().fill(color).frame(width: 9, height: 9)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        // A parked project reads dimmed and carries the pause
                        // glyph: it still holds its terminals, it just has
                        // nothing to say (see `AppState.isMuted`).
                        Text(group.name)
                            .fontWeight(group.favorite ? .semibold : .regular)
                            .foregroundStyle(group.active ? .primary : .secondary)
                        if group.favorite {
                            PixelIcon(sprite: PixelSprites.star, size: 11, tint: .yellow)
                        }
                        if !group.active {
                            Image(systemName: "pause.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .help(L10n.t(.inactiveProject))
                        }
                        if let until = group.snoozedUntil, until > Date() {
                            SnoozeBadge(until: until)
                        }
                    }
                    if let shared {
                        BranchText(branch: shared)
                    }
                }
                Spacer()
                // Close (X) appears on hover; attention summary otherwise.
                if hoveredGroup == group.id {
                    Button { confirmClose(group) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.t(.closeProject))
                } else {
                    attentionSummary(group)
                }
            }
            .contentShape(Rectangle())
            .onHover { hoveredGroup = $0 ? group.id : (hoveredGroup == group.id ? nil : hoveredGroup) }
            .overlay(dropHighlight(group.id))
            .contextMenu { groupMenu(group) }
        }
        .tag(group.id)
        // Drag and drop belong on the ROW, not on the label inside it: a
        // DisclosureGroup's label never sees the drag gesture. And it has to be
        // `draggable`, not `onDrag` — the latter swallows the click that selects
        // the row, so a project could be dragged but no longer opened.
        // Drag a project — or the whole selection — onto a folder to file it,
        // or onto another project to land next to it in that project's folder.
        .draggable(ProjectDragPayload(ids: actionTargets(group))) { dragPreview(for: group) }
        // Measured so the delegate can tell the upper half of the row from the
        // lower one — that split is what makes a drop land in a chosen gap.
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { rowHeights[group.id] = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in rowHeights[group.id] = new }
            }
        )
        .overlay(insertionLine(group))
        .onDrop(
            of: [.plainText, .utf8PlainText, .text],
            delegate: ProjectDropDelegate(
                rowID: group.id,
                height: { rowHeights[group.id] ?? 24 },
                slot: { dropSlot = $0 },
                perform: { ids, below in
                    dropNext(to: group, below: below, ids: ids, siblings: siblings)
                }))
    }

    /// The project context menu. With several projects selected it acts on all
    /// of them — a batch you assembled by ⌘-clicking should not silently apply
    /// to one row.
    @ViewBuilder
    private func groupMenu(_ group: SessionGroup) -> some View {
        let targets = actionTargets(group)
        if targets.count > 1 {
            Text(L10n.t(.selectedProjects, targets.count))
            Divider()
            Button(L10n.t(.makeFavorite)) { appState.setFavorite(true, forGroups: targets) }
            Button(L10n.t(.unmakeFavorite)) { appState.setFavorite(false, forGroups: targets) }
            Button(L10n.t(.markProjectsActive, targets.count)) {
                appState.setActive(true, forGroups: targets)
            }
            Button(L10n.t(.markProjectsInactive, targets.count)) {
                appState.setActive(false, forGroups: targets)
            }
            .help(L10n.t(.markProjectActiveHelp))
            colorPicker(current: group.color) { color in
                for id in targets { appState.updateGroup(id) { $0.color = color } }
            }
            bulkFolderPicker(targets)
            Divider()
            Button(L10n.t(.markProjectsFree, targets.count)) { appState.markGroupsReady(targets) }
            Menu(L10n.t(.remindMe)) {
                ForEach(SnoozeOption.allCases) { option in
                    Button(L10n.t(option.labelKey)) {
                        appState.snooze(groups: targets, until: option.date(from: Date()))
                    }
                }
            }
            .help(L10n.t(.remindMeHelp))
            Divider()
            Button(L10n.t(.closeProjects, targets.count), role: .destructive) {
                confirmClose(targets)
            }
        } else {
            Button(group.favorite ? L10n.t(.unmakeFavorite) : L10n.t(.makeFavorite)) {
                appState.updateGroup(group.id) { $0.favorite.toggle() }
            }
            .help(L10n.t(.favoriteHelp))
            Button(group.active ? L10n.t(.markProjectInactive) : L10n.t(.markProjectActive)) {
                appState.setActive(!group.active, forGroups: [group.id])
            }
            .help(L10n.t(.markProjectActiveHelp))
            colorPicker(current: group.color) { color in
                appState.updateGroup(group.id) { $0.color = color }
            }
            Button(L10n.t(.rename)) { rename(group: group) }
            folderPicker(for: group)
            Button(L10n.t(.moveToNewWindow)) {
                openWindow(value: appState.moveGroupToNewWindow(group.id))
            }
            .help(L10n.t(.moveToNewWindowHelp))
            Divider()
            GroupAttentionMenu(group: group)
            Divider()
            Button(L10n.t(.closeProject), role: .destructive) { confirmClose(group) }
        }
    }

    /// "Move to folder" for a batch.
    @ViewBuilder
    private func bulkFolderPicker(_ targets: [UUID]) -> some View {
        let window = appState.window(for: windowID)
        Menu(L10n.t(.moveToFolder)) {
            ForEach(window?.folders ?? []) { folder in
                Button(folder.name) {
                    appState.moveGroups(targets, toFolder: folder.id, inWindow: windowID)
                }
            }
            Divider()
            Button(L10n.t(.newFolder)) { promptNewFolder(containing: targets) }
            Button(L10n.t(.noFolder)) {
                appState.moveGroups(targets, toFolder: nil, inWindow: windowID)
            }
        }
    }

    /// New folder holding a whole batch — the folder is created first, then the
    /// projects move in, so a cancelled prompt leaves nothing behind.
    private func promptNewFolder(containing targets: [UUID]) {
        appState.promptText(title: L10n.t(.newFolderTitle), value: "") { name in
            guard !name.isEmpty else { return }
            let folder = appState.addFolder(name: name, inWindow: windowID)
            appState.moveGroups(targets, toFolder: folder.id, inWindow: windowID)
        }
    }

    /// Confirm before closing several projects at once — it ends every terminal
    /// in all of them, so the count is spelled out.
    private func confirmClose(_ ids: [UUID]) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.closeProjects, ids.count)
        alert.informativeText = L10n.t(
            .closeProjectsBody, ids.count, appState.terminalCount(inGroups: ids))
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t(.closeProjects, ids.count))
        alert.addButton(withTitle: L10n.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        appState.closeGroups(ids)
        multiSelection = []
    }

    /// Confirm before closing a project — it ends the project's terminals.
    private func confirmClose(_ group: SessionGroup) {
        let count = appState.sessions(in: group).count
        let alert = NSAlert()
        alert.messageText = L10n.t(.closeProject)
        alert.informativeText = L10n.t(.closeProjectBody, group.name, count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t(.closeProject))
        alert.addButton(withTitle: L10n.t(.cancel))
        if alert.runModal() == .alertFirstButtonReturn {
            appState.closeGroup(group.id)
        }
    }

    /// `isActive` marks the terminal this project is currently showing — the one
    /// the tab bar has open. Outlined in its state colour, exactly like the tab,
    /// so the sidebar answers "which one am I in, and what is it doing" without
    /// opening the project.
    private func sessionRow(_ session: TerminalSession, isActive: Bool = false,
                            showBranch: Bool = false) -> some View {
        // What I last sent this terminal to do. Its own row, so the line above
        // can stay the fixed answer to "which checkout is this?" while this one
        // changes with every prompt.
        let task = session.currentTask.flatMap { Titles.taskLabel($0, max: 48) }
        return Button {
            appState.select(session: session)
        } label: {
            HStack(spacing: 6) {
                StateIcon(state: session.state)
                if let color = session.color.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    // Where this terminal is: the ticket of its checkout (or the
                    // name you gave it) and the tail of the path.
                    HStack(spacing: 5) {
                        if let name = session.rowName {
                            Text(name).lineLimit(1)
                        }
                        Text(session.shortPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if showBranch, let branch = appState.branches[session.id] {
                        BranchText(branch: branch)
                    }
                    // The prompt and how long ago something last happened here.
                    // The age sits at the right edge, the same place it sits in
                    // every other list, so a column of ages can be read down
                    // instead of hunted for at the end of each prompt. It stays on
                    // the row without a prompt as well, so a question or an error
                    // still says how long it has been one.
                    if task != nil || session.state.needsAttention {
                        HStack(spacing: 5) {
                            if let task {
                                Text(task)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            WaitingTimeText(since: session.stateSince)
                        }
                    }
                    TagChips(tags: session.tags)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let until = appState.snoozeEnd(for: session), until > Date() {
                    SnoozeBadge(until: until)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isActive ? session.state.tint : .clear, lineWidth: 1.5)
        )
        .help(sessionTooltip(session))
        .contextMenu {
            SessionAttentionMenu(session: session)
            Divider()
            TagMenu(session: session)
            Divider()
            Button(L10n.t(.rename)) { appState.promptRename(session: session) }
            colorPicker(current: session.color) { color in
                appState.update(session.id) { $0.color = color }
            }
            Button(L10n.t(.startupCommand)) { appState.promptStartupCommand(session: session) }
                .help(L10n.t(.startupCommandHelp))
            Divider()
            Button(L10n.t(.close), role: .destructive) { appState.closeSession(session.id) }
        }
    }

    private func sessionTooltip(_ session: TerminalSession) -> String {
        var lines = [session.currentDirectory]
        if let summary = session.aiSummary { lines.append("🔮 \(summary)") }
        if !session.tags.isEmpty { lines.append("Tags: \(session.tags.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private func attentionSummary(_ group: SessionGroup) -> some View {
        attentionSummary(appState.sessions(in: group))
    }

    /// Badge row for any set of terminals (a project, or a folder's projects taken
    /// together). Silent terminals are left out — a snoozed or parked project must
    /// not keep a badge lit while it is meant to be quiet.
    private func attentionSummary(_ all: [TerminalSession]) -> some View {
        StateSummaryBadges(sessions: all.filter { !appState.isMuted($0) })
    }

    @ViewBuilder
    private func colorPicker(current: SessionColor, apply: @escaping (SessionColor) -> Void) -> some View {
        Menu(L10n.t(.color)) {
            ForEach(SessionColor.allCases) { option in
                Button {
                    apply(option)
                } label: {
                    HStack {
                        Text(option == .none ? L10n.t(.colorNone) : option.rawValue.capitalized)
                        if option == current { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .help(L10n.t(.colorHelp))
    }

    private func rename(group: SessionGroup) {
        appState.promptText(title: L10n.t(.renameGroup), value: group.name) { name in
            appState.updateGroup(group.id) { $0.name = name }
        }
    }
}

/// Bottom bar of the project panel: project-settings icons + quick switcher.
struct SidebarBottomBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    let windowID: UUID

    var body: some View {
        HStack(spacing: 2) {
            // Search / quick switcher (far left).
            barButton("magnifyingglass", help: L10n.t(.quickSwitcherHelp)) {
                appState.showQuickSwitcher()
            }
            Spacer()
            // Settings (far right).
            barButton("gearshape", help: L10n.t(.settingsHelp)) { openSettings() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A checked-out branch, wherever one is named: the project row while its
/// terminals agree on it, a terminal row when they do not. One view so both read
/// the same and the full name is always on hover.
struct BranchText: View {
    let branch: String

    var body: some View {
        Text(branch)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(branch)
    }
}

/// When a "how long ago" label has to redraw: every second while it still counts
/// seconds, once a minute afterwards. A fixed minute cadence would leave "3s"
/// standing for the better part of a minute, and a fixed second cadence would
/// redraw every row of a workspace that has been idle for hours.
struct AgeSchedule: TimelineSchedule {
    let since: Date

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        return AnyIterator {
            let step: TimeInterval = next.timeIntervalSince(since) < 60 ? 1 : 60
            defer { next = next.addingTimeInterval(step) }
            return next
        }
    }
}

/// "12m" — how long ago the state last changed, updated once a minute.
struct WaitingTimeText: View {
    let since: Date

    var body: some View {
        TimelineView(AgeSchedule(since: since)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                // "3m" is the last thing that should wrap when a panel gets
                // narrow — it would break into two lines and push the row open.
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// "42s" / "12m" / "1h 20m" / "3d" / "2w" — an age in the unit symbols the
    /// rows use everywhere: s, m, h, d, w. Two units at most, and the smaller one
    /// only while it carries something: "1h 20m" is worth the width, "2h 0m" is
    /// not. A negative interval (a clock that moved) reads as "0s", never as a
    /// count from the future.
    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if seconds < 60 { return L10n.t(.secondsShort, seconds) }
        if minutes < 60 { return L10n.t(.minutesShort, minutes) }
        if hours < 24 { return with(L10n.t(.hoursShort, hours), minutes % 60, .minutesShort) }
        if days < 7 { return with(L10n.t(.daysShort, days), hours % 24, .hoursShort) }
        return with(L10n.t(.weeksShort, days / 7), days % 7, .daysShort)
    }

    /// Append the next unit down, unless it is zero — then the bigger one already
    /// says everything.
    private static func with(_ head: String, _ rest: Int, _ key: LKey) -> String {
        rest == 0 ? head : "\(head) \(L10n.t(key, rest))"
    }
}

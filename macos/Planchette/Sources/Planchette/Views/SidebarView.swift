import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarMinified") private var minified = false
    let windowID: UUID
    @State private var isDropTargeted = false

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { appState.window(for: windowID)?.selectedGroupID },
            set: { newValue in appState.updateWindow(windowID) { $0.selectedGroupID = newValue } }
        )
    }

    var body: some View {
        let windowGroups = appState.window(for: windowID).map { appState.groups(inWindow: $0) } ?? []
        VStack(spacing: 0) {
            if minified {
                minifiedRail(windowGroups)
            } else {
                fullList(windowGroups)
            }
            SidebarBottomBar(windowID: windowID)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: Full list

    @ViewBuilder
    private func fullList(_ windowGroups: [SessionGroup]) -> some View {
        VStack(spacing: 0) {
            // Header row: title + add-project + collapse.
            HStack(spacing: 6) {
                Text(L10n.t(.projects)).font(.headline)
                Button {
                    appState.promptNewProject(inWindow: windowID)
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help(L10n.t(.newProjectHelp))
                Spacer()
                Button { minified = true } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.plain)
                .help(L10n.t(.minifySidebar))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            List(selection: selectionBinding) {
                let favorites = windowGroups.filter(\.favorite)
                let normal = windowGroups.filter { !$0.favorite }

                if !favorites.isEmpty {
                    Section(L10n.t(.mainProjects)) {
                        ForEach(favorites) { group in groupRow(group) }
                    }
                }
                Section(favorites.isEmpty ? L10n.t(.projects) : L10n.t(.sideProjects)) {
                    ForEach(normal) { group in groupRow(group) }
                }
            }
            .listStyle(.sidebar)
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
    }

    // MARK: Minified rail

    @ViewBuilder
    private func minifiedRail(_ windowGroups: [SessionGroup]) -> some View {
        VStack(spacing: 0) {
            Button { minified = false } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t(.expandSidebar))
            .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(windowGroups) { group in
                        ForEach(appState.sessions(in: group)) { session in
                            minifiedItem(session)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func minifiedItem(_ session: TerminalSession) -> some View {
        let isSelected = appState.window(for: windowID)?.selectedGroupID == session.groupID
            && appState.groups.first { $0.id == session.groupID }?.activeSessionID == session.id
        return Button {
            appState.select(session: session)
        } label: {
            ZStack {
                Circle()
                    .fill(session.state.tint)
                    .frame(width: 24, height: 24)
                Image(systemName: session.state.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(
                Circle().strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2)
            )
            .padding(4)
            .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("\(session.displayTitle) — \(session.state.label)\n\(session.currentDirectory)")
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

    private func groupRow(_ group: SessionGroup) -> some View {
        DisclosureGroup {
            ForEach(appState.sessions(in: group)) { session in
                sessionRow(session)
            }
        } label: {
            HStack(spacing: 6) {
                if let color = group.color.color {
                    Circle().fill(color).frame(width: 9, height: 9)
                }
                Text(group.name).fontWeight(group.favorite ? .semibold : .regular)
                if group.favorite {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Spacer()
                attentionSummary(group)
            }
            .contextMenu {
                Button(group.favorite ? L10n.t(.unmakeFavorite) : L10n.t(.makeFavorite)) {
                    appState.updateGroup(group.id) { $0.favorite.toggle() }
                }
                .help(L10n.t(.favoriteHelp))
                colorPicker(current: group.color) { color in
                    appState.updateGroup(group.id) { $0.color = color }
                }
                Button(L10n.t(.rename)) { rename(group: group) }
                Divider()
                Button(L10n.t(.moveToNewWindow)) {
                    openWindow(value: appState.moveGroupToNewWindow(group.id))
                }
                .help(L10n.t(.moveToNewWindowHelp))
            }
        }
        .tag(group.id)
    }

    private func sessionRow(_ session: TerminalSession) -> some View {
        Button {
            appState.select(session: session)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.state.symbol)
                    .foregroundStyle(session.state.tint)
                    .font(.caption)
                if let color = session.color.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle).lineLimit(1)
                    Text(session.shortPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    TagChips(tags: session.tags)
                }
                Spacer()
                if session.state.needsAttention {
                    WaitingTimeText(since: session.stateSince)
                }
            }
        }
        .buttonStyle(.plain)
        .help(sessionTooltip(session))
        .contextMenu {
            if session.state.needsAttention {
                Button(L10n.t(.markReady)) { appState.markReady(session.id) }
                Divider()
            }
            TagMenu(session: session)
            Divider()
            Button(L10n.t(.rename)) { rename(session: session) }
            colorPicker(current: session.color) { color in
                appState.update(session.id) { $0.color = color }
            }
            Button(L10n.t(.startupCommand)) { editStartupCommand(session: session) }
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
        let sessions = appState.sessions(in: group)
        let waiting = sessions.filter { $0.state == .waiting }.count
        let errors = sessions.filter { $0.state == .error }.count
        return HStack(spacing: 4) {
            if errors > 0 {
                Text("\(errors)").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            }
            if waiting > 0 {
                Text("\(waiting)").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.blue.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            }
        }
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
        prompt(title: L10n.t(.renameGroup), value: group.name) { name in
            appState.updateGroup(group.id) { $0.name = name }
        }
    }

    private func rename(session: TerminalSession) {
        prompt(title: L10n.t(.renameTerminal), value: session.customTitle ?? "") { name in
            appState.update(session.id) { $0.customTitle = name.isEmpty ? nil : name }
        }
    }

    private func editStartupCommand(session: TerminalSession) {
        prompt(
            title: L10n.t(.startupCommandPrompt),
            value: session.startupCommand ?? ""
        ) { command in
            appState.update(session.id) { $0.startupCommand = command.isEmpty ? nil : command }
        }
    }

    private func prompt(title: String, value: String, apply: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            apply(field.stringValue.trimmingCharacters(in: .whitespaces))
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

/// "wartet seit 12 min" — updates once a minute.
struct WaitingTimeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return L10n.t(.now) }
        if minutes < 60 { return L10n.t(.minutesShort, minutes) }
        return L10n.t(.hoursShort, minutes / 60, minutes % 60)
    }
}

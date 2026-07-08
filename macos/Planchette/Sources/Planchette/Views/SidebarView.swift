import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedGroupID) {
            let favorites = appState.groups.filter(\.favorite)
            let normal = appState.groups.filter { !$0.favorite }

            if !favorites.isEmpty {
                Section("Hauptprojekte") {
                    ForEach(favorites) { group in groupRow(group) }
                }
            }
            Section(favorites.isEmpty ? "Projekte" : "Side Projects") {
                ForEach(normal) { group in groupRow(group) }
            }
        }
        .listStyle(.sidebar)
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
                Button(group.favorite ? "Kein Hauptprojekt mehr" : "Als Hauptprojekt") {
                    appState.updateGroup(group.id) { $0.favorite.toggle() }
                }
                colorPicker(current: group.color) { color in
                    appState.updateGroup(group.id) { $0.color = color }
                }
                Button("Umbenennen…") { rename(group: group) }
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
            TagMenu(session: session)
            Divider()
            Button("Umbenennen…") { rename(session: session) }
            colorPicker(current: session.color) { color in
                appState.update(session.id) { $0.color = color }
            }
            Button("Startup-Command…") { editStartupCommand(session: session) }
            Divider()
            Button("Schließen", role: .destructive) { appState.closeSession(session.id) }
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
        let asking = sessions.filter { $0.state == .asking }.count
        let done = sessions.filter { $0.state == .done }.count
        return HStack(spacing: 4) {
            if asking > 0 {
                Text("\(asking)").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.orange.opacity(0.8), in: Capsule()).foregroundStyle(.white)
            }
            if done > 0 {
                Text("\(done)").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.green.opacity(0.8), in: Capsule()).foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private func colorPicker(current: SessionColor, apply: @escaping (SessionColor) -> Void) -> some View {
        Menu("Farbe") {
            ForEach(SessionColor.allCases) { option in
                Button {
                    apply(option)
                } label: {
                    HStack {
                        Text(option == .none ? "Keine" : option.rawValue.capitalized)
                        if option == current { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }

    private func rename(group: SessionGroup) {
        prompt(title: "Gruppe umbenennen", value: group.name) { name in
            appState.updateGroup(group.id) { $0.name = name }
        }
    }

    private func rename(session: TerminalSession) {
        prompt(title: "Terminal umbenennen", value: session.customTitle ?? "") { name in
            appState.update(session.id) { $0.customTitle = name.isEmpty ? nil : name }
        }
    }

    private func editStartupCommand(session: TerminalSession) {
        prompt(
            title: "Startup-Command (läuft nach einem Restore erneut)",
            value: session.startupCommand ?? ""
        ) { command in
            appState.update(session.id) { $0.startupCommand = command.isEmpty ? nil : command }
        }
    }

    private func prompt(title: String, value: String, apply: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            apply(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
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
        if minutes < 1 { return "jetzt" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

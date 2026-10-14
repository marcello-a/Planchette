import SwiftUI

/// Settings → Project panel: what the left panel shows next to a project or a
/// terminal, and the tags you keep.
///
/// Three pages instead of one long list of switches — a switch is found by what
/// it is about (a terminal, a project, a tag), and a page is short enough to
/// read. The details are `SidebarDetail.allCases` grouped by `group`, so a new
/// detail cannot ship without a switch here.
struct ProjectPanelSettings: View {
    private enum Page: String, CaseIterable, Identifiable {
        case terminals, projects, tags

        var id: String { rawValue }

        var titleKey: LKey {
            switch self {
            case .terminals: .projectPanelPageTerminals
            case .projects: .projects
            case .tags: .tags
            }
        }
    }

    /// The page you were on, kept for the next time Settings opens — the way the
    /// window already remembers its tab. A view convenience, not workspace state,
    /// so it lives in the user defaults and not in `state.json`.
    @AppStorage("projectPanelPage") private var page: Page = .terminals

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L10n.t(.projectPanelTab), selection: $page) {
                    ForEach(Page.allCases) { Text(L10n.t($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if page != .tags {
                    Text(L10n.t(.projectPanelIntro))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 2)

            switch page {
            case .terminals: TerminalPage()
            case .projects: ProjectPage()
            case .tags: TagEditor()
            }
        }
    }
}

/// What a terminal's row shows — in four groups — and how long its done check stays.
private struct TerminalPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            ForEach(SidebarDetailGroup.terminalGroups) { group in
                Section {
                    ForEach(SidebarDetail.allCases.filter { $0.group == group }) {
                        DetailSwitch(detail: $0)
                    }
                } header: {
                    Text(L10n.t(group.titleKey))
                } footer: {
                    // The one group that is off by default, and why.
                    if group == .claude {
                        Text(L10n.t(.projectPanelOptionalHelp))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section(L10n.t(.projectPanelBehavior)) {
                Picker(L10n.t(.doneExpiryTitle), selection: $appState.doneExpiry) {
                    ForEach(DoneExpiry.allCases) { Text($0.label).tag($0) }
                }
                .help(L10n.t(.doneExpiryHelp))
                Text(L10n.t(.doneExpiryHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// What a project's row shows, and how a folded project behaves.
private struct ProjectPage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            ForEach(SidebarDetailGroup.allCases.filter { !$0.isTerminal }) { group in
                Section {
                    ForEach(SidebarDetail.allCases.filter { $0.group == group }) {
                        DetailSwitch(detail: $0)
                    }
                } header: {
                    Text(L10n.t(group.titleKey))
                }
            }
            Section(L10n.t(.projectPanelBehavior)) {
                Toggle(L10n.t(.peekCollapsedTitle), isOn: $appState.peekCollapsedProjects)
                    .help(L10n.t(.peekCollapsedHelp))
                Text(L10n.t(.peekCollapsedHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// The switch, what it means in one line, and what it looks like — drawn with
/// the sidebar's own views, so the example cannot drift from the row.
private struct DetailSwitch: View {
    @EnvironmentObject var appState: AppState
    let detail: SidebarDetail

    var body: some View {
        Toggle(isOn: Binding(
            get: { appState.shows(detail) },
            set: { appState.sidebarDetails.set(detail, $0) })
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t(detail.titleKey))
                Text(L10n.t(detail.helpKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SidebarDetailExample(detail: detail)
                    .opacity(appState.shows(detail) ? 1 : 0.4)
            }
        }
    }
}

// MARK: Tags

/// The tag list: what a terminal's Tags menu offers. Rename or delete a tag here
/// and it changes on every terminal that carries it (and in the saved
/// arrangements); a tag made with "New tag…" shows up below until you keep it.
private struct TagEditor: View {
    @EnvironmentObject var appState: AppState
    @State private var newName = ""
    @State private var pendingDelete: String?

    var body: some View {
        Form {
            Section {
                Text(L10n.t(.tagEditorHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.tagList.isEmpty {
                    Text(L10n.t(.tagEditorEmpty)).foregroundStyle(.secondary)
                }
                ForEach(appState.tagList, id: \.self) { tag in
                    TagRow(tag: tag) { askToDelete(tag) }
                }
                HStack {
                    TextField(L10n.t(.tagEditorNewPlaceholder), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(L10n.t(.tagEditorAdd), action: add)
                        .disabled(TagList.normalized(newName) == nil)
                }
            } header: {
                Text(L10n.t(.tagEditorTitle))
            }

            if !appState.strayTags.isEmpty {
                Section {
                    ForEach(appState.strayTags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            Spacer()
                            Text(usage(of: tag)).font(.caption).foregroundStyle(.secondary)
                            Button(L10n.t(.tagKeep)) { appState.addTagToList(tag) }
                        }
                    }
                } header: {
                    Text(L10n.t(.tagStraysTitle))
                } footer: {
                    Text(L10n.t(.tagStraysHelp))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button(L10n.t(.tagRestoreDefaults)) { appState.restoreDefaultTagList() }
                    .disabled(appState.tagList == TagList.defaults)
                    .help(L10n.t(.tagRestoreDefaultsHelp, TagList.defaults.joined(separator: ", ")))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            pendingDelete.map { L10n.t(.tagDeleteTitle, $0) } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.t(.tagDeleteConfirm), role: .destructive) {
                if let tag = pendingDelete { appState.deleteTag(tag) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { L10n.t(.tagDeleteBody, appState.tagUsage($0)) } ?? "")
        }
    }

    private func add() {
        appState.addTagToList(newName)
        newName = ""
    }

    /// A tag nobody carries goes at once; one that is on terminals asks first,
    /// because the delete reaches them all.
    private func askToDelete(_ tag: String) {
        if appState.tagUsage(tag) == 0 {
            appState.deleteTag(tag)
        } else {
            pendingDelete = tag
        }
    }

    private func usage(of tag: String) -> String {
        let count = appState.tagUsage(tag)
        return count == 0 ? L10n.t(.tagUnused) : L10n.t(.tagUsage, count)
    }
}

/// One tag of the list: its name, editable in place; where it is used; delete.
private struct TagRow: View {
    @EnvironmentObject var appState: AppState
    let tag: String
    let delete: () -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(tag: String, delete: @escaping () -> Void) {
        self.tag = tag
        self.delete = delete
        _draft = State(initialValue: tag)
    }

    var body: some View {
        // The name is the label and the facts are the content: a Form lays a
        // bare TextField out as "label | field" and left the whole left half empty.
        LabeledContent {
            HStack(spacing: 8) {
                let count = appState.tagUsage(tag)
                Text(count == 0 ? L10n.t(.tagUnused) : L10n.t(.tagUsage, count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.t(.tagDeleteHelp))
            }
        } label: {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                .frame(maxWidth: 200)
                .focused($focused)
                .onSubmit(commit)
                // Leaving the field keeps what you typed, as Return does.
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        }
    }

    /// A name that normalizes to something new renames the tag everywhere; an
    /// empty or unchanged one puts the old name back.
    private func commit() {
        if let new = TagList.normalized(draft), new != tag {
            appState.renameTag(tag, to: new)
        } else {
            draft = tag
        }
    }
}

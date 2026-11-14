import AppKit
import SwiftUI

/// The Jira panel at the right of the tab (and of the notepad, when that is open): one section per
/// saved JQL query, a card per ticket. The same panel for every terminal; the queries are made and
/// changed here. The rules are in `JiraTickets`, the poll in `Jira.swift`.
struct JiraPanel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab: SettingsTab = .general
    /// The query being written: a new one (`editingID == nil`) or an existing one.
    @State private var editing = false
    @State private var editingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !appState.jira.hasAccount {
                placeholder(.jiraNoAccount) {
                    Button(L10n.t(.jiraOpenSettings)) {
                        settingsTab = .general
                        openSettings()
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if editing && editingID == nil {
                            JiraQueryEditor(query: nil) { editing = false }
                        }
                        if appState.jira.queries.isEmpty && !editing {
                            Text(L10n.t(.jiraNoQueries))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(appState.jira.queries) { query in
                            if editing && editingID == query.id {
                                JiraQueryEditor(query: query) { editing = false }
                            } else {
                                section(query)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "ticket").foregroundStyle(.secondary)
            Text(L10n.t(.jiraTitle))
                .font(.caption.weight(.medium))
            Spacer(minLength: 4)
            if appState.jiraRefreshing {
                ProgressView().controlSize(.mini)
            }
            headerButton("arrow.clockwise", help: .jiraRefresh) { appState.refreshJira(manual: true) }
                .disabled(!appState.jira.hasAccount || appState.jira.queries.isEmpty)
            headerButton("plus", help: .jiraAddQuery) {
                editingID = nil
                editing = true
            }
            .disabled(!appState.jira.hasAccount)
            headerButton("xmark", help: .jiraClose) { appState.toggleJiraPanel() }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func headerButton(_ symbol: String, help: LKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
    }

    private func placeholder<Action: View>(_ key: LKey, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Text(L10n.t(key))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: A query

    private func section(_ query: JiraQuery) -> some View {
        let result = appState.jiraResults[query.id]
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                appState.updateJira { look in
                    if let i = look.queries.firstIndex(where: { $0.id == query.id }) { look.queries[i].collapsed.toggle() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: query.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Text(query.name.isEmpty ? query.jql : query.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let result, result.error == nil {
                        Text("\(result.issues.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(query.jql)
            .contextMenu { queryMenu(query) }

            if !query.collapsed {
                if let error = result?.error {
                    Label(JiraErrorText.of(error), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let result, result.issues.isEmpty {
                    Text(L10n.t(.jiraEmpty))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if let result {
                    ForEach(result.issues) { issue in
                        JiraCard(issue: issue)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func queryMenu(_ query: JiraQuery) -> some View {
        Button(L10n.t(.jiraEditQuery)) {
            editingID = query.id
            editing = true
        }
        Button(L10n.t(.jiraMoveUp)) { appState.updateJira { $0.moveQuery(query.id, by: -1) } }
            .disabled(appState.jira.queries.first?.id == query.id)
        Button(L10n.t(.jiraMoveDown)) { appState.updateJira { $0.moveQuery(query.id, by: 1) } }
            .disabled(appState.jira.queries.last?.id == query.id)
        Divider()
        Button(L10n.t(.jiraDeleteQuery), role: .destructive) {
            appState.updateJira { $0.queries.removeAll { $0.id == query.id } }
        }
    }
}

/// What a query's error says, in the user's language.
enum JiraErrorText {
    static func of(_ error: JiraError) -> String {
        switch error {
        case .unauthorized: return L10n.t(.jiraErrorUnauthorized)
        case .rejected(let message): return message
        case .unreachable: return L10n.t(.jiraErrorUnreachable)
        case .unreadable: return L10n.t(.jiraErrorUnreadable)
        }
    }
}

/// A ticket: key, type and priority; the title in at most two lines; its status and who has it.
/// A click opens it in the browser.
struct JiraCard: View {
    @EnvironmentObject var appState: AppState
    let issue: JiraIssue
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(issue.key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text([issue.type, issue.priority].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(issue.summary)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(issue.status)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(tint)
                        .background(tint.opacity(0.15), in: Capsule())
                    if let days = issue.daysInStatus() {
                        Text(L10n.t(.jiraDaysInStatus, days))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(issue.assignee ?? L10n.t(.jiraUnassigned))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(hovered ? 0.45 : 0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { appState.openInBrowser(issue) }
        // One tooltip for the whole card: a `.help` inside it never shows, the card's covers it.
        .help(tooltip)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var tooltip: String {
        guard let days = issue.daysInStatus() else { return L10n.t(.jiraCardHelp) }
        return L10n.t(.jiraDaysInStatusHelp, days, issue.status) + "\n" + L10n.t(.jiraCardHelp)
    }

    private var tint: Color {
        switch issue.statusCategory {
        case .todo: return .gray
        case .inProgress: return .blue
        case .done: return .green
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(L10n.t(.jiraOpenInBrowser)) { appState.openInBrowser(issue) }
        Button(L10n.t(.jiraCopyKey)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(issue.key, forType: .string)
        }
        Divider()
        Menu(L10n.t(.jiraOpenTerminalIn)) {
            ForEach(appState.groups) { group in
                Button(group.name) { appState.openTerminal(for: issue, inGroup: group.id) }
            }
        }
        .disabled(appState.groups.isEmpty)
    }
}

/// A query being made or changed, in place of its section: a name, the JQL, and "Test", which asks
/// Jira before anything is saved.
struct JiraQueryEditor: View {
    @EnvironmentObject var appState: AppState
    let query: JiraQuery?
    let onClose: () -> Void
    @State private var name = ""
    @State private var jql = ""
    @State private var test: JiraResult?
    @State private var testing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.t(.jiraQueryName), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !trimmedJQL.isEmpty { save() } }
            TextField(L10n.t(.jiraQueryPlaceholder), text: $jql, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2...6)
                .focused($focused)
            if let test {
                Text(test.error.map(JiraErrorText.of) ?? L10n.t(.jiraTestResult, test.issues.count))
                    .font(.caption)
                    .foregroundStyle(test.error == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.t(.jiraTest)) { runTest() }
                    .disabled(trimmedJQL.isEmpty || testing)
                if testing { ProgressView().controlSize(.mini) }
                Spacer()
                // No Return/Esc shortcuts: a window-wide one would take those keys from the terminal.
                Button(L10n.t(.cancel)) { close() }
                Button(L10n.t(.ok)) { save() }
                    .disabled(trimmedJQL.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .onAppear {
            name = query?.name ?? ""
            jql = query?.jql ?? ""
            focused = true
        }
        .onExitCommand { close() }
        .onChange(of: focused) { _, now in appState.jiraEditing = now }
        .onDisappear { appState.jiraEditing = false }
    }

    private var trimmedJQL: String { jql.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func runTest() {
        testing = true
        let asked = trimmedJQL
        Task {
            let result = await appState.testJiraQuery(asked)
            test = result
            testing = false
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let jql = trimmedJQL
        appState.updateJira { look in
            if let query, let i = look.queries.firstIndex(where: { $0.id == query.id }) {
                look.queries[i].name = name
                look.queries[i].jql = jql
            } else {
                look.queries.append(JiraQuery(name: name, jql: jql))
            }
        }
        close()
    }

    private func close() {
        appState.jiraEditing = false
        onClose()
    }
}

/// Settings → General → Panels, under the Jira switch: the site, the account and the API token
/// (which goes to the Keychain, not to `state.json`), and a check that they work.
struct JiraAccountSettings: View {
    @EnvironmentObject var appState: AppState
    @State private var token = ""
    @State private var checking = false
    @State private var check: Result<String, JiraError>?

    var body: some View {
        TextField(L10n.t(.jiraSite), text: siteBinding, prompt: Text(verbatim: "example.atlassian.net"))
            .help(L10n.t(.jiraSiteHelp))
        TextField(L10n.t(.jiraEmail), text: emailBinding)
            .textContentType(.username)
        SecureField(L10n.t(.jiraToken), text: $token)
            .help(L10n.t(.jiraTokenHelp))
            .onSubmit(saveToken)
            .onChange(of: token) { _, _ in check = nil }
        HStack {
            Button(L10n.t(.jiraCheckConnection)) {
                saveToken()
                checking = true
                Task {
                    check = await appState.checkJiraConnection()
                    checking = false
                    if case .success = check { appState.offerHint(.jira) }
                }
            }
            .disabled(!appState.jira.hasAccount || token.isEmpty || checking)
            if checking { ProgressView().controlSize(.small) }
            switch check {
            case .success(let name):
                Label(L10n.t(.jiraConnected, name), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .failure(let error):
                Label(JiraErrorText.of(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(2)
            case nil:
                EmptyView()
            }
            Spacer()
            Link(L10n.t(.jiraCreateToken),
                 destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                .font(.caption)
        }
        .onAppear(perform: loadToken)
        .onChange(of: appState.jira.email) { _, _ in loadToken() }
        .onDisappear(perform: saveToken)
    }

    private var siteBinding: Binding<String> {
        Binding(get: { appState.jira.site }, set: { value in appState.updateJira { $0.site = value } })
    }

    private var emailBinding: Binding<String> {
        Binding(get: { appState.jira.email }, set: { value in appState.updateJira { $0.email = value } })
    }

    private var account: String { appState.jira.email.trimmingCharacters(in: .whitespaces) }

    private func loadToken() {
        token = Keychain.read(service: Keychain.jiraService, account: account) ?? ""
    }

    private func saveToken() {
        guard !account.isEmpty,
              token != (Keychain.read(service: Keychain.jiraService, account: account) ?? "") else { return }
        Keychain.write(token, service: Keychain.jiraService, account: account)
        appState.refreshJira()
    }
}

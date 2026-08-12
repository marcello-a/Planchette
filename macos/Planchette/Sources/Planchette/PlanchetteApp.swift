import SwiftUI

@main
struct PlanchetteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Every window carries its WindowModel id; the default (first) window
        // uses the stable main-window id.
        WindowGroup("Planchette", for: UUID.self) { $windowID in
            ContentView(windowID: windowID)
                .environmentObject(delegate.appState)
                .frame(minWidth: 900, minHeight: 520)
        } defaultValue: {
            AppState.mainWindowID
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(L10n.t(.newWindow)) {
                    openWindow(value: delegate.appState.newWindow())
                }
                .keyboardShortcut("n")
            }
            CommandMenu(L10n.t(.sessionMenu)) {
                Button(L10n.t(.newTerminal)) { delegate.appState.promptNewTerminalInKeyWindow() }
                    .keyboardShortcut("t")
                Button(L10n.t(.newWorktree)) { delegate.appState.promptNewWorktree() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button(L10n.t(.quickSwitcher)) { delegate.appState.showQuickSwitcher() }
                    .keyboardShortcut("k")
                Button(L10n.t(.jumpToWaiting)) { delegate.appState.jumpToNextWaiting() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.t(.arrangements)) {
                ArrangementsMenu()
                    .environmentObject(delegate.appState)
            }
            CommandMenu(L10n.t(.aiMenu)) {
                AIMenu()
                    .environmentObject(delegate.appState)
            }
            CommandMenu(L10n.t(.importMenu)) {
                Button(L10n.t(.importFromITerm)) {
                    delegate.appState.importFrom(.iterm2, windowID: nil)
                }
                Button(L10n.t(.importFromTerminal)) {
                    delegate.appState.importFrom(.terminalApp, windowID: nil)
                }
            }
            CommandGroup(after: .appInfo) {
                Button(L10n.t(.checkForUpdates)) { delegate.updater.checkNow() }
            }
        }

        Settings {
            SettingsView(updater: delegate.updater)
                .environmentObject(delegate.appState)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(delegate.appState)
        } label: {
            MenuBarLabel()
                .environmentObject(delegate.appState)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var updater: UpdateService

    var body: some View {
        TabView {
            general
                .tabItem { Label(L10n.t(.generalTab), systemImage: "gearshape") }
            InfoTab()
                .tabItem { Label(L10n.t(.infoTab), systemImage: "info.circle") }
        }
        .frame(width: 440)
    }

    private var general: some View {
        Form {
            Section(L10n.t(.language)) {
                Picker(L10n.t(.language), selection: $appState.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .help(L10n.t(.languageHelp))
            }
            Section(L10n.t(.appearance)) {
                Picker(L10n.t(.appearance), selection: $appState.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(L10n.t(.appearanceHelp))
            }
            Section(L10n.t(.aiSection)) {
                Toggle(L10n.t(.aiActive), isOn: $appState.aiEnabled)
                    .help(appState.aiEnabled ? L10n.t(.aiAssistOnHelp) : L10n.t(.aiAssistOffHelp))
                Text(L10n.t(.aiExplanation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.t(.durableSection)) {
                Toggle(L10n.t(.durableActive), isOn: $appState.durableTerminals)
                    .disabled(!Durable.isAvailable)
                    .help(L10n.t(.durableHelp))
                Text(L10n.t(Durable.isAvailable ? .durableExplanation : .durableMissingTmux))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.t(.updates)) {
                Toggle(L10n.t(.autoUpdateCheck), isOn: $appState.autoUpdateCheck)
                    .help(L10n.t(.autoUpdateHelp))
                HStack {
                    Button(L10n.t(.checkForUpdates)) { updater.checkNow() }
                        .disabled(updater.isChecking || updater.isInstalling)
                    if updater.isInstalling {
                        ProgressView().controlSize(.small)
                        Text(L10n.t(.updateInstalling)).foregroundStyle(.secondary)
                    }
                }
                if let staged = updater.stagedUpdate {
                    Label(
                        "\(L10n.t(.updatePendingQuit)) (\(staged.version))",
                        systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → Information: explains the status-color system.
struct InfoTab: View {
    private let states: [AttentionState] = [.ready, .running, .waiting, .error, .free]

    var body: some View {
        Form {
            Section(L10n.t(.colorLegendTitle)) {
                Text(L10n.t(.colorLegendIntro)).foregroundStyle(.secondary)
                ForEach(states, id: \.self) { state in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(state.tint).frame(width: 14, height: 14).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.label).fontWeight(.semibold)
                            Text(description(for: state))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func description(for state: AttentionState) -> String {
        switch state {
        case .ready: L10n.t(.readyDesc)
        case .running: L10n.t(.runningDesc)
        case .waiting: L10n.t(.waitingDesc)
        case .error: L10n.t(.errorDesc)
        case .free: L10n.t(.freeDesc)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let updater: UpdateService
    private var hookServer: HookServer?
    private(set) var isTerminating = false

    override init() {
        let state = MainActor.assumeIsolated { AppState() }
        self.appState = state
        self.updater = MainActor.assumeIsolated { UpdateService(appState: state) }
        super.init()
        // Wired here, not in applicationDidFinishLaunching: the restore dialog
        // runs a nested modal loop, and a click that launched the app would be
        // delivered (and lost) before the delegate existed.
        NotificationService.handleClicks { [weak state] id in
            MainActor.assumeIsolated { state?.focusSession(id) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { appState.appearance.apply() }

        MainActor.assumeIsolated {
            let saved = AppState.loadPersistedState()
            // Localize the dialog in the previously chosen language.
            L10n.current = saved?.language ?? .system
            if let saved, !saved.sessions.isEmpty {
                let alert = NSAlert()
                alert.messageText = L10n.t(.restoreTitle)
                alert.informativeText = L10n.t(.restoreBody, saved.sessions.count, saved.groups.count)
                alert.addButton(withTitle: L10n.t(.restore))
                alert.addButton(withTitle: L10n.t(.startFresh))
                if alert.runModal() == .alertFirstButtonReturn {
                    appState.applyRestore(saved)
                } else {
                    appState.startFresh(archiving: saved)
                }
            } else {
                appState.startFresh(archiving: nil)
            }
            // A banner click may have launched us — jump now that the
            // terminals exist.
            appState.flushPendingFocus()
        }

        NotificationService.requestAuthorization()

        let server = HookServer(appState: appState)
        server.start()
        hookServer = server

        // Auto-install the Claude Code hooks so attention events work with no
        // manual setup (idempotent; merges into ~/.claude/settings.json).
        DispatchQueue.global(qos: .utility).async { HookInstaller.installIfNeeded() }

        MainActor.assumeIsolated {
            // A run that was killed rather than quit may have left a verified
            // bundle behind; apply it at the *next* quit instead of losing it.
            updater.adoptStagedUpdateIfAny()
            updater.startAutoChecks()
        }
    }

    // Clicking the dock icon with no open window reopens one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // When the app is activated, guarantee a key window so keyboard input is
        // delivered (the launch modal + window restoration can leave none).
        if NSApp.keyWindow == nil {
            NSApp.windows.first { $0.canBecomeKey && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
    }

    // Flush state whenever we lose focus or hide, so an abrupt kill/crash while
    // in the background can't lose the workspace (on top of the debounced save
    // after every change and the save on quit).
    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { appState.saveNow(); appState.saveScrollbacks() }
    }

    func applicationDidHide(_ notification: Notification) {
        MainActor.assumeIsolated { appState.saveNow(); appState.saveScrollbacks() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting kills the PTYs: a running turn is lost, and restore can only
        // resume the conversation, not the work in flight. Ask first — except
        // for durable terminals, whose agents live in tmux and are still there
        // when we come back. Warning about those would be a lie in the other
        // direction, and would train the user to click through the dialog.
        let reply: NSApplication.TerminateReply = MainActor.assumeIsolated {
            let running = appState.sessions.values
                .filter { $0.state == .running && !$0.durable }.count
            guard running > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = L10n.t(.quitWhileRunningTitle)
            alert.informativeText = L10n.t(.quitWhileRunningBody, running)
            alert.addButton(withTitle: L10n.t(.quitAnyway))
            alert.addButton(withTitle: L10n.t(.cancel))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        guard reply == .terminateNow else { return reply }
        isTerminating = true
        MainActor.assumeIsolated {
            appState.saveNow()
            appState.saveScrollbacks()
            // State is on disk first: the swap helper starts the moment we exit,
            // and the next launch must read the state this run wrote.
            updater.applyStagedUpdateOnQuit()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { appState.saveNow() }
        hookServer?.stop()
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarMinified") private var sidebarMinified = false
    @AppStorage("inboxShown") private var inboxShown = false
    let windowID: UUID

    // A window whose id has no model (e.g. one macOS restored from a previous
    // session) redirects to the main window model instead of sitting blank or
    // being closed — guaranteeing there's always at least one usable window.
    private var resolvedWindow: WindowModel? {
        appState.window(for: windowID) ?? appState.window(for: AppState.mainWindowID)
    }
    private var isMainWindow: Bool { windowID == AppState.mainWindowID }

    var body: some View {
        Group {
            if let window = resolvedWindow {
                HSplitView {
                    // Left "Projects" panel — a body panel (below the toolbar),
                    // symmetric with the Notifications panel on the right.
                    if sidebarMinified {
                        SidebarView(windowID: window.id)
                            .frame(width: 60)
                            .frame(maxHeight: .infinity)
                    } else {
                        SidebarView(windowID: window.id)
                            .frame(minWidth: 210, idealWidth: 250, maxWidth: 400,
                                   maxHeight: .infinity)
                    }

                    Group {
                        // A selected folder shows what is inside it; otherwise
                        // the selected project's terminals.
                        if let folderID = window.selectedFolderID,
                           let folder = window.folders.first(where: { $0.id == folderID }) {
                            FolderOverviewView(folder: folder, windowID: window.id)
                        } else if let groupID = window.selectedGroupID,
                                  let group = appState.groups.first(where: { $0.id == groupID }) {
                            TerminalAreaView(group: group)
                        } else {
                            welcome
                        }
                    }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                    if inboxShown {
                        // Persistent, drag-resizable notification sidebar.
                        AttentionPanel(windowID: window.id)
                            .frame(minWidth: 240, idealWidth: 300, maxWidth: 520,
                                   maxHeight: .infinity)
                    }
                }
                .background(WindowAccessor(windowID: window.id))
                .toolbar { toolbarContent(window: window) }
                .sheet(isPresented: switcherBinding(window.id)) {
                    QuickSwitcherView()
                }
                .onChange(of: appState.windowsToOpen) { _, toOpen in
                    guard isMainWindow else { return }
                    for id in toOpen { openWindow(value: id) }
                    if !toOpen.isEmpty { appState.windowsToOpen = [] }
                }
                .onAppear {
                    guard isMainWindow else { return }
                    let toOpen = appState.windowsToOpen
                    for id in toOpen { openWindow(value: id) }
                    if !toOpen.isEmpty { appState.windowsToOpen = [] }
                }
            } else {
                // No model at all yet (very first render before restore) —
                // transient; show the welcome screen rather than a blank window.
                welcome
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(window: WindowModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            InboxToolbarButton(shown: $inboxShown)
        }
        if !isMainWindow {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let id = window.id
                    appState.mergeWindow(id, into: appState.windows.first?.id)
                    WindowRegistry.shared.close(id)
                } label: {
                    Label(L10n.t(.mergeIntoMain), systemImage: "rectangle.stack")
                }
                .help(L10n.t(.mergeIntoMainHelp))
            }
        }
    }

    private func switcherBinding(_ windowID: UUID) -> Binding<Bool> {
        Binding(
            get: { appState.quickSwitcherWindowID == windowID },
            set: { shown in if !shown { appState.quickSwitcherWindowID = nil } }
        )
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
            Text("Planchette").font(.largeTitle.bold())
            Text(L10n.t(.tagline))
                .foregroundStyle(.secondary)
            Button(L10n.t(.openFirstTerminal)) {
                if let id = resolvedWindow?.id { appState.promptNewTerminal(inWindow: id) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            // The whole point of arrangements: after "Start fresh" the saved
            // workspaces are right here, one click from being back.
            if !appState.presets.isEmpty, let windowID = resolvedWindow?.id {
                ArrangementLauncher(windowID: windowID)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Saved arrangements on the welcome screen — name, size, and one click to
/// build the whole thing.
struct ArrangementLauncher: View {
    @EnvironmentObject var appState: AppState
    let windowID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t(.savedArrangements))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(appState.presets) { preset in
                Button {
                    appState.openPreset(preset, inWindow: windowID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name).fontWeight(.medium)
                            Text(L10n.t(.arrangementSummary, preset.projects.count, preset.terminalCount))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(L10n.t(.openArrangement))
                            .font(.caption).foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: 340, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(preset.projects.map(\.name).joined(separator: ", "))
                .contextMenu {
                    Button(L10n.t(.renameArrangement)) {
                        appState.promptText(
                            title: L10n.t(.saveArrangementTitle), value: preset.name
                        ) { name in
                            appState.renamePreset(preset.id, to: name)
                        }
                    }
                    Divider()
                    Button(L10n.t(.deleteArrangement), role: .destructive) {
                        appState.deletePreset(preset.id)
                    }
                }
            }
        }
    }
}

/// Registers the hosting NSWindow in the WindowRegistry.
struct WindowAccessor: NSViewRepresentable {
    let windowID: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attach(nsView) }
    }

    private func attach(_ view: NSView) {
        guard let window = view.window else { return }
        // Stop macOS from restoring a blank duplicate window on next launch —
        // Planchette manages its own windows from persisted state.
        window.isRestorable = false
        WindowRegistry.shared.register(windowID, window: window)
        // After the launch modal + window restoration the app can end up with
        // no key window, which drops all keyboard input. Claim key status for a
        // real content window when none exists. Only while active: keyWindow is
        // always nil when the app is in the background, and ordering front from
        // there would raise/deminiaturize the window on every view update.
        if NSApp.isActive, NSApp.keyWindow == nil, window.canBecomeKey, !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// "Arrangements" menu: save what this window looks like, or open a saved one.
struct ArrangementsMenu: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(L10n.t(.saveArrangement)) { appState.promptSaveArrangementInKeyWindow() }
            .help(L10n.t(.saveArrangementHelp))
        Divider()
        if appState.presets.isEmpty {
            Text(L10n.t(.noArrangements))
        } else {
            ForEach(appState.presets) { preset in
                Button("\(preset.name) — \(L10n.t(.arrangementSummary, preset.projects.count, preset.terminalCount))") {
                    appState.openPresetInKeyWindow(preset)
                }
            }
        }
    }
}

struct AIMenu: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Toggle(L10n.t(.aiActive), isOn: $appState.aiEnabled)
            .help(appState.aiEnabled ? L10n.t(.aiAssistOnHelp) : L10n.t(.aiAssistOffHelp))
        Divider()
        Button(L10n.t(.summarizeAll)) { appState.summarizeAllNow() }
            .disabled(!appState.aiEnabled)
            .help(L10n.t(.summarizeAllHelp))
        Button(L10n.t(.groupByTopic)) { proposeGrouping() }
            .disabled(!appState.aiEnabled)
            .help(L10n.t(.groupByTopicHelp))
    }

    private func proposeGrouping() {
        let proposal = appState.topicProposal
        let alert = NSAlert()
        if proposal.isEmpty {
            alert.messageText = L10n.t(.noGroupingTitle)
            alert.informativeText = L10n.t(.noGroupingBody)
            alert.runModal()
            return
        }
        alert.messageText = L10n.t(.groupByTopicTitle)
        alert.informativeText = proposal
            .map { "\($0.topic): \($0.sessions.map(\.displayTitle).joined(separator: ", "))" }
            .joined(separator: "\n")
        alert.addButton(withTitle: L10n.t(.group))
        alert.addButton(withTitle: L10n.t(.cancel))
        if alert.runModal() == .alertFirstButtonReturn {
            appState.applyTopicGrouping()
        }
    }
}

/// Top-right bell: toggles the persistent notifications sidebar, with a live
/// count badge to its left.
struct InboxToolbarButton: View {
    @EnvironmentObject var appState: AppState
    @Binding var shown: Bool

    var body: some View {
        let count = appState.attentionQueue.count
        Button {
            shown.toggle()
        } label: {
            HStack(spacing: 4) {
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(appState.errorCount > 0 ? .red : .blue, in: Capsule())
                }
                Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
                    .symbolRenderingMode(count > 0 ? .multicolor : .monochrome)
            }
        }
        .help(L10n.t(.notificationsPanelHelp))
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let waiting = appState.waitingCount
        let errors = appState.errorCount
        if waiting == 0 && errors == 0 {
            Image(systemName: "moon.zzz")
        } else {
            Text([errors > 0 ? "\(errors)🔴" : nil, waiting > 0 ? "\(waiting)🔵" : nil]
                .compactMap(\.self).joined(separator: " "))
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let queue = appState.attentionQueue
        if queue.isEmpty {
            Text(L10n.t(.allQuietShort))
        } else {
            ForEach(queue) { session in
                Button("\(session.state == .error ? "🔴" : "🔵") \(session.displayTitle) — \(session.shortPath)") {
                    NSApp.activate(ignoringOtherApps: true)
                    appState.select(session: session)
                }
            }
        }
        Divider()
        Button(L10n.t(.openPlanchette)) { NSApp.activate(ignoringOtherApps: true) }
    }
}

extension AppState {
    /// Folder picker → new session in the given window (reusing a group whose
    /// sessions already live in that folder).
    func promptNewTerminal(inWindow windowID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.t(.chooseFolder)
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("development")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let dir = url.path
        let window = window(for: windowID)
        let existing = window.map { groups(inWindow: $0) }?.first { group in
            sessions(in: group).contains { $0.workingDirectory == dir }
        }
        let group = existing ?? addGroup(name: (dir as NSString).lastPathComponent, inWindow: windowID)
        let session = addSession(directory: dir, groupID: group.id)
        select(session: session)
    }

    /// ⌘T from the menu: target whichever window is key.
    func promptNewTerminalInKeyWindow() {
        let windowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id
        guard let windowID else { return }
        promptNewTerminal(inWindow: windowID)
    }

    /// Folder picker → always create a NEW project (group) with a first terminal.
    func promptNewProject(inWindow windowID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.t(.chooseFolder)
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("development")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = url.path
        let group = addGroup(name: (dir as NSString).lastPathComponent, inWindow: windowID)
        let session = addSession(directory: dir, groupID: group.id)
        select(session: session)
    }

    /// Ask for a branch and open a git worktree of the *current* project as a
    /// project of its own. The repo comes from the focused terminal, so this is
    /// "another branch of what I'm looking at" — the way several agents end up
    /// working on one repo at once.
    func promptNewWorktree() {
        let windowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id
        guard let windowID,
              let window = window(for: windowID),
              let groupID = window.selectedGroupID,
              let group = groups.first(where: { $0.id == groupID }),
              let sessionID = group.activeSessionID ?? group.sessionIDs.first,
              let session = sessions[sessionID]
        else { return }
        let directory = session.currentDirectory
        promptText(title: L10n.t(.worktreeBranchPrompt), value: "") { [weak self] branch in
            let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return }
            self?.newWorktreeProject(fromDirectory: directory, branch: branch, base: nil)
        }
    }

    /// Modal one-line text prompt (rename, startup command, …) shared by the
    /// sidebar, tab bar, and notifications panel context menus.
    func promptText(title: String, value: String, apply: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            apply(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Rename a terminal (empty input restores the automatic title). The name
    /// is the session's `customTitle`, which `displayTitle` prefers — so tabs,
    /// sidebar, notifications panel, and quick switcher all pick it up.
    func promptRename(session: TerminalSession) {
        promptText(title: L10n.t(.renameTerminal), value: session.customTitle ?? "") { name in
            self.update(session.id) { $0.customTitle = name.isEmpty ? nil : name }
        }
    }

    /// Edit the command re-run when this terminal is restored.
    func promptStartupCommand(session: TerminalSession) {
        promptText(
            title: L10n.t(.startupCommandPrompt),
            value: session.startupCommand ?? ""
        ) { command in
            self.update(session.id) { $0.startupCommand = command.isEmpty ? nil : command }
        }
    }

    /// Ask for a name and create a sidebar folder, optionally putting a project
    /// straight into it.
    func promptNewFolder(inWindow windowID: UUID, containing groupID: UUID? = nil) {
        promptText(title: L10n.t(.newFolderTitle), value: "") { [weak self] name in
            guard !name.isEmpty else { return }
            self?.addFolder(name: name, inWindow: windowID, containing: groupID)
        }
    }

    /// Save the key window's projects and terminals as a named arrangement.
    func promptSaveArrangementInKeyWindow() {
        guard let windowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id else { return }
        promptText(title: L10n.t(.saveArrangementTitle), value: "") { [weak self] name in
            self?.savePreset(name: name, fromWindow: windowID)
        }
    }

    func openPresetInKeyWindow(_ preset: Preset) {
        guard let windowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id else { return }
        openPreset(preset, inWindow: windowID)
    }

    /// Add a terminal to an existing group, in that group's folder.
    func addTerminalToGroup(_ groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        // Use the folder of an existing session in the group, else the group name.
        let dir = sessions(in: group).first?.currentDirectory
            ?? sessions(in: group).first?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let session = addSession(directory: dir, groupID: groupID)
        select(session: session)
    }
}

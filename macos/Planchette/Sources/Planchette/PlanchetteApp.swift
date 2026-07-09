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
                Button(L10n.t(.quickSwitcher)) { delegate.appState.showQuickSwitcher() }
                    .keyboardShortcut("k")
                Button(L10n.t(.jumpToWaiting)) { delegate.appState.jumpToNextWaiting() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
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
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → Information: explains the status-color system.
struct InfoTab: View {
    private let states: [AttentionState] = [.ready, .running, .waiting, .error]

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
        }

        NotificationService.requestAuthorization()

        let server = HookServer(appState: appState)
        server.start()
        hookServer = server

        MainActor.assumeIsolated { updater.autoCheckIfEnabled() }
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
        MainActor.assumeIsolated { appState.saveNow() }
    }

    func applicationDidHide(_ notification: Notification) {
        MainActor.assumeIsolated { appState.saveNow() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        MainActor.assumeIsolated { appState.saveNow() }
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
                        if let groupID = window.selectedGroupID,
                           let group = appState.groups.first(where: { $0.id == groupID }) {
                            TerminalAreaView(group: group)
                        } else {
                            welcome
                        }
                    }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                    if inboxShown {
                        // Persistent, drag-resizable notification sidebar.
                        AttentionPanel()
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
            Text("🔮").font(.system(size: 56))
            Text("Planchette").font(.largeTitle.bold())
            Text(L10n.t(.tagline))
                .foregroundStyle(.secondary)
            Button(L10n.t(.openFirstTerminal)) {
                if let id = resolvedWindow?.id { appState.promptNewTerminal(inWindow: id) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // real content window when none exists.
        if NSApp.keyWindow == nil, window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
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

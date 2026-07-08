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
                Button(L10n.t(.checkForUpdates)) { updater.checkNow() }
                    .disabled(updater.isChecking)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .navigationTitle(L10n.t(.settingsTitle))
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

        let server = HookServer(appState: appState)
        server.start()
        hookServer = server

        MainActor.assumeIsolated { updater.autoCheckIfEnabled() }
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
    let windowID: UUID

    private var resolvedWindow: WindowModel? { appState.window(for: windowID) }
    private var isMainWindow: Bool { windowID == AppState.mainWindowID }

    var body: some View {
        Group {
            if let window = resolvedWindow {
                NavigationSplitView {
                    SidebarView(windowID: window.id)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 250)
                } detail: {
                    if let groupID = window.selectedGroupID,
                       let group = appState.groups.first(where: { $0.id == groupID }) {
                        TerminalAreaView(group: group)
                    } else {
                        welcome
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
                // The window's model was merged away — nothing to show.
                Text(L10n.t(.windowMerged)).padding()
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(window: WindowModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            InboxToolbarButton()
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
        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.promptNewTerminal(inWindow: window.id)
            } label: {
                Label(L10n.t(.newTerminal), systemImage: "plus")
            }
            .help(L10n.t(.newTerminalHelp))
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
        DispatchQueue.main.async {
            if let window = view.window {
                WindowRegistry.shared.register(windowID, window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                WindowRegistry.shared.register(windowID, window: window)
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

struct InboxToolbarButton: View {
    @EnvironmentObject var appState: AppState
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label(L10n.t(.inbox), systemImage: "bell")
                .overlay(alignment: .topTrailing) {
                    let count = appState.attentionQueue.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(appState.askingCount > 0 ? .orange : .green, in: Circle())
                            .offset(x: 7, y: -7)
                    }
                }
        }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            InboxView()
        }
        .help(L10n.t(.inboxHelp))
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let asking = appState.askingCount
        let done = appState.doneCount
        if asking == 0 && done == 0 {
            Image(systemName: "moon.zzz")
        } else {
            Text([asking > 0 ? "\(asking)❓" : nil, done > 0 ? "\(done)✅" : nil]
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
                Button("\(session.state == .asking ? "❓" : "✅") \(session.displayTitle) — \(session.shortPath)") {
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
}

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
                Button("Neues Fenster") {
                    openWindow(value: delegate.appState.newWindow())
                }
                .keyboardShortcut("n")
            }
            CommandMenu("Session") {
                Button("Neues Terminal…") { delegate.appState.promptNewTerminalInKeyWindow() }
                    .keyboardShortcut("t")
                Button("Quick Switcher") { delegate.appState.showQuickSwitcher() }
                    .keyboardShortcut("k")
                Button("Zur wartenden Session") { delegate.appState.jumpToNextWaiting() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandMenu("KI") {
                AIMenu()
                    .environmentObject(delegate.appState)
            }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    private var hookServer: HookServer?
    private(set) var isTerminating = false

    override init() {
        self.appState = MainActor.assumeIsolated { AppState() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        MainActor.assumeIsolated {
            let saved = AppState.loadPersistedState()
            if let saved, !saved.sessions.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Letzte Sitzung wiederherstellen?"
                alert.informativeText = """
                \(saved.sessions.count) Terminal(s) in \(saved.groups.count) Gruppe(n). \
                Claude-Sessions werden fortgesetzt, Startup-Commands laufen erneut an.
                """
                alert.addButton(withTitle: "Wiederherstellen")
                alert.addButton(withTitle: "Neu starten")
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
                Text("Fenster wurde zusammengeführt").padding()
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(window: WindowModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $appState.aiEnabled) {
                Label("KI-Assistenz", systemImage: appState.aiEnabled ? "sparkles" : "sparkles.slash")
            }
            .toggleStyle(.button)
            .help(appState.aiEnabled
                ? "KI-Assistenz aktiv: Sessions werden zusammengefasst und geordnet"
                : "KI-Assistenz aus")
        }
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
                    Label("In Hauptfenster mergen", systemImage: "rectangle.stack")
                }
                .help("Alle Gruppen dieses Fensters ins Hauptfenster verschieben")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.promptNewTerminal(inWindow: window.id)
            } label: {
                Label("Neues Terminal", systemImage: "plus")
            }
            .help("Neues Terminal (⌘T)")
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
            Text("points you to the session that speaks")
                .foregroundStyle(.secondary)
            Button("Erstes Terminal öffnen (⌘T)") {
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
        Toggle("KI-Assistenz aktiv", isOn: $appState.aiEnabled)
        Divider()
        Button("Alle Sessions jetzt zusammenfassen") { appState.summarizeAllNow() }
            .disabled(!appState.aiEnabled)
        Button("Nach Themen gruppieren…") { proposeGrouping() }
            .disabled(!appState.aiEnabled)
    }

    private func proposeGrouping() {
        let proposal = appState.topicProposal
        let alert = NSAlert()
        if proposal.isEmpty {
            alert.messageText = "Kein Gruppierungs-Vorschlag"
            alert.informativeText = "Noch keine (oder zu wenige) Sessions mit gleichem Thema. Erst zusammenfassen lassen."
            alert.runModal()
            return
        }
        alert.messageText = "Nach Themen gruppieren?"
        alert.informativeText = proposal
            .map { "\($0.topic): \($0.sessions.map(\.displayTitle).joined(separator: ", "))" }
            .joined(separator: "\n")
        alert.addButton(withTitle: "Gruppieren")
        alert.addButton(withTitle: "Abbrechen")
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
            Label("Inbox", systemImage: "bell")
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
        .help("Aufmerksamkeits-Inbox")
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
            Text("Alles ruhig")
        } else {
            ForEach(queue) { session in
                Button("\(session.state == .asking ? "❓" : "✅") \(session.displayTitle) — \(session.shortPath)") {
                    NSApp.activate(ignoringOtherApps: true)
                    appState.select(session: session)
                }
            }
        }
        Divider()
        Button("Planchette öffnen") { NSApp.activate(ignoringOtherApps: true) }
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
        panel.message = "Projektordner für das neue Terminal wählen"
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

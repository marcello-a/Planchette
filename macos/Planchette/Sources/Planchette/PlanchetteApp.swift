import SwiftUI

@main
struct PlanchetteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Planchette") {
            ContentView()
                .environmentObject(delegate.appState)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .commands {
            CommandMenu("Session") {
                Button("Neues Terminal…") { delegate.appState.promptNewTerminal() }
                    .keyboardShortcut("t")
                Button("Quick Switcher") { delegate.appState.quickSwitcherShown = true }
                    .keyboardShortcut("k")
                Button("Zur wartenden Session") { delegate.appState.jumpToNextWaiting() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
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

    override init() {
        self.appState = MainActor.assumeIsolated { AppState() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let server = HookServer(appState: appState)
        server.start()
        hookServer = server
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { appState.saveNow() }
        hookServer?.stop()
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            if let group = appState.selectedGroup {
                TerminalAreaView(group: group)
            } else {
                welcome
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                InboxToolbarButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.promptNewTerminal()
                } label: {
                    Label("Neues Terminal", systemImage: "plus")
                }
                .help("Neues Terminal (⌘T)")
            }
        }
        .sheet(isPresented: $appState.quickSwitcherShown) {
            QuickSwitcherView()
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Text("🔮").font(.system(size: 56))
            Text("Planchette").font(.largeTitle.bold())
            Text("points you to the session that speaks")
                .foregroundStyle(.secondary)
            Button("Erstes Terminal öffnen (⌘T)") { appState.promptNewTerminal() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// Folder picker → new session (creating a group per folder by default).
    func promptNewTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Projektordner für das neue Terminal wählen"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("development")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let dir = url.path
        // Reuse an existing group whose sessions live in the same folder.
        let existing = groups.first { group in
            sessions(in: group).contains { $0.workingDirectory == dir }
        }
        if let existing {
            let session = addSession(directory: dir, groupID: existing.id)
            select(session: session)
        } else {
            let group = addGroup(name: (dir as NSString).lastPathComponent)
            let session = addSession(directory: dir, groupID: group.id)
            select(session: session)
        }
    }
}

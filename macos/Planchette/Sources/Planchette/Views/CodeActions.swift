import AppKit
import SwiftUI

/// Clickable chips for a project's running dev servers — THE one way a dev
/// server is shown (project header, folder overview), so a running server
/// always has its link on screen wherever the project is.
///
/// The chip is the port and nothing else. Where it leads is what the server
/// announced (`https://vite.myposter.de:8082`), which the tooltip spells out —
/// a row of chips all reading "localhost:" only repeats a word.
struct DevServerChips: View {
    @EnvironmentObject var appState: AppState
    let groupID: UUID

    var body: some View {
        let servers = appState.devServers[groupID] ?? []
        HStack(spacing: 4) {
            ForEach(servers) { server in
                Button {
                    NSWorkspace.shared.open(server.url)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "network")
                            .font(.caption2)
                        Text(server.label)
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.16), in: Capsule())
                    .foregroundStyle(.green)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.t(
                    .devServerHelp, server.url.absoluteString, server.processName))
            }
        }
    }
}

/// "Look at code" — hand this project to an IDE. It lives in a tab's right-click menu.
///
/// The first item opens: the project's own IDE when its checkout names one
/// (`.idea` → JetBrains, `.vscode` → VS Code), else the IDE you last worked
/// in. With nothing to go on it is left out, and "Open in" asks instead. "Open in"
/// lists every installed IDE; the default submenu is where an IDE becomes the default.
struct IDEMenuItems: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup

    var body: some View {
        if let directory = appState.projectDirectory(of: group),
           !appState.installedIDEs.isEmpty {
            let target = appState.ideTarget(for: group)
            let entries = IDEMenuEntry.entries(
                directory: directory, installed: appState.installedIDEs,
                running: appState.runningIDEs, defaultBundleID: appState.defaultIDEBundleID,
                target: target)
            if let target {
                Button(L10n.t(.lookAtCode)) {
                    SpaceSwitchPrompt.askIfNeeded(appState: appState)
                    IDEs.open(directory: directory, in: target)
                }
                // Say which of the two things the item does: take you to a window
                // that exists, or open the project somewhere new.
                .help(appState.ideAlreadyOpen(group, in: target)
                    ? L10n.t(.lookAtCodeOpenHelp, target.name)
                    : L10n.t(.lookAtCodeHelp, target.name))
            }
            Menu(L10n.t(.openInIDE)) {
                ForEach(entries) { entry in
                    // A dash would mark a running IDE in an AppKit menu; here the name says it.
                    Button(entry.title) {
                        SpaceSwitchPrompt.askIfNeeded(appState: appState)
                        IDEs.open(directory: directory, in: entry.ide)
                    }
                    .disabled(!entry.isEnabled)
                }
            }
            .help(L10n.t(.openNewIDEHelp))
            Menu(L10n.t(.defaultIDEMenu)) {
                ForEach(entries) { entry in
                    Toggle(entry.ide.name, isOn: Binding(
                        get: { entry.isDefault },
                        set: { _ in appState.defaultIDEBundleID = entry.ide.bundleID }))
                }
                Divider()
                Toggle(L10n.t(.noDefaultIDE), isOn: Binding(
                    get: { appState.defaultIDEBundleID == nil },
                    set: { _ in appState.defaultIDEBundleID = nil }))
            }
            .help(L10n.t(.chooseIDEHelp))
        }
    }
}

/// One row of the "Open in" menu, worked out in one place so a test can read it:
/// every installed IDE, a running one marked, the one the first item opens named,
/// and one that cannot open this checkout (Xcode without a project file) listed but
/// disabled — a menu whose items come and go makes you wonder whether the feature exists.
struct IDEMenuEntry: Identifiable, Equatable {
    let ide: IDE
    let isEnabled: Bool
    let isRunning: Bool
    let isTarget: Bool
    let isDefault: Bool

    var id: String { ide.bundleID }

    var title: String {
        isRunning ? "\(ide.name) ●" : ide.name
    }

    static func entries(
        directory: String, installed: [IDE], running: Set<String>,
        defaultBundleID: String?, target: IDE?
    ) -> [IDEMenuEntry] {
        installed.map { ide in
            IDEMenuEntry(
                ide: ide,
                isEnabled: IDEs.target(directory: directory, for: ide) != nil,
                isRunning: running.contains(ide.bundleID),
                isTarget: ide == target,
                isDefault: defaultBundleID == ide.bundleID)
        }
    }
}

/// The one thing standing between "look at code" and the window it means: an
/// IDE window on another Space cannot be brought here by any application, only
/// by macOS itself, and macOS only comes along when the Dock's "switch to a
/// Space with open windows" is on — off by default.
///
/// So the button asks, once, at the moment it matters, while Planchette is
/// still the app in front. Answering it is what makes the feature work on a
/// machine with more than one Space; declining leaves the system untouched and
/// is never asked again.
@MainActor
enum SpaceSwitchPrompt {
    static func askIfNeeded(appState: AppState) {
        guard !appState.askedAboutSpaceSwitching, !IDEs.followsSpaces() else { return }
        appState.askedAboutSpaceSwitching = true
        let alert = NSAlert()
        alert.messageText = L10n.t(.spaceSwitchTitle)
        alert.informativeText = L10n.t(.spaceSwitchBody)
        alert.addButton(withTitle: L10n.t(.spaceSwitchEnable))
        alert.addButton(withTitle: L10n.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        IDEs.enableSpaceSwitching()
    }
}

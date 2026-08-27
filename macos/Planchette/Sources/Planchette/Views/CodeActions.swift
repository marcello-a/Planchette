import AppKit
import SwiftUI

/// Clickable `localhost:<port>` chips for a project's running dev servers —
/// THE one way a dev server is shown (project header, folder overview), so a
/// running server always has its link on screen wherever the project is.
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
                .help(L10n.t(.devServerHelp, server.processName, server.directory))
            }
        }
    }
}

/// "Look at code" — hand this project to an IDE. One click opens the default
/// IDE (or the one already running); the menu lists every installed IDE and
/// carries the default choice, marked with a checkmark. With no IDE running
/// and none chosen, the button reads "open a new IDE" and is the picker.
struct IDEButton: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup

    var body: some View {
        if let directory = appState.projectDirectory(of: group) {
            button(directory: directory)
        }
    }

    @ViewBuilder
    private func button(directory: String) -> some View {
        let installed = IDEs.installed()
        let target = IDEs.target(
            defaultBundleID: appState.defaultIDEBundleID,
            running: appState.runningIDEs,
            installed: installed)
        if !installed.isEmpty {
            Group {
                if let target {
                    // One click opens the IDE; the chevron opens the menu.
                    Menu {
                        menuItems(installed: installed, directory: directory)
                    } label: {
                        label(target: target)
                    } primaryAction: {
                        IDEs.open(directory: directory, in: target)
                    }
                } else {
                    // Nothing to open yet: the whole button is the picker.
                    Menu {
                        menuItems(installed: installed, directory: directory)
                    } label: {
                        label(target: nil)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(target.map { L10n.t(.lookAtCodeHelp, $0.name) } ?? L10n.t(.openNewIDEHelp))
        }
    }

    private func label(target: IDE?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.caption)
            Text(target == nil ? L10n.t(.openNewIDE) : L10n.t(.lookAtCode))
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menuItems(installed: [IDE], directory: String) -> some View {
        ForEach(installed) { ide in
            Button {
                IDEs.open(directory: directory, in: ide)
            } label: {
                // A dot marks the IDEs already running — those focus instantly.
                Text(appState.runningIDEs.contains(ide.bundleID) ? "● \(ide.name)" : ide.name)
            }
        }
        Divider()
        Menu(L10n.t(.defaultIDEMenu)) {
            ForEach(installed) { ide in
                Button {
                    appState.defaultIDEBundleID = ide.bundleID
                } label: {
                    if appState.defaultIDEBundleID == ide.bundleID {
                        Label(ide.name, systemImage: "checkmark")
                    } else {
                        Text(ide.name)
                    }
                }
            }
            Divider()
            Button {
                appState.defaultIDEBundleID = nil
            } label: {
                if appState.defaultIDEBundleID == nil {
                    Label(L10n.t(.noDefaultIDE), systemImage: "checkmark")
                } else {
                    Text(L10n.t(.noDefaultIDE))
                }
            }
        }
    }
}

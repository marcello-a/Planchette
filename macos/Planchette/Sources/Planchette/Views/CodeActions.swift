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

/// "Look at code" — hand this project to an IDE.
///
/// The left button opens: the project's own IDE when its checkout names one
/// (`.idea` → JetBrains, `.vscode` → VS Code), else the IDE you last worked
/// in. With nothing to go on it reads "open a new IDE" and asks instead.
/// The chevron always asks, and that menu is where an IDE becomes the default.
///
/// The menu is an `NSMenu`, like the terminal's own context menu: it has to
/// appear reliably next to a terminal surface, which is AppKit all the way down.
struct IDEButton: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup

    var body: some View {
        if let directory = appState.projectDirectory(of: group),
           !appState.installedIDEs.isEmpty {
            let target = appState.ideTarget(for: group)
            HStack(spacing: 1) {
                Button {
                    if let target {
                        SpaceSwitchPrompt.askIfNeeded(appState: appState)
                        IDEs.open(directory: directory, in: target)
                    } else {
                        showMenu(directory: directory, target: nil)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                        Text(target == nil ? L10n.t(.openNewIDE) : L10n.t(.lookAtCode))
                            .font(.caption)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                // Say which of the two things a click does: take you to a
                // window that exists, or open the project somewhere new.
                .help(target.map {
                    appState.ideAlreadyOpen(group, in: $0)
                        ? L10n.t(.lookAtCodeOpenHelp, $0.name)
                        : L10n.t(.lookAtCodeHelp, $0.name)
                } ?? L10n.t(.openNewIDEHelp))

                Button {
                    showMenu(directory: directory, target: target)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .padding(.horizontal, 3).padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .help(L10n.t(.chooseIDEHelp))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// Pop the IDE menu at the pointer.
    private func showMenu(directory: String, target: IDE?) {
        IDEMenuActions.shared.appState = appState
        let menu = IDEMenuActions.shared.menu(
            directory: directory,
            installed: appState.installedIDEs,
            running: appState.runningIDEs,
            defaultBundleID: appState.defaultIDEBundleID,
            target: target)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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

/// The target of the IDE menu's items. AppKit menus need an ObjC target, and a
/// SwiftUI view is not one; this holds the two actions and the state to apply
/// them to.
@MainActor
final class IDEMenuActions: NSObject {
    static let shared = IDEMenuActions()
    weak var appState: AppState?

    /// What an "open in …" item carries.
    final class Open: NSObject {
        let directory: String
        let ide: IDE
        init(directory: String, ide: IDE) {
            self.directory = directory
            self.ide = ide
        }
    }

    /// The whole menu, built in one place so a test can read it: every
    /// installed IDE (running ones marked, the one a click would open in bold,
    /// one that cannot open this checkout disabled), then the default choice
    /// with a checkmark on it.
    func menu(
        directory: String, installed: [IDE], running: Set<String>,
        defaultBundleID: String?, target: IDE?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: L10n.t(.openInIDE), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for ide in installed {
            let item = NSMenuItem(
                title: ide.name, action: #selector(open(_:)), keyEquivalent: "")
            item.representedObject = Open(directory: directory, ide: ide)
            item.target = self
            // A dash marks what is running: those focus a window instead of
            // starting a cold launch.
            item.state = running.contains(ide.bundleID) ? .mixed : .off
            // An IDE that cannot open this checkout (Xcode without a project
            // file) stays listed but dead — a menu whose items come and go
            // makes you wonder whether the feature exists at all (the same
            // rule the terminal's own context menu follows).
            item.isEnabled = IDEs.target(directory: directory, for: ide) != nil
            if ide == target {
                item.attributedTitle = NSAttributedString(
                    string: ide.name,
                    attributes: [.font: NSFontManager.shared.convert(
                        NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)])
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let defaults = NSMenu()
        defaults.autoenablesItems = false
        for ide in installed {
            let item = NSMenuItem(
                title: ide.name, action: #selector(setDefault(_:)), keyEquivalent: "")
            item.representedObject = ide.bundleID
            item.target = self
            item.state = defaultBundleID == ide.bundleID ? .on : .off
            defaults.addItem(item)
        }
        defaults.addItem(.separator())
        let none = NSMenuItem(
            title: L10n.t(.noDefaultIDE), action: #selector(setDefault(_:)), keyEquivalent: "")
        none.target = self
        none.state = defaultBundleID == nil ? .on : .off
        defaults.addItem(none)

        let defaultsItem = NSMenuItem(
            title: L10n.t(.defaultIDEMenu), action: nil, keyEquivalent: "")
        defaultsItem.submenu = defaults
        menu.addItem(defaultsItem)
        return menu
    }

    @objc func open(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Open else { return }
        IDEs.open(directory: payload.directory, in: payload.ide)
    }

    @objc func setDefault(_ sender: NSMenuItem) {
        appState?.defaultIDEBundleID = sender.representedObject as? String
    }
}


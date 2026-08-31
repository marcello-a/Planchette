import AppKit

/// An editor/IDE Planchette can hand a project to.
struct IDE: Identifiable, Equatable {
    /// Stable identity — persisted as the default-IDE choice.
    let bundleID: String
    /// Display name — a proper noun, deliberately not localized.
    let name: String
    /// Which marker in a checkout points at this IDE (`.idea` for the JetBrains
    /// family, `.vscode` for the VS Code family, …). The single strongest hint
    /// about which IDE a project belongs to: it is written by the IDE itself.
    let marker: String
    /// Can it open a plain folder? Xcode cannot — handed a bare directory it
    /// opens a window and closes it again, which is exactly what "I just see a
    /// blank, then it closes" was. It needs a project file (see `target`).
    let opensFolders: Bool

    var id: String { bundleID }
}

/// The known IDEs, what is installed, what is running, which one a project
/// belongs to, and how to open it there.
///
/// Opening goes through the app itself (`open -a` semantics): an IDE that
/// already shows the folder focuses that window, one that doesn't opens it —
/// so "look at code" and "open a new IDE" are the same call.
enum IDEs {
    /// IDEs recognized on sight. The order is only the last tie-break; which
    /// one a click opens is decided by `resolve`.
    static let known: [IDE] = [
        IDE(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code",
            marker: ".vscode", opensFolders: true),
        IDE(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor",
            marker: ".cursor", opensFolders: true),
        IDE(bundleID: "com.exafunction.windsurf", name: "Windsurf",
            marker: ".windsurf", opensFolders: true),
        IDE(bundleID: "dev.zed.Zed", name: "Zed", marker: ".zed", opensFolders: true),
        IDE(bundleID: "com.jetbrains.WebStorm", name: "WebStorm",
            marker: ".idea", opensFolders: true),
        IDE(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA",
            marker: ".idea", opensFolders: true),
        IDE(bundleID: "com.jetbrains.intellij.ce", name: "IntelliJ IDEA CE",
            marker: ".idea", opensFolders: true),
        IDE(bundleID: "com.jetbrains.PhpStorm", name: "PhpStorm",
            marker: ".idea", opensFolders: true),
        IDE(bundleID: "com.jetbrains.pycharm", name: "PyCharm",
            marker: ".idea", opensFolders: true),
        IDE(bundleID: "com.apple.dt.Xcode", name: "Xcode",
            marker: "xcode", opensFolders: false),
        IDE(bundleID: "com.sublimetext.4", name: "Sublime Text",
            marker: ".sublime", opensFolders: true),
    ]

    static func ide(bundleID: String?) -> IDE? {
        known.first { $0.bundleID == bundleID }
    }

    /// The known IDEs present on this machine — what the menu lists.
    static func installed() -> [IDE] {
        known.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    /// Bundle IDs of the known IDEs currently running.
    static func runningBundleIDs() -> Set<String> {
        let knownIDs = Set(known.map(\.bundleID))
        return Set(NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter { knownIDs.contains($0) })
    }

    /// Which IDE markers a checkout carries. Read off disk, so it must run off
    /// the main thread; `AppState` collects it on the dev-server tick.
    ///
    /// This is what makes the button open the *right* IDE: a project with
    /// `.idea/` is a JetBrains project, whatever else happens to be running.
    static func markers(in directory: String) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for marker in [".idea", ".vscode", ".cursor", ".windsurf", ".zed", ".sublime"]
        where fm.fileExists(atPath: (directory as NSString).appendingPathComponent(marker)) {
            found.append(marker)
        }
        if xcodeTarget(in: directory) != nil { found.append("xcode") }
        return found
    }

    /// The file Xcode has to be handed for this checkout: a workspace, else a
    /// project, else a Swift package. Nil when there is none — then Xcode is no
    /// target at all.
    static func xcodeTarget(in directory: String) -> String? {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return (directory as NSString).appendingPathComponent(workspace)
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return (directory as NSString).appendingPathComponent(project)
        }
        if contents.contains("Package.swift") {
            return (directory as NSString).appendingPathComponent("Package.swift")
        }
        return nil
    }

    // MARK: Which IDE already has this project open

    /// Where each IDE family records the projects it currently has open. Read
    /// from the IDE's own state, because that is the only place the answer
    /// exists: another app's window titles are off limits without the screen
    /// recording permission, and Planchette is not asking for that.
    ///
    /// Support directory name per bundle id; JetBrains dirs carry the version
    /// (`PhpStorm2026.2`), so the name is a prefix.
    static let jetBrainsDirs: [String: String] = [
        "com.jetbrains.PhpStorm": "PhpStorm",
        "com.jetbrains.WebStorm": "WebStorm",
        "com.jetbrains.intellij": "IntelliJIdea",
        "com.jetbrains.intellij.ce": "IdeaIC",
        "com.jetbrains.pycharm": "PyCharm",
    ]

    static let vsCodeDirs: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
    ]

    /// The projects an IDE has open right now. Empty when the IDE keeps no
    /// readable record — then the other evidence decides.
    static func openProjects(of ide: IDE) -> Set<String> {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let product = jetBrainsDirs[ide.bundleID] {
            let jetBrains = support.appendingPathComponent("JetBrains", isDirectory: true)
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: jetBrains.path))
                ?? []
            var open: Set<String> = []
            for version in versions where version.hasPrefix(product) {
                let file = jetBrains.appendingPathComponent(
                    "\(version)/options/recentProjects.xml")
                guard let xml = try? String(contentsOf: file, encoding: .utf8) else { continue }
                open.formUnion(openJetBrainsProjects(inXML: xml, home: NSHomeDirectory()))
            }
            return open
        }
        if let product = vsCodeDirs[ide.bundleID] {
            let file = support.appendingPathComponent(
                "\(product)/User/globalStorage/storage.json")
            guard let data = try? Data(contentsOf: file) else { return [] }
            return openVSCodeProjects(inJSON: data)
        }
        return []
    }

    /// Pure: the `opened="true"` entries of a JetBrains `recentProjects.xml`,
    /// with `$USER_HOME$` expanded.
    static func openJetBrainsProjects(inXML xml: String, home: String) -> Set<String> {
        var open: Set<String> = []
        // Each entry is `<entry key="…"> <value> <RecentProjectMetaInfo … opened="true"`,
        // so an entry's key is the nearest one above its metadata.
        var key: String?
        for line in xml.split(whereSeparator: \.isNewline) {
            if let found = capture(line, after: "<entry key=\"") { key = found }
            guard line.contains("RecentProjectMetaInfo"), line.contains("opened=\"true\"") ,
                  let path = key
            else { continue }
            open.insert(path.replacingOccurrences(of: "$USER_HOME$", with: home))
            key = nil
        }
        return open
    }

    /// Pure: the folders a VS Code-family `storage.json` lists as open windows.
    static func openVSCodeProjects(inJSON data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["windowsState"] as? [String: Any]
        else { return [] }
        var open: Set<String> = []
        var windows = (state["openedWindows"] as? [[String: Any]]) ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        for window in windows {
            guard let folder = window["folder"] as? String,
                  let url = URL(string: folder), url.isFileURL
            else { continue }
            open.insert(url.path)
        }
        return open
    }

    /// The value of `attribute` on this line, up to the closing quote.
    private static func capture(_ line: Substring, after attribute: String) -> String? {
        guard let start = line.range(of: attribute) else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Pure: which IDE a click should open, best first.
    ///
    /// The order of evidence, strongest first:
    /// 1. **The IDE that already has this project open.** Then the click is not
    ///    "open somewhere" but "take me to the window that exists" — which is
    ///    what a button called "look at code" means, and it costs the user no
    ///    dialog: an IDE handed a project it already shows just focuses it.
    /// 2. **The default**, once chosen — that is what making it the default meant.
    /// 3. **The project's own marker.** A checkout with `.idea/` belongs to a
    ///    JetBrains IDE; picking VS Code because it happens to be first in a
    ///    list is how this shipped broken.
    /// 4. **The IDE you last worked in**, among those running.
    /// 5. Anything running, then anything installed.
    ///
    /// Xcode only counts when the checkout has something Xcode can open.
    static func resolve(
        markers: [String],
        defaultBundleID: String?,
        running: Set<String>,
        installed: [IDE],
        lastActivated: String? = nil,
        alreadyOpenIn: Set<String> = []
    ) -> IDE? {
        let candidates = installed.filter { $0.opensFolders || markers.contains($0.marker) }
        guard !candidates.isEmpty else { return nil }
        // An open window beats a preference: the default says which IDE to
        // *start*, and there is nothing to start when the project is on screen
        // already. Only a default that also has it open would win here anyway.
        if let open = candidates.first(where: { alreadyOpenIn.contains($0.bundleID) }) {
            // Among several, a chosen default still decides.
            if let chosen = ide(bundleID: defaultBundleID),
               alreadyOpenIn.contains(chosen.bundleID), candidates.contains(chosen) {
                return chosen
            }
            return open
        }
        if let chosen = ide(bundleID: defaultBundleID), candidates.contains(chosen) {
            return chosen
        }
        let scored = candidates.map { ide -> (ide: IDE, score: Int) in
            var score = 0
            if markers.contains(ide.marker) { score += 4 }
            if ide.bundleID == lastActivated { score += 2 }
            if running.contains(ide.bundleID) { score += 1 }
            return (ide, score)
        }
        // Nothing to go on at all (no marker, nothing running): the click has
        // no honest target — the button says "open a new IDE" and asks.
        guard let best = scored.max(by: { a, b in
            a.score != b.score
                ? a.score < b.score
                // Same score: keep the declared order (index in `known`).
                : (known.firstIndex(of: a.ide) ?? 0) > (known.firstIndex(of: b.ide) ?? 0)
        }), best.score > 0
        else { return nil }
        return best.ide
    }

    /// What to hand this IDE for this checkout: the folder, or Xcode's project
    /// file. Nil when the IDE cannot open this checkout at all.
    static func target(directory: String, for ide: IDE) -> String? {
        ide.opensFolders ? directory : xcodeTarget(in: directory)
    }

    /// Open a checkout in an IDE and **bring that IDE to the front**.
    ///
    /// The activation is the whole point, not a nicety. An IDE asked to open a
    /// folder it does not currently have open answers with a window of its own
    /// — PhpStorm asks "this window or a new one?" — and that window appears
    /// wherever the IDE already lives: behind Planchette, or on another Space.
    /// Without pulling the app forward, a click looks like it did nothing, and
    /// the modal it left behind swallows every further click. That is precisely
    /// how this shipped broken twice.
    ///
    /// Activated twice on purpose: once when the open call returns, once after
    /// the IDE has had a moment to put its window up, because activating an app
    /// before it has a window to show does not raise the window that follows.
    ///
    /// Failures are logged rather than swallowed: "nothing happened" is the one
    /// outcome a user cannot debug.
    static func open(directory: String, in ide: IDE) {
        guard let path = target(directory: directory, for: ide) else {
            NSLog("ide: \(ide.name) cannot open \(directory) — no project file")
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ide.bundleID)
        else {
            NSLog("ide: \(ide.name) not installed")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: ide.opensFolders)],
            withApplicationAt: appURL,
            configuration: configuration
        ) { app, error in
            if let error {
                NSLog("ide: opening \(path) in \(ide.name) failed: \(error)")
                return
            }
            guard let app else { return }
            raise(app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                raise(app)
                // An IDE can be frontmost and still show nothing: its windows
                // sit on another Space, or minimized in the Dock, and no app
                // may raise another app's window from outside. Then the click
                // *did* work and looks like it didn't — so say so instead of
                // leaving the user clicking a button that seems dead.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard !hasVisibleWindow(pid: app.processIdentifier) else { return }
                    NSLog("ide: \(ide.name) has no window on this Space")
                    // Two different dead ends, two different remedies: a window
                    // on another Space is one macOS checkbox away from working,
                    // a minimized one only the user can restore. Guessing which
                    // would send half the readers to the wrong setting.
                    let key: LKey = followsSpaces() ? .ideNoWindowMinimized : .ideNoWindowBody
                    NotificationService.post(
                        title: L10n.t(.ideNoWindowTitle, ide.name),
                        body: L10n.t(key, ide.name),
                        sessionID: nil)
                }
            }
        }
    }

    /// Does macOS follow an app to the Space its windows are on? The Dock's
    /// "When switching to an application, switch to a Space with open windows"
    /// — off unless the user turned it on, and the reason activating an IDE can
    /// leave you staring at the same screen. Read straight from the Dock's
    /// preferences; an absent key means the default, which is off.
    static func followsSpaces() -> Bool {
        UserDefaults(suiteName: "com.apple.dock")?
            .object(forKey: "workspaces-auto-swoosh") as? Bool ?? false
    }

    /// Does this app show a window where the user is looking? Asks
    /// CoreGraphics for the on-screen list and matches the pid — the owner and
    /// the geometry of a window are public, unlike its title, which is what the
    /// screen recording permission guards. Planchette needs neither.
    ///
    /// Menu-bar strips and other chrome are excluded by size: a real window is
    /// taller than a bar.
    static func hasVisibleWindow(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? Double
            else { return false }
            return height > 100
        }
    }

    /// Pull an app in front of us.
    ///
    /// Deliberately **not** `.activateAllWindows`: the IDE has just been told
    /// which project to show and has put that window in front of its own stack.
    /// Raising all of them instead surfaces whichever window happens to be on
    /// this Space — asking for one project and getting another one's window is
    /// worse than getting none.
    private static func raise(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate(from: .current)
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Make macOS follow an app to the Space its windows are on — the Dock's
    /// "When switching to an application, switch to a Space with open windows".
    ///
    /// This is the one switch that decides whether "look at code" can work at
    /// all for a window on another Space: no application may drag another
    /// application's window across Spaces, so if macOS does not come along,
    /// nothing can. Only ever called after the user says yes (see
    /// `SpaceSwitchPrompt`), and the Dock has to be restarted to read it.
    static func enableSpaceSwitching() {
        guard let defaults = UserDefaults(suiteName: "com.apple.dock") else { return }
        defaults.set(true, forKey: "workspaces-auto-swoosh")
        defaults.synchronize()
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Dock"]
        try? restart.run()
    }
}

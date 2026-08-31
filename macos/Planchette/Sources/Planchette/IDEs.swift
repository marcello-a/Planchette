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

    /// Pure: which IDE a click should open, best first.
    ///
    /// The order of evidence, strongest first:
    /// 1. **The default**, once chosen — that is what making it the default meant.
    /// 2. **The project's own marker.** A checkout with `.idea/` belongs to a
    ///    JetBrains IDE; picking VS Code because it happens to be first in a
    ///    list is how this shipped broken.
    /// 3. **The IDE you last worked in**, among those running.
    /// 4. Anything running, then anything installed.
    ///
    /// Xcode only counts when the checkout has something Xcode can open.
    static func resolve(
        markers: [String],
        defaultBundleID: String?,
        running: Set<String>,
        installed: [IDE],
        lastActivated: String? = nil
    ) -> IDE? {
        let candidates = installed.filter { $0.opensFolders || markers.contains($0.marker) }
        guard !candidates.isEmpty else { return nil }
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

    /// Open a checkout in an IDE. Focuses the existing window when the IDE
    /// already has it open, launches the IDE when it isn't running.
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
        let isDirectory = ide.opensFolders
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: isDirectory)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                NSLog("ide: opening \(path) in \(ide.name) failed: \(error)")
            }
        }
    }
}

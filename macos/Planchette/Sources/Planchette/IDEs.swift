import AppKit

/// An editor/IDE Planchette can hand a project to.
struct IDE: Identifiable, Equatable {
    /// Stable identity — persisted as the default-IDE choice.
    let bundleID: String
    /// Display name — a proper noun, deliberately not localized.
    let name: String

    var id: String { bundleID }
}

/// The known IDEs, what is installed, what is running, and how to open a
/// project in one. Opening always goes through the app itself (`open -a`
/// semantics): an IDE that already shows the folder focuses that window, one
/// that doesn't opens it — so "look at code" and "open a new IDE" are the
/// same call.
enum IDEs {
    /// IDEs recognized on sight. Order is the fallback preference when no
    /// default is set and several are running.
    static let known: [IDE] = [
        IDE(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        IDE(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        IDE(bundleID: "com.exafunction.windsurf", name: "Windsurf"),
        IDE(bundleID: "dev.zed.Zed", name: "Zed"),
        IDE(bundleID: "com.jetbrains.WebStorm", name: "WebStorm"),
        IDE(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
        IDE(bundleID: "com.jetbrains.intellij.ce", name: "IntelliJ IDEA CE"),
        IDE(bundleID: "com.jetbrains.PhpStorm", name: "PhpStorm"),
        IDE(bundleID: "com.jetbrains.pycharm", name: "PyCharm"),
        IDE(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
        IDE(bundleID: "com.sublimetext.4", name: "Sublime Text"),
    ]

    static func ide(bundleID: String?) -> IDE? {
        known.first { $0.bundleID == bundleID }
    }

    /// The known IDEs present on this machine — what the "open a new IDE"
    /// menu lists.
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

    /// Pure: which IDE a click should open. The default always wins — that is
    /// what making it the default meant — then a running IDE (in `known`
    /// order), then nothing: the caller shows the picker instead.
    static func target(
        defaultBundleID: String?, running: Set<String>, installed: [IDE]
    ) -> IDE? {
        if let ide = ide(bundleID: defaultBundleID), installed.contains(ide) { return ide }
        return installed.first { running.contains($0.bundleID) }
    }

    /// Open a directory in an IDE. Focuses the existing window when the IDE
    /// already has the folder open, launches the IDE when it isn't running.
    static func open(directory: String, in ide: IDE) {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ide.bundleID)
        else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: directory, isDirectory: true)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration())
    }
}

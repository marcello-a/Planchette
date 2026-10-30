import Foundation

/// The `review-pr` Claude Code skill a review runs as. A user who has one of their own keeps it;
/// a user who has none gets Planchette's default (`skills/review-pr` in the repository,
/// `Contents/Resources/skills/review-pr` in the app), installed in `~/.claude/skills/review-pr`
/// the first time a review starts.
///
/// The marker file `.planchette-default` beside the default's `SKILL.md` is the whole ownership
/// rule: with it, the folder is Planchette's and follows the bundled version; without it, the
/// folder is the user's and is never written. The plan is pure; `ensureInstalled` does the files
/// and must run off the main thread.
enum ReviewSkill {
    static let name = "review-pr"
    static let markerName = ".planchette-default"
    static let markerText = """
    This review-pr skill is Planchette's default. Planchette keeps it up to date while this file
    exists. To use your own skill, replace the folder's contents and delete this file.

    """

    enum Plan: Equatable {
        /// No skill of that name: the default goes in.
        case install
        /// Planchette's default, older than the bundled one.
        case update
        /// The default, as bundled.
        case upToDate
        /// A skill of the user's own: left alone.
        case keepUsersOwn
        /// Nothing to install from (a build without the folder), or an isolated instance.
        case unavailable
    }

    /// Pure: what to do, from what is in the skill folder and what is bundled.
    static func plan(installed: [String: Data]?, marker: Bool, bundled: [String: Data]?) -> Plan {
        guard let bundled, bundled["SKILL.md"] != nil else { return .unavailable }
        guard let installed, installed["SKILL.md"] != nil else { return .install }
        guard marker else { return .keepUsersOwn }
        return bundled.allSatisfy { installed[$0.key] == $0.value } ? .upToDate : .update
    }

    /// `~/.claude/skills/review-pr` — of the user record, as every other path of the app.
    static var userFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The bundled default: the app's resources, or the repository in a dev run.
    static var bundledFolder: URL? {
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("skills/\(name)", isDirectory: true),
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("SKILL.md").path) {
            return resources
        }
        // A dev run: this file is macos/Planchette/Sources/Planchette/<file>.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dev = root.appendingPathComponent("skills/\(name)", isDirectory: true)
        return FileManager.default.fileExists(atPath: dev.appendingPathComponent("SKILL.md").path) ? dev : nil
    }

    /// Every regular file below `folder`, by relative path. Nil when the folder is missing.
    static func files(in folder: URL) -> [String: Data]? {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return nil }
        var found: [String: Data] = [:]
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            guard !url.path.contains("/__pycache__/"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            found[String(path.dropFirst(base.count + 1))] = data
        }
        return found
    }

    /// Install or refresh the default when the plan says so. Returns what was done. An isolated
    /// instance never writes into the user's `~/.claude` (AGENTS.md: it does not run the hook
    /// installer either).
    @discardableResult
    static func ensureInstalled(
        into folder: URL = userFolder, from bundled: URL? = bundledFolder,
        isolated: Bool = SupportPaths.isIsolated
    ) -> Plan {
        guard !isolated, let bundled else { return .unavailable }
        let marker = folder.appendingPathComponent(markerName)
        let source = files(in: bundled)
        let plan = plan(
            installed: files(in: folder), marker: FileManager.default.fileExists(atPath: marker.path),
            bundled: source)
        guard plan == .install || plan == .update, let source else { return plan }
        do {
            for (relative, data) in source {
                let target = folder.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                if relative.hasPrefix("scripts/") {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                }
            }
            try Data(markerText.utf8).write(to: marker, options: .atomic)
        } catch {
            NSLog("review-pr skill install failed: \(error)")
            return .unavailable
        }
        return plan
    }
}

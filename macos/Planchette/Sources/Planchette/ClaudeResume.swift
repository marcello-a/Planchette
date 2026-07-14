import Foundation

/// Resolves which Claude conversation each restored terminal should resume —
/// as robustly as possible, because a Claude session should always come back.
///
/// All terminals of a restore are resolved TOGETHER (`resolveAll`): every
/// conversation can be claimed by at most one terminal. Resolving terminals
/// independently made all tabs of one project converge on the folder's newest
/// transcript whenever their exact records failed — and after one such
/// restore the hooks record that shared id into every tab, so they show the
/// same conversation forever.
///
/// Per-terminal preference, strong evidence first across ALL terminals, each
/// step guaranteeing (where it can) that the transcript actually exists on
/// disk so `claude --resume <id>` won't fail:
///   1. The transcript path we recorded for this exact terminal.
///   2. The recorded session id, if its transcript exists for this project.
///   3. The most recent UNCLAIMED transcript in the project's folder — only
///      for terminals showing evidence of Claude (a recorded id/transcript),
///      or that are their project's sole restored terminal (recovers sessions
///      whose id we never captured, e.g. hooks weren't installed yet). Never
///      for extra plain-shell tabs — they must not hijack a conversation.
///   4. The recorded id unverified, as a final attempt.
enum ClaudeResume {
    /// One restored terminal's recorded Claude evidence.
    struct Terminal {
        let id: UUID
        let claudeSessionID: String?
        let transcriptPath: String?
        let currentDirectory: String

        /// Any evidence that Claude ever ran in this terminal.
        var hasRecord: Bool { claudeSessionID != nil || transcriptPath != nil }
    }

    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude stores a project's transcripts under a folder named after the cwd
    /// with "/" and "." replaced by "-" (e.g. /Users/x.y/dev → -Users-x-y-dev).
    static func encodedProjectName(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
           .replacingOccurrences(of: ".", with: "-")
    }

    /// The session id encoded in a transcript path (`…/<id>.jsonl`).
    static func sessionID(fromTranscriptPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropLast(".jsonl".count))
        return id.isEmpty ? nil : id
    }

    /// Resolve every restored terminal's conversation together. Terminals come
    /// in display order — on equal evidence (e.g. two tabs recorded the same
    /// transcript) the earlier one keeps it and the later falls through to the
    /// next-best unclaimed conversation.
    static func resolveAll(
        _ terminals: [Terminal],
        projectsDir: URL = ClaudeResume.projectsDir
    ) -> [UUID: String] {
        let fm = FileManager.default
        var resolved: [UUID: String] = [:]
        var claimed = Set<String>()

        func claim(_ id: String, for t: Terminal) {
            resolved[t.id] = id
            claimed.insert(id)
        }
        func projDir(_ t: Terminal) -> URL {
            projectsDir.appendingPathComponent(encodedProjectName(t.currentDirectory))
        }

        // 1. The transcript each terminal recorded, if it still exists.
        for t in terminals {
            guard let tp = t.transcriptPath, fm.fileExists(atPath: tp),
                  let id = sessionID(fromTranscriptPath: tp),
                  !claimed.contains(id) else { continue }
            claim(id, for: t)
        }

        // 2. The recorded id, if its transcript exists for the project.
        for t in terminals where resolved[t.id] == nil {
            guard let id = t.claudeSessionID, !claimed.contains(id),
                  fm.fileExists(atPath: projDir(t).appendingPathComponent("\(id).jsonl").path)
            else { continue }
            claim(id, for: t)
        }

        // 3. The most recent unclaimed transcript in the project folder.
        let projectTerminalCount = Dictionary(
            grouping: terminals, by: { encodedProjectName($0.currentDirectory) })
            .mapValues(\.count)
        for t in terminals where resolved[t.id] == nil {
            let soleInProject = projectTerminalCount[encodedProjectName(t.currentDirectory)] == 1
            guard t.hasRecord || soleInProject,
                  let id = newestTranscriptID(in: projDir(t), excluding: claimed)
            else { continue }
            claim(id, for: t)
        }

        // 4. Whatever was recorded, even unverified.
        for t in terminals where resolved[t.id] == nil {
            guard let id = t.claudeSessionID, !claimed.contains(id) else { continue }
            claim(id, for: t)
        }

        return resolved
    }

    /// Single-terminal convenience over `resolveAll` (a restore with several
    /// terminals must always resolve them as one batch).
    static func resolveSessionID(
        claudeSessionID: String?,
        transcriptPath: String?,
        currentDirectory: String,
        projectsDir: URL = ClaudeResume.projectsDir
    ) -> String? {
        let terminal = Terminal(
            id: UUID(), claudeSessionID: claudeSessionID,
            transcriptPath: transcriptPath, currentDirectory: currentDirectory)
        return resolveAll([terminal], projectsDir: projectsDir)[terminal.id]
    }

    static func newestTranscriptID(in dir: URL, excluding claimed: Set<String> = []) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = items
            .filter {
                $0.pathExtension == "jsonl"
                    && !claimed.contains(String($0.lastPathComponent.dropLast(".jsonl".count)))
            }
            .max { a, b in modDate(a) < modDate(b) }
        return newest.map { String($0.lastPathComponent.dropLast(".jsonl".count)) }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

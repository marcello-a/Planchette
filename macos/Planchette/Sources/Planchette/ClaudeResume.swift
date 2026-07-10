import Foundation

/// Resolves which Claude conversation to resume for a restored terminal — as
/// robustly as possible, because a Claude session should always come back.
///
/// Order of preference, each guaranteeing (where it can) that the transcript
/// actually exists on disk so `claude --resume <id>` won't fail:
///   1. The transcript path we recorded for this exact terminal.
///   2. The recorded session id, if its transcript exists for this project.
///   3. The most recent transcript in the project's folder — recovers sessions
///      whose id we never captured (e.g. hooks weren't installed yet) or whose
///      recorded id went stale.
///   4. The recorded id unverified, as a final attempt.
enum ClaudeResume {
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

    static func resolveSessionID(
        claudeSessionID: String?,
        transcriptPath: String?,
        currentDirectory: String,
        projectsDir: URL = ClaudeResume.projectsDir
    ) -> String? {
        let fm = FileManager.default

        // 1. The transcript we recorded, if it still exists (per-terminal, exact).
        if let tp = transcriptPath, fm.fileExists(atPath: tp),
           let id = sessionID(fromTranscriptPath: tp) {
            return id
        }

        let projDir = projectsDir.appendingPathComponent(encodedProjectName(currentDirectory))

        // 2. The recorded id, if its transcript exists for this project.
        if let id = claudeSessionID,
           fm.fileExists(atPath: projDir.appendingPathComponent("\(id).jsonl").path) {
            return id
        }

        // 3. The most recent transcript in the project folder.
        if let id = newestTranscriptID(in: projDir) {
            return id
        }

        // 4. Whatever we recorded, even unverified.
        return claudeSessionID
    }

    static func newestTranscriptID(in dir: URL) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = items
            .filter { $0.pathExtension == "jsonl" }
            .max { a, b in modDate(a) < modDate(b) }
        return newest.map { String($0.lastPathComponent.dropLast(".jsonl".count)) }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

import Foundation

/// Stage 1: deterministic transcript parsing — no LLM involved.
enum TranscriptReader {
    struct Tail {
        var lastUserPrompt: String?
        var lastAssistantText: String?
    }

    /// Reads the last ~96 KB of a Claude Code transcript JSONL and extracts
    /// the most recent user prompt and assistant text.
    static func tail(path: String) -> Tail {
        var result = Tail()
        guard let handle = FileHandle(forReadingAtPath: path) else { return result }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 96 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return result }

        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String,
                  let message = obj["message"] as? [String: Any]
            else { continue }

            let textContent = extractText(message["content"])
            guard !textContent.isEmpty else { continue }

            if type == "assistant", result.lastAssistantText == nil {
                result.lastAssistantText = textContent
            }
            if type == "user", result.lastUserPrompt == nil {
                // Skip tool results (content array with tool_result items only).
                result.lastUserPrompt = textContent
            }
            if result.lastAssistantText != nil, result.lastUserPrompt != nil { break }
        }
        return result
    }

    private static func extractText(_ content: Any?) -> String {
        if let string = content as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let items = content as? [[String: Any]] else { return "" }
        return items
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Stage 2: LLM condensation via headless `claude -p` (uses the user's
/// existing Claude login; only runs while the AI toggle is on).
@MainActor
final class AIAssist {
    private weak var appState: AppState?
    private var lastRun: [UUID: Date] = [:]
    private let minInterval: TimeInterval = 60

    init(appState: AppState) {
        self.appState = appState
    }

    /// Called after Stop/Notification hook events.
    func sessionUpdated(_ id: UUID, force: Bool = false) {
        guard let appState, appState.aiEnabled else { return }
        guard let session = appState.sessions[id], let transcriptPath = session.transcriptPath else { return }
        if !force, let last = lastRun[id], Date().timeIntervalSince(last) < minInterval { return }
        lastRun[id] = Date()

        let cwd = session.currentDirectory
        let branch = Titles.gitBranch(forDirectory: cwd)
        Task.detached(priority: .utility) {
            let tail = TranscriptReader.tail(path: transcriptPath)
            guard tail.lastUserPrompt != nil || tail.lastAssistantText != nil else { return }
            guard let result = Self.condense(tail: tail, cwd: cwd, branch: branch) else { return }
            await MainActor.run { [weak appState] in
                appState?.update(id) {
                    $0.aiSummary = result.summary
                    $0.aiTopic = result.topic
                }
            }
        }
    }

    struct Condensed {
        var summary: String
        var topic: String
    }

    nonisolated private static func condense(
        tail: TranscriptReader.Tail,
        cwd: String,
        branch: String?
    ) -> Condensed? {
        let prompt = """
        Fasse den Zustand dieser Coding-Agent-Session in EINEM kurzen deutschen Satz \
        zusammen (max 12 Woerter, kein Punkt am Ende) und vergib ein Topic-Label \
        (EIN kleingeschriebenes Wort, z.B. Ticket-Nummer oder Thema).
        Antworte NUR mit JSON: {"summary": "...", "topic": "..."}

        Verzeichnis: \(cwd)
        Branch: \(branch ?? "-")
        Letzter Auftrag: \(String((tail.lastUserPrompt ?? "-").prefix(600)))
        Letzte Antwort des Agents: \(String((tail.lastAssistantText ?? "-").prefix(1200)))
        """

        guard let output = runClaude(prompt: prompt) else { return nil }
        // Be lenient: find the first JSON object in the output.
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start < end,
              let obj = try? JSONSerialization.jsonObject(
                  with: Data(output[start...end].utf8)) as? [String: Any],
              let summary = obj["summary"] as? String
        else {
            NSLog("ai-assist: unparseable output: \(output.prefix(200))")
            return nil
        }
        return Condensed(
            summary: summary,
            topic: (obj["topic"] as? String ?? "").lowercased()
        )
    }

    nonisolated private static func runClaude(prompt: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell so the user's PATH (and thus `claude`) resolves.
        process.arguments = ["-lc", "claude -p --model haiku 2>/dev/null"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("ai-assist: failed to launch claude: \(error)")
            return nil
        }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        // Drain stdout concurrently so a full pipe can never block the child.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        // Guard against hangs.
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if process.isRunning {
            process.terminate()
            NSLog("ai-assist: claude -p timed out")
            return nil
        }
        drained.wait()
        return String(data: data, encoding: .utf8)
    }
}

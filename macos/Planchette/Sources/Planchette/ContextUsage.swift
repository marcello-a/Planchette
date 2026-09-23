import Foundation

/// How full a Claude session's context window is, and which model it runs on —
/// read from the tail of its transcript. No LLM, no network: Claude Code writes
/// `message.model` and `message.usage` onto every assistant line.
///
/// The prompt a request sent is `input_tokens + cache_read_input_tokens +
/// cache_creation_input_tokens`; that sum is what occupies the context window
/// on the *next* turn, so the newest main-thread assistant line is the answer.
struct ContextUsage: Equatable {
    /// The model id as the transcript names it (`claude-opus-5-5`).
    let model: String
    /// Tokens the last request sent.
    let usedTokens: Int
    /// The window those tokens are measured against (see `ContextWindow`).
    let windowTokens: Int

    var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return min(1, Double(usedTokens) / Double(windowTokens))
    }

    var percent: Int { Int((fraction * 100).rounded()) }

    /// Past this, the answers of a long session get worse and `/compact` is due.
    static let warnFraction = 0.7
    static let criticalFraction = 0.9
}

enum ContextWindow {
    static let standard = 200_000
    static let extended = 1_000_000

    /// The window a session runs in. The transcript does not say — the `[1m]`
    /// suffix that selects the long window never reaches it — so this is decided
    /// from what we can see, strongest evidence first:
    /// - more than the standard window already used: it can only be the long one,
    /// - the terminal showed Claude Code's "1M context" banner,
    /// - the configured model (settings / `ANTHROPIC_MODEL`) carries `[1m]`.
    /// Otherwise the standard window.
    static func size(usedTokens: Int, sawExtendedBanner: Bool, configuredModel: String?) -> Int {
        if usedTokens > standard { return extended }
        if sawExtendedBanner { return extended }
        if let configuredModel, configuredModel.lowercased().contains("[1m]") { return extended }
        return standard
    }

    /// Whether a terminal's screen shows the banner of a long-window session
    /// (`Opus 5.5 (1M context)`). Pure, so the screen poll can call it on the
    /// viewport text it already has.
    static func screenShowsExtended(_ text: String) -> Bool {
        text.range(of: "1M context", options: .caseInsensitive) != nil
    }

    /// The model the user configured for Claude Code, if any. Read once per
    /// poll off-main: `~/.claude/settings.json` → `model`, else the environment.
    static func configuredModel(home: String = NSHomeDirectory()) -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"], !env.isEmpty {
            return env
        }
        let url = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["model"] as? String
    }
}

enum ContextUsageReader {
    /// Model and prompt size of the newest main-thread assistant line in `text`
    /// (JSONL). Sidechain lines are skipped: a subagent's prompt lives in its own
    /// window and says nothing about this one. Pure, so it is unit-tested.
    static func latest(inJSONL text: Substring) -> (model: String, usedTokens: Int)? {
        for line in text.split(separator: "\n").reversed() {
            // Cheap filter before parsing: most lines are tool results.
            guard line.contains("\"usage\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  (obj["isSidechain"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            // `<synthetic>` marks a line Claude Code wrote itself (an interrupt,
            // an API error) — it carries zero usage and would empty the ring.
            guard !model.hasPrefix("<") else { continue }
            let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            guard used > 0 else { continue }
            return (model, used)
        }
        return nil
    }

    /// Read the last `window` bytes of a transcript and find the newest usage.
    /// 512 KB, because one assistant line with a large tool call can be long,
    /// and the usage we need may sit behind several of them.
    static func read(path: String, window: UInt64 = 512 * 1024) -> (model: String, usedTokens: Int)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return latest(inJSONL: text[...])
    }
}

enum ModelName {
    /// A short, readable name for a model id: `claude-opus-5-5` → `Opus 5.5`,
    /// `claude-haiku-4-5-20251001` → `Haiku 4.5`, `claude-sonnet-5` → `Sonnet 5`.
    /// An id that does not look like a Claude model is returned unchanged.
    static func short(_ id: String) -> String {
        var parts = id.lowercased()
            .replacingOccurrences(of: "[1m]", with: "")
            .split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return id }
        parts.removeFirst()
        // Drop a date stamp (`20251001`).
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.allSatisfy(\.isLetter), !family.isEmpty else {
            return id
        }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    /// Tokens as a compact label: `137k`, `1.2M`.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000
            return m >= 10 ? "\(Int(m.rounded()))M" : String(format: "%.1fM", m)
        }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))k" }
        return "\(count)"
    }
}

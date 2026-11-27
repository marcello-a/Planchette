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
    /// When the last request touched the prompt cache, and how long the cache
    /// lives after that (see `PromptCache`). Nil when the transcript has no
    /// timestamp — the cache timer then has nothing to count from.
    var cacheTouchedAt: Date?
    var cacheTTL: TimeInterval = PromptCache.defaultTTL

    /// When the prompt cache of this session clears if nothing is sent.
    var cacheExpiresAt: Date? { cacheTouchedAt?.addingTimeInterval(cacheTTL) }

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

/// Claude's prompt cache: every request re-reads the conversation from it and
/// resets its clock; after the TTL without a request it is gone, and the next
/// prompt pays to write the whole context again. Claude Code asks for either a
/// 5-minute or a 1-hour cache, and says which on every line it writes
/// (`usage.cache_creation.ephemeral_1h_input_tokens` / `…_5m_…`).
enum PromptCache {
    /// When no line says: Claude Code's 1-hour cache, the one Opus 5.5 runs on.
    static let defaultTTL: TimeInterval = 3600

    /// The TTL a usage block asked for, or nil when it wrote nothing to the
    /// cache (a pure cache read) and so does not say.
    static func ttl(fromUsage usage: [String: Any]) -> TimeInterval? {
        guard let creation = usage["cache_creation"] as? [String: Any] else { return nil }
        if ((creation["ephemeral_1h_input_tokens"] as? Int) ?? 0) > 0 { return 3600 }
        if ((creation["ephemeral_5m_input_tokens"] as? Int) ?? 0) > 0 { return 300 }
        return nil
    }
}

/// What the newest main-thread assistant line of a transcript says.
struct TranscriptUsage: Equatable {
    let model: String
    let usedTokens: Int
    /// The line's `timestamp` — when that request finished.
    var at: Date?
    /// The cache TTL the newest line that wrote to the cache asked for.
    var cacheTTL: TimeInterval?
}

/// What one read of a transcript's tail yields: how full the context window of
/// its newest assistant line is, and the name Claude Code gave the conversation
/// (`AgentTitle`). Either half can be absent — a fresh transcript has no usage
/// yet, a short one no title.
struct TranscriptScan: Equatable {
    var usage: TranscriptUsage?
    var title: String?
    /// The `/rename` name. Written once, so the 512 KB window loses it as the
    /// session goes on: the sweep carries it over from the last reading of the
    /// same transcript (`keepingRename(of:)`).
    var customTitle: String?

    /// What the sidebar calls the conversation: your name for it, else Claude's.
    var displayTitle: String? { customTitle ?? title }

    /// This reading, with the `/rename` name of an earlier reading of the same file
    /// when this one no longer sees it.
    func keepingRename(of earlier: TranscriptScan?) -> TranscriptScan {
        guard customTitle == nil, let kept = earlier?.customTitle else { return self }
        var scan = self
        scan.customTitle = kept
        return scan
    }
}

enum ContextUsageReader {
    private static let timestampFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Model and prompt size of the newest main-thread assistant line in `text`
    /// (JSONL). Sidechain lines are skipped: a subagent's prompt lives in its own
    /// window and says nothing about this one. Pure, so it is unit-tested.
    static func latest(inJSONL text: Substring) -> TranscriptUsage? {
        latest(inJSONL: Data(text.utf8))
    }

    static func latest(inJSONL data: Data) -> TranscriptUsage? {
        var found: TranscriptUsage?
        // Only the lines that name a usage are parsed: most lines are tool results.
        JSONLines.newestFirst(in: data, containing: "\"usage\"") { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  (obj["isSidechain"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any]
            else { return false }
            // `<synthetic>` marks a line Claude Code wrote itself (an interrupt,
            // an API error) — it carries zero usage and would empty the ring.
            guard !model.hasPrefix("<") else { return false }
            let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            guard used > 0 else { return false }
            let ttl = PromptCache.ttl(fromUsage: usage)
            if found != nil {
                // Only still looking for which cache the session asked for.
                found?.cacheTTL = ttl
                return ttl != nil
            }
            let at = (obj["timestamp"] as? String).flatMap { timestampFormat.date(from: $0) }
            found = TranscriptUsage(model: model, usedTokens: used, at: at, cacheTTL: ttl)
            return ttl != nil
        }
        return found
    }

    /// Read the last `window` bytes of a transcript and parse everything the
    /// sidebar reads out of it. 512 KB, because one assistant line with a large
    /// tool call can be long, and the usage we need may sit behind several of
    /// them.
    ///
    /// One read for both answers: the sweep that wants them runs per changed
    /// transcript, and reading the same half megabyte a second time to find a
    /// line that sits in it already would buy nothing.
    static func scan(path: String, window: UInt64 = 512 * 1024) -> TranscriptScan {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptScan() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return TranscriptScan() }
        // Bytes, not a String: each answer is found by a byte search for its marker,
        // and only the lines that hold it are parsed. Splitting the half megabyte into
        // lines three times cost about 31 ms a scan; the search costs well under one.
        return TranscriptScan(usage: latest(inJSONL: data),
                              title: AgentTitle.latest(inJSONL: data),
                              customTitle: AgentTitle.latestCustom(inJSONL: data))
    }
}

/// Size and modification date of a transcript, as one comparable value: a reader
/// whose file has the same stamp as at its last read has nothing new to read.
enum TranscriptStamp {
    static func of(path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? Int) ?? -1
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(modified)"
    }
}

/// The lines of a JSONL buffer that contain a marker, newest first, found by a byte
/// search (`memmem`) rather than by splitting the whole buffer into lines. Pure.
enum JSONLines {
    /// Calls `body` with each line of `data` that contains `marker`, from the last
    /// line to the first, until `body` returns true. A line is given once, however
    /// often the marker appears in it, without its newline.
    static func newestFirst(in data: Data, containing marker: String, _ body: (Data) -> Bool) {
        let needle = Array(marker.utf8)
        guard !needle.isEmpty, data.count >= needle.count else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            // One forward pass collects every hit; the lines are then visited backwards.
            var hits: [Int] = []
            needle.withUnsafeBytes { pattern in
                var position = 0
                while position <= count - needle.count,
                      let hit = memmem(base + position, count - position, pattern.baseAddress, needle.count) {
                    let offset = base.distance(to: UnsafeRawPointer(hit))
                    hits.append(offset)
                    position = offset + needle.count
                }
            }
            var lineStartOfLastVisit = count + 1
            for hit in hits.reversed() where hit < lineStartOfLastVisit {
                // Darwin has no `memrchr`: walk back to the newline before the hit.
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                var start = hit
                while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
                let after = hit + needle.count
                let end = memchr(base + after, 0x0A, count - after)
                    .map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                lineStartOfLastVisit = start
                if body(Data(bytes: base + start, count: end - start)) { return }
            }
        }
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

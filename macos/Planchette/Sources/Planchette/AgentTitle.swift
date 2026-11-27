import Foundation

/// The name Claude Code gives the conversation itself, read out of its own
/// transcript — "VOLL-2735 testimonial merge status", "Shop-backend 401 Fehler".
///
/// It answers what the last prompt cannot: a prompt is the latest thing you
/// said ("ja, mach"), the title is what the session is *about*, and it survives
/// the back and forth of a long turn. Claude Code rewrites it as the topic
/// moves, so the newest one in the file wins.
///
/// Read, never asked for: the line is already in the transcript we sweep for
/// the context ring, so this costs no `claude -p` and no tokens (unlike
/// `AIAssist`, which is a second, opt-in opinion about the same session).
///
/// The format is Claude Code's internal one and nothing promises it stays:
///
///     {"type":"ai-title","aiTitle":"…","sessionId":"…"}
///
/// So every step here is a `guard` that falls back to nil. A transcript without
/// the line (a very short session, an older Claude Code, another agent) simply
/// has no title, and the row keeps saying what it said before.
///
/// A name you gave with `/rename` sits in the same file, and wins over Claude's own:
///
///     {"type":"custom-title","customTitle":"…","sessionId":"…"}
enum AgentTitle {
    /// The newest title Claude Code gave in `text` (JSONL), or nil when it names
    /// none. Pure, so it is unit-tested.
    static func latest(inJSONL text: Substring) -> String? {
        latest(type: "ai-title", key: "aiTitle", inJSONL: text)
    }

    /// The newest `/rename` name in `text` (JSONL), or nil when there is none.
    static func latestCustom(inJSONL text: Substring) -> String? {
        latest(type: "custom-title", key: "customTitle", inJSONL: text)
    }

    /// The newest title in `data`, read as bytes (see `ContextUsageReader.scan`).
    static func latest(inJSONL data: Data) -> String? {
        latest(type: "ai-title", key: "aiTitle", inJSONL: data)
    }

    /// The newest `/rename` name in `data`, read as bytes.
    static func latestCustom(inJSONL data: Data) -> String? {
        latest(type: "custom-title", key: "customTitle", inJSONL: data)
    }

    private static func latest(type: String, key: String, inJSONL text: Substring) -> String? {
        latest(type: type, key: key, inJSONL: Data(text.utf8))
    }

    private static func latest(type: String, key: String, inJSONL data: Data) -> String? {
        var found: String?
        // Only the lines that name the type are parsed: most lines are tool results.
        JSONLines.newestFirst(in: data, containing: "\"\(type)\"") { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == type,
                  let title = obj[key] as? String
            else { return false }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Claude Code writes an empty title before it has one to give.
            guard !trimmed.isEmpty else { return false }
            found = trimmed
            return true
        }
        return found
    }
}

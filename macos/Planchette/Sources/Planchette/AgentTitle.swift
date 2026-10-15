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
enum AgentTitle {
    /// The newest title in `text` (JSONL), or nil when it names none. Pure, so
    /// it is unit-tested.
    static func latest(inJSONL text: Substring) -> String? {
        for line in text.split(separator: "\n").reversed() {
            // Cheap filter before parsing: most lines are tool results.
            guard line.contains("\"ai-title\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let title = obj["aiTitle"] as? String
            else { continue }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Claude Code writes an empty title before it has one to give.
            guard !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }
}

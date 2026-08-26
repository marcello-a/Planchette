import Foundation

/// Shell escaping for paths dropped into a live terminal — ported from
/// Ghostty's own `Ghostty.Shell` so dropped files behave exactly like in
/// Ghostty itself.
enum Shell {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Escape shell-sensitive characters by prefixing each with a backslash.
    /// Suitable for inserting paths/URLs into a live terminal buffer.
    static func escape(_ str: String) -> String {
        // A backslash cannot neutralize a newline — `\<newline>` is a shell line
        // continuation, not a literal newline. A dropped filename may legally
        // contain newlines (only NUL and "/" are forbidden in a path), so remove
        // line breaks outright: an inserted path must never submit or split a
        // command at the prompt.
        var result = str
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}

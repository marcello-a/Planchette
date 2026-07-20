import Foundation

/// Shell escaping for paths dropped into a live terminal — ported from
/// Ghostty's own `Ghostty.Shell` so dropped files behave exactly like in
/// Ghostty itself.
enum Shell {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Escape shell-sensitive characters by prefixing each with a backslash.
    /// Suitable for inserting paths/URLs into a live terminal buffer.
    static func escape(_ str: String) -> String {
        var result = str
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}

import Foundation

/// What dropping something onto a terminal should do.
enum DropAction: Equatable {
    /// Image files → put on the clipboard and paste with ⌃V, so a running
    /// Claude Code attaches them as images (`[Image #1]`) instead of receiving
    /// a long screenshot path.
    case pasteImages([URL])
    /// Everything else → type this text at the prompt.
    case typeText(String)
}

/// Pure drop decision, so the rules are unit-tested rather than buried in the
/// AppKit drag handler.
enum Drop {
    /// Image formats Claude Code accepts as an attachment. Deliberately a
    /// whitelist and not "anything NSImage can open" — a dropped `.psd` or
    /// `.pdf` is more useful as a path Claude can open with a tool.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    static func isImage(_ url: URL) -> Bool {
        url.isFileURL && imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decide what a drop means.
    ///
    /// - Parameters:
    ///   - urlString: the pasteboard's `public.url` string, if any.
    ///   - urls: URLs read off the pasteboard (files and/or web URLs).
    ///   - string: plain dropped text, if any.
    ///   - canPasteImages: whether ⌃V is safe here — true only while a Claude
    ///     Code session is live in the terminal. In a plain shell ⌃V means
    ///     quoted-insert, so images fall back to their escaped path.
    static func action(
        urlString: String?,
        urls: [URL],
        string: String?,
        canPasteImages: Bool
    ) -> DropAction? {
        // Images take the clipboard route only when the whole drop is images —
        // a mixed drop stays one consistent line of paths at the prompt.
        let images = urls.filter(isImage)
        if canPasteImages, !urls.isEmpty, images.count == urls.count {
            return .pasteImages(images)
        }
        // Fall back to Ghostty's own order: URL > file URLs > plain string.
        if let urlString {
            return .typeText(Shell.escape(urlString))
        }
        if !urls.isEmpty {
            return .typeText(urls.map { Shell.escape($0.path) }.joined(separator: " "))
        }
        if let string {
            // Plain strings stay unescaped — they may be a command to run.
            return .typeText(string)
        }
        return nil
    }
}

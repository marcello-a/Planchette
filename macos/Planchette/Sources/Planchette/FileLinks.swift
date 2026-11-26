import Foundation

/// A path a program printed — `src/Foo.php:42`, `./app.ts:3:7`,
/// `/var/www/html/src/Foo.php:42` — and where it is on this Mac.
///
/// libghostty marks paths as links as well as URLs (its link regex has a
/// branch for rooted and for bare relative paths), and a ⌘-click hands us the
/// text. A path has no scheme, so the URL policy blocked every one of them;
/// these open in the project's IDE at their line instead. Pure, unit-tested;
/// the click is `AppState.openFileLink`.
struct FileLink: Equatable {
    /// The path as printed, without its position.
    let path: String
    let line: Int?
    let column: Int?

    /// The link's path and position, or nil for anything that is not a path
    /// (a URL with a scheme keeps the URL policy).
    static func parse(_ raw: String) -> FileLink? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPathLike(text) else { return nil }
        // Up to two trailing numbers: `:line`, then `:line:column`.
        var numbers: [Int] = []
        while numbers.count < 2, let colon = text.lastIndex(of: ":") {
            let tail = text[text.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(tail) else { break }
            numbers.insert(number, at: 0)
            text = String(text[..<colon])
        }
        guard !text.isEmpty, !text.hasSuffix("/") else { return nil }
        let line = numbers.first.flatMap { $0 > 0 ? $0 : nil }
        let column = line == nil ? nil : (numbers.count > 1 && numbers[1] > 0 ? numbers[1] : nil)
        return FileLink(path: text, line: line, column: column)
    }

    /// A path, not a URL: rooted (`/`, `./`, `../`, `~/`), or relative with a
    /// `/` and no scheme in front of it (`src/Foo.php`, but not `https://…`).
    static func isPathLike(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../") || text.hasPrefix("~/") {
            return !text.hasPrefix("//")
        }
        guard let slash = text.firstIndex(of: "/") else { return false }
        return !text[..<slash].contains(":")
    }

    /// The file this link means, or nil when there is none.
    ///
    /// The printed path first: as it is when absolute, else from the terminal's
    /// folder, then from the project's. A path printed inside a container or a VM
    /// (`/var/www/html/src/Foo.php` from tests run in a pod) does not exist here;
    /// then the longest tail of it that is a file in the terminal's folder or the
    /// project is meant. A tail keeps at least two parts, so a bare `Foo.php` never
    /// stands for whichever `Foo.php` happens to come first.
    static func resolve(
        _ path: String, cwd: String?, project: String?, home: String,
        isFile: (String) -> Bool
    ) -> String? {
        let expanded = path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
        let bases = [cwd, project].compactMap { $0 }.filter { !$0.isEmpty }
        var candidates: [String] = []
        if expanded.hasPrefix("/") {
            candidates.append(expanded)
        } else {
            candidates += bases.map { join($0, expanded) }
        }
        let parts = expanded.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        if parts.count > 2 {
            for drop in 1...(parts.count - 2) {
                let tail = parts.dropFirst(drop).joined(separator: "/")
                candidates += bases.map { join($0, tail) }
            }
        }
        return candidates.lazy.map { ($0 as NSString).standardizingPath }.first(where: isFile)
    }

    private static func join(_ base: String, _ path: String) -> String {
        (base as NSString).appendingPathComponent(path)
    }
}

/// How an IDE is told to open a file at a line.
enum FileOpenRequest: Equatable {
    /// Run the IDE's own launcher. A JetBrains IDE that already runs hands the
    /// file to its open window and the launcher exits.
    case launcher(executable: String, arguments: [String])
    /// An IDE URL (`vscode://file/…:42:7`).
    case url(URL)
    /// No way to name a line: open the file in the IDE.
    case plain

    /// The request for `file` at `line`/`column` in `ide`, whose app bundle is
    /// `appPath` and whose main executable is `executable`.
    static func make(
        file: String, line: Int?, column: Int?, ide: IDE, appPath: String, executable: String?
    ) -> FileOpenRequest {
        let position = line.map { ":\($0)" + (column.map { ":\($0)" } ?? "") } ?? ""
        switch ide.bundleID {
        case let id where id.hasPrefix("com.jetbrains."):
            guard let executable else { return .plain }
            var arguments: [String] = []
            if let line { arguments += ["--line", String(line)] }
            if line != nil, let column { arguments += ["--column", String(column)] }
            return .launcher(executable: executable, arguments: arguments + [file])
        case "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf":
            let scheme = ["com.microsoft.VSCode": "vscode",
                          "com.todesktop.230313mzl4w4u92": "cursor",
                          "com.exafunction.windsurf": "windsurf"][ide.bundleID]!
            var components = URLComponents()
            components.scheme = scheme
            components.host = "file"
            components.path = file + position
            return components.url.map(FileOpenRequest.url) ?? .plain
        case "dev.zed.Zed":
            return .launcher(executable: appPath + "/Contents/MacOS/cli", arguments: [file + position])
        case let id where id.hasPrefix("com.sublimetext."):
            return .launcher(
                executable: appPath + "/Contents/SharedSupport/bin/subl", arguments: [file + position])
        case "com.apple.dt.Xcode":
            var arguments: [String] = []
            if let line { arguments += ["--line", String(line)] }
            return .launcher(executable: "/usr/bin/xed", arguments: arguments + [file])
        default:
            return .plain
        }
    }
}

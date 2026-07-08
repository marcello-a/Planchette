import Foundation

/// Imports working directories from other terminal apps and turns them into
/// Planchette terminals.
///
/// Honest scope: another terminal app owns its own PTY and child process, and
/// macOS has no API to adopt or live-mirror another process's window. So we
/// migrate the *workspace* (the working directory, and hence the project),
/// not the running process — a new Planchette terminal opens in the same
/// directory. iTerm2 and Terminal.app expose their session ttys via
/// AppleScript; we resolve each tty's foreground cwd with `lsof`.
enum MigrationService {
    enum Source: String {
        case iterm2, terminalApp

        var displayName: String {
            switch self {
            case .iterm2: return "iTerm2"
            case .terminalApp: return "Terminal.app"
            }
        }
    }

    enum MigrationError: Error {
        case notRunning
        case notAuthorized     // Automation permission denied
        case nothingFound
        case failed(String)
    }

    /// Collect the working directories of all tabs/sessions of `source`.
    static func importDirectories(from source: Source) -> Result<[String], MigrationError> {
        let ttyScript: String
        switch source {
        case .iterm2:
            ttyScript = """
            tell application "iTerm2"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            set out to out & (tty of s) & "\\n"
                        end repeat
                    end repeat
                end repeat
                return out
            end tell
            """
        case .terminalApp:
            ttyScript = """
            tell application "Terminal"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (tty of t) & "\\n"
                    end repeat
                end repeat
                return out
            end tell
            """
        }

        let osa = runProcess("/usr/bin/osascript", ["-e", ttyScript])
        if osa.status != 0 {
            let err = osa.stderr.lowercased()
            if err.contains("not authoriz") || err.contains("-1743") || err.contains("not allowed") {
                return .failure(.notAuthorized)
            }
            if err.contains("not running") || err.contains("-600") || err.contains("-609") {
                return .failure(.notRunning)
            }
            return .failure(.failed(osa.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        let ttys = osa.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/dev/") }
        guard !ttys.isEmpty else { return .failure(.nothingFound) }

        let cwds = resolveCwds(ttys: ttys)
        guard !cwds.isEmpty else { return .failure(.nothingFound) }
        return .success(cwds)
    }

    /// Resolve each tty's foreground-process working directory via `lsof`.
    private static func resolveCwds(ttys: [String]) -> [String] {
        // Device names are interpolated into a shell loop; allow only the safe
        // charset (e.g. "ttys005") so a malformed name can't inject.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let devs = ttys
            .map { $0.replacingOccurrences(of: "/dev/", with: "") }
            .filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy { safe.contains($0) } }
            .joined(separator: " ")
        guard !devs.isEmpty else { return [] }
        let script = """
        for dev in \(devs); do
            pid=$(ps -t "$dev" -o pid=,stat= 2>/dev/null | awk '$2 ~ /\\+/{print $1}' | tail -1)
            [ -z "$pid" ] && pid=$(ps -t "$dev" -o pid= 2>/dev/null | tail -1)
            [ -z "$pid" ] && continue
            lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
        done
        """
        let result = runProcess("/bin/sh", ["-c", script])
        var seen = Set<String>()
        var cwds: [String] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, path.hasPrefix("/"),
                  seen.insert(path).inserted else { continue }
            cwds.append(path)
        }
        return cwds
    }

    private static func runProcess(_ launchPath: String, _ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (-1, "", "\(error)")
        }
        // Drain both pipes concurrently: reading stdout fully before stderr can
        // deadlock if the child fills the stderr pipe buffer meanwhile.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let drain = DispatchQueue(label: "planchette.proc-drain", attributes: .concurrent)
        drain.async(group: group) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        drain.async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

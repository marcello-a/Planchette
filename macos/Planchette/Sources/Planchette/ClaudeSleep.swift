import Darwin
import Foundation

/// Putting idle Claude sessions to sleep — and waking them when you come back.
///
/// A Claude Code session costs 150–500 MB while it waits, and so do the MCP servers it started.
/// With two dozen terminals that sat for days, that was the swap the whole Mac paged through:
/// every new shell and every new session waited for memory first (performance audit,
/// 2026-11-24: 24 sessions, 21 of 22 GB swap in use). A conversation lives in its transcript,
/// not in the process, so ending an idle one loses nothing: `claude --resume <id>` brings it
/// back where it was.
///
/// Off by default (Settings → General). When on, the housekeeping tick ends Claude in a terminal
/// that has been idle for the chosen time (`shouldSleep`), by SIGTERM to its process
/// (`ClaudeProcess`) — never by typing into it, where a half-written prompt would be. The
/// terminal remembers the conversation (`TerminalSession.sleepingClaudeID`); focusing or selecting
/// it types the same resume line a restore does (`RestoreCommand`).
enum ClaudeSleep: String, Codable, CaseIterable {
    case off
    case after2h
    case after8h
    case after24h

    /// How long a terminal must be idle; nil when the feature is off.
    var idleTime: TimeInterval? {
        switch self {
        case .off: nil
        case .after2h: 2 * 3600
        case .after8h: 8 * 3600
        case .after24h: 24 * 3600
        }
    }

    /// Pure: whether the Claude in one terminal goes to sleep now. Only an agent with nothing
    /// for you and nothing in flight: free, or a result you have seen; no background shell or
    /// agent of its own; not on screen; idle for the chosen time — and a conversation id to
    /// come back to, else ending it would lose the way back.
    static func shouldSleep(
        setting: ClaudeSleep,
        isClaude: Bool, agentLive: Bool,
        state: AttentionState, seen: Bool, stateSince: Date,
        hasBackgroundWork: Bool, onScreen: Bool,
        claudeSessionID: String?, now: Date
    ) -> Bool {
        guard let idle = setting.idleTime, isClaude, agentLive,
              !hasBackgroundWork, !onScreen,
              let claudeSessionID, isResumable(claudeSessionID)
        else { return false }
        let idleState = state == .free || (state == .ready && seen)
        return idleState && now.timeIntervalSince(stateSince) >= idle
    }

    /// The same rule `RestoreCommand` applies before an id goes into a shell line: letters,
    /// digits and hyphens only.
    static func isResumable(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

/// Finding the `claude` process of one terminal. Every Planchette terminal carries
/// `PLANCHETTE_SESSION=<id>` in its environment, and Claude inherits it; so do the shells and
/// MCP servers Claude starts, which is why the process must also *be* Claude.
enum ClaudeProcess {
    /// The Claude processes whose environment names this terminal.
    static func pids(forTerminal id: UUID) -> [pid_t] {
        let wanted = "PLANCHETTE_SESSION=\(id.uuidString)"
        return candidatePIDs().filter { pid in
            guard let args = arguments(of: pid), isClaude(args.argv) else { return false }
            return args.env.contains(wanted)
        }
    }

    /// Pure: whether a command line is Claude Code — the native binary, or the npm package run
    /// by node.
    static func isClaude(_ argv: [String]) -> Bool {
        guard let first = argv.first else { return false }
        if (first as NSString).lastPathComponent == "claude" { return true }
        guard (first as NSString).lastPathComponent == "node", argv.count > 1 else { return false }
        let script = argv[1]
        return (script as NSString).lastPathComponent == "claude" || script.contains("@anthropic-ai/claude-code")
    }

    /// The processes of this user whose executable can be Claude: `node`, a `claude`, or the
    /// native install's versioned binary (`~/.local/share/claude/versions/2.1.323` — the kernel
    /// names that process `2.1.323`, so its name says nothing). A cheap path filter before the
    /// environment of each is read.
    private static func candidatePIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let me = getuid()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0 else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
                  info.pbsi_uid == me,
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0
            else { return false }
            return mayBeClaude(executable: String(cString: path))
        }
    }

    /// Pure: whether an executable path can run Claude Code.
    static func mayBeClaude(executable: String) -> Bool {
        let name = (executable as NSString).lastPathComponent
        return name == "claude" || name == "node" || executable.contains("/claude/versions/")
    }

    /// The command line and environment of a process of this user (`KERN_PROCARGS2`).
    static func arguments(of pid: pid_t) -> (argv: [String], env: [String])? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(length)))
    }

    /// Pure: split a `KERN_PROCARGS2` buffer — `argc` (32 bit), the executable path, NUL padding,
    /// then `argc` arguments and the environment, each NUL-terminated.
    static func parseProcArgs(_ bytes: [UInt8]) -> (argv: [String], env: [String])? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // the executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // its padding
        var strings: [String] = []
        var start = index
        while index < bytes.count {
            if bytes[index] == 0 {
                // An empty string after the arguments ends the environment.
                if index == start, strings.count >= argc { break }
                strings.append(String(decoding: bytes[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        guard strings.count >= argc else { return nil }
        return (Array(strings.prefix(argc)), Array(strings.dropFirst(argc)))
    }
}

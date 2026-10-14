import Foundation

/// Runs a short-lived helper process (`git`, `lsof`, `tmux`, `gh`) under a hard
/// deadline.
///
/// Every poller in the app shells out to one of these, off the main thread, on a
/// timer. A bare `Process` + `readDataToEndOfFile()` + `waitUntilExit()` has no
/// upper bound: one `git` stuck on a dead network mount, or one `gh` waiting on a
/// stalled connection, holds its thread forever — and because the timer keeps
/// firing, a new stuck process and thread joins it every interval until the app
/// is starved. This helper kills the child at the deadline and returns what it
/// had, so a poll can only ever cost its timeout.
///
/// It also stops waiting for pipes that a *grandchild* holds open. Killing the
/// direct child does not close a pipe that a daemon it spawned inherited, so a
/// plain `readDataToEndOfFile()` would outlive the kill; here the read is a
/// `poll` loop against the same deadline instead.
enum Subprocess {
    enum Stderr {
        /// Send stderr to /dev/null (the common case for pollers).
        case discard
        /// Collect it, for callers that surface the tool's own error message.
        case capture
    }

    struct Output {
        /// The exit status, or -1 when the process had to be killed.
        var status: Int32
        var stdout: Data
        var stderr: Data
        /// The deadline passed. Output may be incomplete, and `status` is not
        /// the tool's own verdict.
        var timedOut: Bool

        /// Exited by itself with status 0.
        var succeeded: Bool { !timedOut && status == 0 }
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Run `executable` and collect its output. Returns nil only when the process
    /// could not be started at all (missing binary, no permission).
    ///
    /// Blocking: call it off the main thread. `timeout` bounds the whole run.
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        in directory: String? = nil,
        timeout: TimeInterval = 15,
        stderr stderrMode: Stderr = .discard
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        // A helper must never wait for a keyboard the app does not have.
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        let errPipe: Pipe? = stderrMode == .capture ? Pipe() : nil
        process.standardError = errPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let start = DispatchTime.now().uptimeNanoseconds
        func remaining() -> TimeInterval {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            return max(0, timeout - elapsed)
        }

        var outData = Data()
        var errData = Data()
        var fds = [pollfd(fd: outPipe.fileHandleForReading.fileDescriptor,
                          events: Int16(POLLIN), revents: 0)]
        if let errPipe {
            fds.append(pollfd(fd: errPipe.fileHandleForReading.fileDescriptor,
                              events: Int16(POLLIN), revents: 0))
        }
        var openStreams = fds.count
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var timedOut = false

        while openStreams > 0 {
            let left = remaining()
            if left <= 0 { timedOut = true; break }
            // Wake at least once a second so the deadline is honoured even when
            // nothing is written.
            let ready = poll(&fds, nfds_t(fds.count), Int32(min(left, 1.0) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0 else { continue }
            for index in fds.indices where fds[index].fd >= 0 && fds[index].revents != 0 {
                let count = read(fds[index].fd, &buffer, buffer.count)
                if count > 0 {
                    if index == 0 { outData.append(buffer, count: count) }
                    else { errData.append(buffer, count: count) }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    // EOF (or a dead pipe): `poll` skips a negative descriptor.
                    fds[index].fd = -1
                    openStreams -= 1
                }
            }
        }

        // The pipes are closed, but the process may still be winding down — or
        // may have closed them on purpose and kept running. Give it whatever is
        // left of the deadline, then end it.
        if exited.wait(timeout: .now() + remaining()) == .timedOut { timedOut = true }
        if process.isRunning {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // `terminationStatus` raises while the process is still alive.
        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return Output(status: timedOut ? -1 : status, stdout: outData, stderr: errData,
                      timedOut: timedOut)
    }
}

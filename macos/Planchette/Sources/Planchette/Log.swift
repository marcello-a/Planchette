import Foundation
import os

/// The app's log: everything goes to the unified log (Console.app, `log stream --predicate
/// 'subsystem == "build.planchette.app"'`), and an error is also counted for the next
/// telemetry report.
///
/// The key of an error is a `StaticString` on purpose: only a literal written in the source
/// can reach PostHog, so a path, a title or a payload can never become one. The message is
/// free text and stays on this Mac.
enum Log {
    static let subsystem = "build.planchette.app"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    /// Something went wrong that the user or the developer should hear about.
    /// `key` is `area.what`, e.g. `hook-server.bind_failed`.
    static func error(_ key: StaticString, _ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(key.description, privacy: .public): \(text, privacy: .public)")
        TelemetryCounter.shared.add(error: key.description)
    }

    /// Worth a line in the log, not a count. `notice`, not `info`: the unified log keeps
    /// `info` in memory only, and these lines replaced `NSLog`, which is kept on disk.
    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.notice("\(text, privacy: .public)")
    }

    /// For the developer only: not kept on disk, shown by `log stream --level debug`.
    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }
}

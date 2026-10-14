import AppKit

/// Showing an alert without stopping the app.
///
/// `NSAlert.runModal()` spins a nested run loop. Started from inside a block that
/// the main DISPATCH QUEUE is running, that loop does not run the queue's other
/// blocks — and every `DispatchQueue.main.async` block, and every continuation of
/// a Swift-concurrency task on the main actor, is such a block. While the alert is
/// open nothing else dispatched to the main queue runs:
///
/// - libghostty's wake-up (`GhosttyRuntime.tick`) is one of those blocks, so no
///   terminal's output is processed. The library's mailbox holds 64 messages;
///   a program that sets its title on every spinner frame fills it in seconds, the
///   terminal's IO thread then blocks, the PTY backs up, and the agent behind it
///   stops on its next write. Measured on the previous build with the update
///   dialog left open: the loop in a terminal ran about 140 iterations and then
///   stood still, and the control API never answered again until the dialog closed.
/// - hook events and control-API replies are such blocks too.
///
/// A timer or a run-loop source (an event handler, `CFRunLoopPerformBlock`) does
/// not have the problem: a nested loop started from one of those services the main
/// queue normally. So the alert is run from a run-loop callout, and the caller
/// awaits it — the suspended task holds no queue slot while the alert is up.
///
/// Use this for any alert that can appear from async or dispatched code (after an
/// `await`, from a timer's `Task`, from a notification). An alert shown straight
/// from a user's click or a menu action is already in a run-loop callout and may
/// use `runModal()` directly (measured with the AI menu's dialog and the quit
/// confirmation: a terminal's loop and the control API kept running while they
/// were open).
enum ModalAlert {
    @MainActor
    static func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await runFromRunLoop { alert.runModal() }
    }

    /// For an alert nobody waits on (an error report, a notice).
    @MainActor
    static func show(_ alert: NSAlert) {
        Task { _ = await run(alert) }
    }

    /// Run `body` on the main thread from a run-loop callout, and return what it
    /// returns. The mechanism of `run`, separate from the alert so it can be tested:
    /// a body that spins a nested run loop (what `runModal()` does) must leave the
    /// main queue serviced.
    @MainActor
    static func runFromRunLoop<T>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { continuation.resume(returning: body()) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

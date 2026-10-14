/// One run at a time for a poll that works off the main thread.
///
/// The app refreshes branches, pull requests, dev servers and context usage from
/// timers, each in a detached task. A timer does not care whether the previous
/// tick has finished: when a poll runs longer than its interval (a slow `gh`, a
/// busy disk, a sleeping network), the next tick starts a second copy, and a
/// third behind it — more processes and threads, each making the machine slower
/// and the next poll slower still.
///
/// A request that arrives while a run is in flight is not dropped: dropping it
/// would leave the screen showing the state from before the event that asked
/// (a `Stop` hook asks for a fresh context reading precisely *because* the
/// transcript just changed). It is remembered, and exactly one more run happens
/// when the current one ends.
struct SingleFlight {
    private(set) var isRunning = false
    private var rerunRequested = false

    /// Ask to start. True: go ahead (and call `end()` when done). False: a run is
    /// already in flight and will repeat itself once when it finishes.
    mutating func begin() -> Bool {
        if isRunning {
            rerunRequested = true
            return false
        }
        isRunning = true
        return true
    }

    /// The run finished. True when another request arrived meanwhile — the
    /// caller should start one more run.
    mutating func end() -> Bool {
        isRunning = false
        defer { rerunRequested = false }
        return rerunRequested
    }
}

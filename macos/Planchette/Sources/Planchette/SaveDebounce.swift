import Foundation

/// When `state.json` should be written after a change.
///
/// A plain trailing-edge debounce — "save once nothing changed for a second" —
/// has a hole: while changes keep arriving less than a second apart, the save
/// keeps being pushed back and never happens. A busy agent turn is exactly that
/// (titles, directories and states move for minutes), so a crash in the middle
/// of one lost every change since the turn began.
///
/// The ceiling closes it: however busy it is, the oldest unsaved change waits at
/// most `ceiling` seconds.
struct SaveDebounce {
    /// Wait this long after the last change, so a burst becomes one write.
    var quiet: TimeInterval = 1
    /// Never wait longer than this after the first unsaved change.
    var ceiling: TimeInterval = 10

    private(set) var firstPendingAt: Date?

    /// A change happened at `now`. Returns how long to wait before saving.
    mutating func delay(changeAt now: Date) -> TimeInterval {
        let first = firstPendingAt ?? now
        firstPendingAt = first
        let untilCeiling = ceiling - now.timeIntervalSince(first)
        return max(0, min(quiet, untilCeiling))
    }

    /// Everything pending reached the disk.
    mutating func saved() {
        firstPendingAt = nil
    }
}

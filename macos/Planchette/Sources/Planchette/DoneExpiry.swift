import Foundation

/// How long a terminal keeps its "done" check (`AttentionState.ready`) before it
/// goes back to free. A finished turn is a report until you look at it — but a
/// check that is still there a week later says nothing any more, it only hides
/// the terminals that finished today. Settings → Project panel; 1 day by default.
///
/// Pure date math, so the boundary is unit-tested.
enum DoneExpiry: String, CaseIterable, Identifiable, Codable {
    case oneHour, fourHours, twelveHours, oneDay, threeDays, oneWeek, never

    static let `default`: DoneExpiry = .oneDay

    var id: String { rawValue }

    /// Nil for `never`: the check stays until the terminal gets new work.
    var interval: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .fourHours: 4 * 3600
        case .twelveHours: 12 * 3600
        case .oneDay: 86_400
        case .threeDays: 3 * 86_400
        case .oneWeek: 7 * 86_400
        case .never: nil
        }
    }

    var label: String {
        switch self {
        case .oneHour: L10n.t(.hoursShort, 1)
        case .fourHours: L10n.t(.hoursShort, 4)
        case .twelveHours: L10n.t(.hoursShort, 12)
        case .oneDay: L10n.t(.daysShort, 1)
        case .threeDays: L10n.t(.daysShort, 3)
        case .oneWeek: L10n.t(.daysShort, 7)
        case .never: L10n.t(.doneExpiryNever)
        }
    }

    /// Whether a terminal that turned ready at `since` should be free by `now`.
    func isExpired(since: Date, now: Date) -> Bool {
        guard let interval else { return false }
        return now.timeIntervalSince(since) >= interval
    }
}

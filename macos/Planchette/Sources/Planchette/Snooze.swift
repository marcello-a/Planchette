import Foundation

/// "Not now" for a terminal or a whole project: it goes quiet — out of the
/// inbox, the badges and every notification — until the chosen moment, then one
/// reminder brings it back (see `AppState.snooze` / `checkSnoozeExpiry`).
///
/// Pure date math, so the awkward cases (a snooze taken at 23:30, DST) are
/// unit-tested instead of discovered at 9 in the morning.
enum SnoozeOption: String, CaseIterable, Identifiable {
    case oneHour
    case twoHours
    /// The next 9:00 that is still ahead — tomorrow morning, unless it is
    /// already past midnight and before 9, when "tomorrow 9am" would mean
    /// waiting a whole extra day.
    case tomorrowMorning

    var id: String { rawValue }

    var labelKey: LKey {
        switch self {
        case .oneHour: .remindIn1h
        case .twoHours: .remindIn2h
        case .tomorrowMorning: .remindTomorrow
        }
    }

    /// Hour the morning option lands on.
    static let morningHour = 9

    func date(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .twoHours: return now.addingTimeInterval(2 * 3600)
        case .tomorrowMorning:
            // `nextDate` walks forward to the next 9:00 — it handles month ends
            // and DST, which adding 86400 seconds does not.
            let next = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: Self.morningHour, minute: 0, second: 0),
                matchingPolicy: .nextTime)
            return next ?? now.addingTimeInterval(24 * 3600)
        }
    }
}

/// The pure half of snoozing, so the "is it still quiet?" rule is unit-tested
/// instead of living inside `AppState`'s view of the world. A terminal is quiet
/// while *either* its own snooze or its project's is still running.
enum Snooze {
    static func isActive(sessionUntil: Date?, groupUntil: Date?, now: Date) -> Bool {
        end(sessionUntil: sessionUntil, groupUntil: groupUntil).map { $0 > now } ?? false
    }

    /// When it comes back — the later of the two, since both have to be over.
    static func end(sessionUntil: Date?, groupUntil: Date?) -> Date? {
        [sessionUntil, groupUntil].compactMap(\.self).max()
    }
}

enum SnoozeFormat {
    /// "until 14:32" / "until Tue 09:00" — short, for a sidebar row.
    static func until(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, inSameDayAs: now) ? "Hm" : "EEEHm")
        return formatter.string(from: date)
    }
}

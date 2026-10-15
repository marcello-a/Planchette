import Foundation

/// The keys that open the search from anywhere in the app (Settings → General →
/// Search shortcut). Either one modifier tapped twice, quickly — Shift twice is the
/// default, as in the IDEs — or a key with a modifier held.
enum SearchShortcut: Equatable {
    case doubleTap(Modifier)
    case chord(key: String, modifiers: [Modifier])

    enum Modifier: String, CaseIterable {
        case control, option, shift, command

        /// The symbol macOS prints for it, in the order macOS prints them.
        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    static let `default` = SearchShortcut.doubleTap(.shift)

    /// ⌘⇧P is ⇧⌘P: the order the modifiers were pressed or written in does not matter,
    /// nor does the case of the key.
    static func == (lhs: SearchShortcut, rhs: SearchShortcut) -> Bool {
        switch (lhs, rhs) {
        case (.doubleTap(let a), .doubleTap(let b)):
            return a == b
        case (.chord(let k1, let m1), .chord(let k2, let m2)):
            return k1.lowercased() == k2.lowercased() && Set(m1) == Set(m2)
        default:
            return false
        }
    }

    /// As the menus and tooltips write it: `⇧⇧`, `⌘⇧P`.
    var label: String {
        switch self {
        case .doubleTap(let modifier):
            return modifier.symbol + modifier.symbol
        case .chord(let key, let modifiers):
            let ordered = Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined()
            return ordered + key.uppercased()
        }
    }

    /// A chord that needs a modifier besides Shift: Shift and a letter is just a
    /// capital letter, and a bare key is typing. Nil for anything else.
    static func checkedChord(key: String, modifiers: some Collection<Modifier>) -> SearchShortcut? {
        guard key.count == 1, let character = key.first, !character.isWhitespace, !character.isNewline,
              modifiers.contains(where: { $0 != .shift })
        else { return nil }
        let unique = Modifier.allCases.filter { modifiers.contains($0) }
        return .chord(key: key.lowercased(), modifiers: unique)
    }

    /// Chords the app or macOS already uses, which must not be taken: copying and
    /// pasting, quitting, the window and terminal commands. Shown to the user as
    /// "already used", and never saved.
    var isReserved: Bool {
        guard case .chord(let key, let modifiers) = self else { return false }
        switch Set(modifiers) {
        case [.command]: return ["q", "w", "n", "t", "c", "v", "x", "a", "z", ",", "h", "m"].contains(key)
        case [.command, .shift]: return ["n", "t", "k", "z"].contains(key)
        default: return false
        }
    }
}

// MARK: Stored as a short readable word, so the saved file can be edited by hand

extension SearchShortcut: RawRepresentable, Codable {
    /// `double:shift`, `chord:command+shift:p`.
    var rawValue: String {
        switch self {
        case .doubleTap(let modifier):
            return "double:\(modifier.rawValue)"
        case .chord(let key, let modifiers):
            let ordered = Modifier.allCases.filter(modifiers.contains)
            return "chord:\(ordered.map(\.rawValue).joined(separator: "+")):\(key.lowercased())"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "double" where parts.count == 2:
            guard let modifier = Modifier(rawValue: parts[1]) else { return nil }
            self = .doubleTap(modifier)
        case "chord" where parts.count == 3:
            let modifiers = parts[1].split(separator: "+").compactMap { Modifier(rawValue: String($0)) }
            guard let shortcut = Self.checkedChord(key: parts[2], modifiers: modifiers) else { return nil }
            self = shortcut
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let shortcut = SearchShortcut(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown shortcut \(raw)"))
        }
        self = shortcut
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Finds a modifier tapped twice, from the stream of modifier changes and
/// everything else the user does. Pure, so what counts as a double tap is tested.
///
/// A tap is a press and a release of the modifier **alone**, quick enough not to be
/// a hold; two taps count when the second ends soon after the first. Anything that
/// is not a modifier change — a key, a click, a scroll — ends the attempt: typing a
/// capital letter, then another, is not a double tap, and neither are two
/// Shift-clicks that select text. It fires on the *release* of the second tap, so
/// a Shift that is held down to select never opens the search.
struct DoubleTapDetector {
    /// The longest a press may last and still be a tap.
    static let longestTap: TimeInterval = 0.3
    /// The most time between the ends of two taps.
    static let window: TimeInterval = 0.5

    enum Input {
        /// The modifiers held after a change, and when.
        case modifiers(Set<SearchShortcut.Modifier>, at: TimeInterval)
        /// A key, a mouse button, a scroll: anything else.
        case other
    }

    let modifier: SearchShortcut.Modifier
    private var held: Set<SearchShortcut.Modifier> = []
    private var pressedAt: TimeInterval?
    private var firstTapEndedAt: TimeInterval?

    init(modifier: SearchShortcut.Modifier) {
        self.modifier = modifier
    }

    /// True when this input completes a double tap.
    mutating func feed(_ input: Input) -> Bool {
        switch input {
        case .other:
            pressedAt = nil
            firstTapEndedAt = nil
            return false

        case .modifiers(let now, let time):
            // The caps lock key and the like change the flags without changing these.
            guard now != held else { return false }
            defer { held = now }

            if now == [modifier], held.isEmpty {
                pressedAt = time
                return false
            }
            if now.isEmpty, let pressed = pressedAt {
                pressedAt = nil
                guard time - pressed <= Self.longestTap else {
                    firstTapEndedAt = nil
                    return false
                }
                if let first = firstTapEndedAt, time - first <= Self.window {
                    firstTapEndedAt = nil
                    return true
                }
                firstTapEndedAt = time
                return false
            }
            // Another modifier joined, or this one was let go while others stay: use, not a tap.
            pressedAt = nil
            firstTapEndedAt = nil
            return false
        }
    }
}

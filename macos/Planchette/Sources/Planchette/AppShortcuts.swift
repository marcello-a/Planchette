import SwiftUI

/// The app's menu shortcuts, and the user's changes to them (Settings → Shortcuts).
///
/// Every menu item with a key is a `ShortcutAction`; the menus ask the `ShortcutBook` for its
/// key, so a change takes effect at once and in a terminal too (`performKeyEquivalent` asks the
/// main menu). The keys that are not menu items — ⌃Tab, ⌘1–⌘9, copy and paste, the notepad's —
/// stay fixed and are only listed. Pure, unit-tested.

/// A key with its modifiers, as a menu item carries it. Every one holds ⌘: without it a menu
/// key would take a key the terminal needs (⌃C, ⌥ letters on a German keyboard).
struct KeyCombo: Hashable {
    typealias Modifier = SearchShortcut.Modifier

    /// A lowercase character, or one of the named keys (`left`, `right`, `up`, `down`).
    let key: String
    let modifiers: Set<Modifier>

    static let namedKeys: [String: String] = ["left": "←", "right": "→", "up": "↑", "down": "↓"]

    init(_ key: String, _ modifiers: Set<Modifier>) {
        self.key = Self.namedKeys[key] == nil ? key.lowercased() : key
        self.modifiers = modifiers
    }

    var isArrow: Bool { Self.namedKeys[key] != nil }

    /// As macOS writes it in a menu: `⇧⌘N`, `⌥⌘←`.
    var label: String {
        Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + keySymbol
    }

    /// Every way the texts of the app write it: macOS's order, and ⌘ first (`⌘⇧N`), as some
    /// tooltips do.
    var spellings: [String] {
        let commandFirst = "⌘" + Modifier.allCases.filter { modifiers.contains($0) && $0 != .command }
            .map(\.symbol).joined() + keySymbol
        return commandFirst == label || !modifiers.contains(.command) ? [label] : [label, commandFirst]
    }

    private var keySymbol: String { Self.namedKeys[key] ?? key.uppercased() }

    var keyboardShortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent
        switch key {
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        default: equivalent = KeyEquivalent(key.first ?? " ")
        }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }

    /// The same keys as a search shortcut chord, to compare with the search's own keys.
    var asSearchChord: SearchShortcut? {
        isArrow ? nil : .chord(key: key, modifiers: Modifier.allCases.filter(modifiers.contains))
    }

    /// `command+shift:n`; read back by `init?(rawValue:)`.
    var rawValue: String {
        Modifier.allCases.filter(modifiers.contains).map(\.rawValue).joined(separator: "+") + ":" + key
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[1].count == 1 || Self.namedKeys[parts[1]] != nil else { return nil }
        let modifiers = parts[0].split(separator: "+").map { Modifier(rawValue: String($0)) }
        guard !modifiers.contains(nil) else { return nil }
        self.init(parts[1], Set(modifiers.compactMap { $0 }))
    }
}

/// A menu item whose key can be changed.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newProject, newWindow, closeTerminal, closeWindow
    case addTerminal, reopenClosedTerminal, splitRight, splitDown, notepad, newWorktree
    case quickSwitcher, jumpToWaiting, previousTab, nextTab, previousProject, nextProject
    case find, findNext, findPrevious
    case projectPanel, notificationsPanel, reviewsPanel, todos, jira

    var id: String { rawValue }

    enum Group: CaseIterable, Identifiable {
        case windows, terminals, navigation, find, panels
        var id: Self { self }

        var titleKey: LKey {
            switch self {
            case .windows: .shortcutsGroupWindows
            case .terminals: .shortcutsGroupTerminals
            case .navigation: .shortcutsGroupNavigation
            case .find: .shortcutsGroupFind
            case .panels: .shortcutsGroupPanels
            }
        }

        var actions: [ShortcutAction] { ShortcutAction.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .newProject, .newWindow, .closeTerminal, .closeWindow: .windows
        case .addTerminal, .reopenClosedTerminal, .splitRight, .splitDown, .notepad, .newWorktree: .terminals
        case .quickSwitcher, .jumpToWaiting, .previousTab, .nextTab, .previousProject, .nextProject: .navigation
        case .find, .findNext, .findPrevious: .find
        case .projectPanel, .notificationsPanel, .reviewsPanel, .todos, .jira: .panels
        }
    }

    /// The menu item's own name.
    var titleKey: LKey {
        switch self {
        case .newProject: .newProject
        case .newWindow: .newWindow
        case .closeTerminal: .closeTabMenu
        case .closeWindow: .closeWindowMenu
        case .addTerminal: .addTerminal
        case .reopenClosedTerminal: .reopenClosedTab
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .notepad: .notepad
        case .newWorktree: .newWorktree
        case .quickSwitcher: .quickSwitcher
        case .jumpToWaiting: .jumpToWaiting
        case .previousTab: .previousTab
        case .nextTab: .nextTab
        case .previousProject: .previousProject
        case .nextProject: .nextProject
        case .find: .findMenu
        case .findNext: .findNextMenu
        case .findPrevious: .findPreviousMenu
        case .projectPanel: .projectPanelTab
        case .notificationsPanel: .notificationsPanel
        case .reviewsPanel: .reviewsPanel
        case .todos: .todos
        case .jira: .jiraTitle
        }
    }

    /// The key the app ships with. Why each is what it is: see the menus in `PlanchetteApp`.
    var defaultCombo: KeyCombo {
        switch self {
        case .newProject: KeyCombo("n", [.command])
        case .newWindow: KeyCombo("n", [.command, .shift])
        case .closeTerminal: KeyCombo("w", [.command])
        case .closeWindow: KeyCombo("w", [.command, .shift])
        case .addTerminal: KeyCombo("t", [.command])
        case .reopenClosedTerminal: KeyCombo("t", [.command, .control])
        case .splitRight: KeyCombo("d", [.command])
        case .splitDown: KeyCombo("d", [.command, .shift])
        case .notepad: KeyCombo("j", [.command])
        case .newWorktree: KeyCombo("t", [.command, .shift])
        case .quickSwitcher: KeyCombo("k", [.command])
        case .jumpToWaiting: KeyCombo("k", [.command, .shift])
        case .previousTab: KeyCombo("left", [.command, .option])
        case .nextTab: KeyCombo("right", [.command, .option])
        case .previousProject: KeyCombo("up", [.command, .option])
        case .nextProject: KeyCombo("down", [.command, .option])
        case .find: KeyCombo("f", [.command])
        case .findNext: KeyCombo("g", [.command])
        case .findPrevious: KeyCombo("g", [.command, .shift])
        case .projectPanel: KeyCombo("s", [.command, .control])
        case .notificationsPanel: KeyCombo("n", [.command, .control])
        case .reviewsPanel: KeyCombo("r", [.command, .control])
        case .todos: KeyCombo("b", [.command, .control])
        case .jira: KeyCombo("j", [.command, .control])
        }
    }
}

/// What the user changed: per action a new key, or none at all. An action without an entry
/// has its default. Persisted as `PersistedState.shortcuts`.
struct ShortcutBook: Equatable {
    /// `.some(nil)`: the user removed the shortcut.
    private(set) var overrides: [ShortcutAction: KeyCombo?] = [:]

    func combo(for action: ShortcutAction) -> KeyCombo? {
        if let override = overrides[action] { return override }
        return action.defaultCombo
    }

    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        combo(for: action)?.keyboardShortcut
    }

    func isChanged(_ action: ShortcutAction) -> Bool { overrides[action] != nil }

    var isEmpty: Bool { overrides.isEmpty }

    /// A key equal to the default is no change: it is not stored.
    mutating func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if combo == action.defaultCombo {
            overrides[action] = nil
        } else {
            overrides[action] = .some(combo)
        }
    }

    mutating func reset(_ action: ShortcutAction) { overrides[action] = nil }
    mutating func resetAll() { overrides = [:] }

    /// The action that has these keys now, other than `except`.
    func owner(of combo: KeyCombo, except: ShortcutAction? = nil) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != except && self.combo(for: $0) == combo }
    }

    /// Why a key cannot be given to `action`, or nil when it can.
    enum Refusal: Equatable {
        /// No ⌘ in it.
        case needsCommand
        /// ⇧ with a key that is not a letter or an arrow: ⇧1 is `!` on one keyboard and `+` on
        /// another, and the menu matches the character.
        case shiftNeedsLetter
        /// macOS's, the terminal's or a fixed key of the app.
        case reserved
        /// Another action has it.
        case taken(ShortcutAction)
        /// It opens the search (Settings → Shortcuts → Search).
        case search
    }

    func refusal(of combo: KeyCombo, for action: ShortcutAction, search: SearchShortcut) -> Refusal? {
        guard combo.modifiers.contains(.command) else { return .needsCommand }
        if combo.modifiers.contains(.shift), !combo.isArrow, !(combo.key.first?.isLetter ?? false) {
            return .shiftNeedsLetter
        }
        if Self.isReserved(combo) { return .reserved }
        if let owner = owner(of: combo, except: action) { return .taken(owner) }
        if let chord = combo.asSearchChord, chord == search { return .search }
        return nil
    }

    /// Keys that are not the menus' to give: quitting, hiding, the edit commands, Settings, the
    /// terminal's font size, the numbered tabs and projects.
    static func isReserved(_ combo: KeyCombo) -> Bool {
        let key = combo.key
        switch combo.modifiers {
        case [.command]:
            return ["q", "h", "m", ",", "c", "v", "x", "a", "z", "=", "+", "-", "0", "`", "."].contains(key)
                || ("1"..."9").contains(key)
        case [.command, .shift]:
            return ["z", "="].contains(key)
        case [.command, .option]:
            return ["h", "m", "w"].contains(key) || ("1"..."9").contains(key)
        default:
            return false
        }
    }

    /// `text` with every changed key written as it is now: `(⌘T)` becomes `(⌥⌘T)`, or goes away
    /// when the shortcut was removed. A key inside a longer one is left alone (`⌘T` in `⌃⌘T`),
    /// and every place is replaced once, so two keys that swapped do not swap back.
    func rewrite(_ text: String) -> String {
        Self.rewrite(text, replacements: replacements)
    }

    /// From the default's spellings to the new key, longest first.
    var replacements: [(from: String, to: String)] {
        var pairs: [(from: String, to: String)] = []
        for (action, override) in overrides {
            for spelling in action.defaultCombo.spellings {
                if let override {
                    pairs.append((spelling, override.label))
                } else {
                    pairs.append((" (\(spelling))", ""))
                }
            }
        }
        return pairs.sorted { $0.from.count > $1.from.count }
    }

    static func rewrite(_ text: String, replacements: [(from: String, to: String)]) -> String {
        guard !replacements.isEmpty, text.contains("⌘") else { return text }
        let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        let characters = Array(text)
        var result = ""
        var index = 0
        scan: while index < characters.count {
            let previous = index > 0 ? characters[index - 1] : nil
            if previous.map({ !modifierSymbols.contains($0) }) ?? true {
                for pair in replacements {
                    let from = Array(pair.from)
                    let end = index + from.count
                    guard end <= characters.count, Array(characters[index..<end]) == from else { continue }
                    // `⌘T` is not the start of `⌘Tab`.
                    if end < characters.count, let last = from.last, last.isLetter || last.isNumber,
                       characters[end].isLetter || characters[end].isNumber {
                        continue
                    }
                    result += pair.to
                    index = end
                    continue scan
                }
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }
}

// MARK: Stored as readable words: `{"newProject": "command+shift:p", "notepad": ""}`

extension ShortcutBook: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        for (name, value) in raw {
            // An action this version does not know, or a key it cannot read, costs that one entry.
            guard let action = ShortcutAction(rawValue: name) else { continue }
            if value.isEmpty {
                overrides[action] = .some(nil)
            } else if let combo = KeyCombo(rawValue: value) {
                set(combo, for: action)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var raw: [String: String] = [:]
        for (action, override) in overrides { raw[action.rawValue] = override?.rawValue ?? "" }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// The keys the app has that are not menu items, so they cannot be changed — only shown.
enum FixedShortcut: CaseIterable, Identifiable {
    case settings, goToTab, goToProject, cycleTab, cycleProject
    case copyPaste, fontSize, notepadMarkdown, notepadRun, durableNewline, durableSendNow

    var id: Self { self }

    var titleKey: LKey {
        switch self {
        case .settings: .settingsTitle
        case .goToTab: .goToTab
        case .goToProject: .goToProject
        case .cycleTab: .nextTab
        case .cycleProject: .nextProject
        case .copyPaste: .shortcutsCopyPaste
        case .fontSize: .shortcutsFontSize
        case .notepadMarkdown: .notepadShortcutsTitle
        case .notepadRun: .notepadRunLine
        case .durableNewline: .shortcutsDurableNewline
        case .durableSendNow: .shortcutsDurableSendNow
        }
    }

    var label: String {
        switch self {
        case .settings: "⌘,"
        case .goToTab: "⌘1–⌘9"
        case .goToProject: "⌥⌘1–⌥⌘9"
        case .cycleTab: "⌃⇥"
        case .cycleProject: "⌃⇧⇥"
        case .copyPaste: "⌘C ⌘V ⌘A"
        case .fontSize: "⌘+ ⌘- ⌘0"
        case .notepadMarkdown: "⌘B ⌘I ⌘E"
        case .notepadRun: "⌘↩"
        case .durableNewline: "⇧↩"
        case .durableSendNow: "⌃↩"
        }
    }
}

extension View {
    /// The menu item's key, as Settings → Shortcuts has it now; none when it was removed.
    func shortcut(_ action: ShortcutAction, _ book: ShortcutBook) -> some View {
        keyboardShortcut(book.keyboardShortcut(for: action))
    }
}

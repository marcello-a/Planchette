import SwiftUI

/// Listens for the new keys of one menu shortcut (Settings → Shortcuts).
///
/// A local monitor sees the key before the menu does, so pressing ⌘T here records ⌘T and does
/// not also open a terminal. The search's double tap is off while it listens. Esc cancels,
/// Delete removes the shortcut, a click elsewhere ends the listening.
@MainActor
final class MenuShortcutRecorder: ObservableObject {
    @Published private(set) var action: ShortcutAction?
    /// Why the last keys were not taken, in words the user can act on.
    @Published private(set) var note: String?

    private var token: Any?
    private weak var searchMonitor: SearchShortcutMonitor?

    func start(_ action: ShortcutAction, appState: AppState) {
        stop()
        note = nil
        self.action = action
        searchMonitor = appState.searchShortcutMonitor
        searchMonitor?.isSuspended = true
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self, weak appState] event in
            guard let self, let appState else { return event }
            return self.handle(event, appState: appState)
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        searchMonitor?.isSuspended = false
        searchMonitor = nil
        action = nil
    }

    private func handle(_ event: NSEvent, appState: AppState) -> NSEvent? {
        guard let action else { return event }
        guard event.type == .keyDown else {
            // A click on another row's key starts that one; anywhere else ends the listening.
            stop()
            return event
        }
        switch event.keyCode {
        case 53:   // Esc
            stop()
            return nil
        case 51, 117:   // Delete, forward delete: no shortcut at all
            appState.shortcuts.set(nil, for: action)
            stop()
            return nil
        default:
            break
        }
        guard let combo = Self.combo(of: event) else {
            note = L10n.t(.shortcutsNeedsCommand)
            return nil
        }
        switch appState.shortcuts.refusal(of: combo, for: action, search: appState.searchShortcut) {
        case nil:
            appState.shortcuts.set(combo, for: action)
            stop()
        case .needsCommand:
            note = L10n.t(.shortcutsNeedsCommand)
        case .shiftNeedsLetter:
            note = L10n.t(.shortcutsShiftLetters)
        case .reserved:
            note = L10n.t(.shortcutsReserved, combo.label)
        case .taken(let owner):
            note = L10n.t(.shortcutsTaken, combo.label, L10n.t(owner.titleKey))
        case .search:
            note = L10n.t(.shortcutsTaken, combo.label, L10n.t(.searchShortcutTitle))
        }
        return nil
    }

    /// The keys of a key press, by the key's place on the keyboard: ⇧⌘D is `d` with ⇧, not `D`,
    /// and ⌥⌘L stays `l` on a layout where ⌥L types `@`. Nil for a key a menu cannot carry.
    static func combo(of event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags
        var modifiers: Set<KeyCombo.Modifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let arrows: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up"]
        if let arrow = arrows[event.keyCode] { return KeyCombo(arrow, modifiers) }
        guard let characters = event.characters(byApplyingModifiers: []), characters.count == 1,
              let character = characters.first,
              !character.isWhitespace, !character.isNewline,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return nil }
        return KeyCombo(String(character), modifiers)
    }
}

/// Settings → Shortcuts: every key of the app. The menu keys can be changed; the others are
/// listed so the page is the one place to look.
struct ShortcutSettings: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recorder = MenuShortcutRecorder()

    var body: some View {
        Form {
            Section {
                Text(L10n.t(.shortcutsIntro))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = recorder.note, recorder.action != nil {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            // First: the key that opens the search is the one most people change.
            Section(L10n.t(.searchSection)) {
                SearchShortcutSetting()
            }
            ForEach(ShortcutAction.Group.allCases) { group in
                Section(L10n.t(group.titleKey)) {
                    ForEach(group.actions) { action in
                        row(action)
                    }
                }
            }
            Section {
                ForEach(FixedShortcut.allCases) { fixed in
                    HStack {
                        Text(L10n.t(fixed.titleKey))
                        Spacer()
                        KeyCap(text: fixed.label, style: .fixed)
                    }
                }
            } header: {
                Text(L10n.t(.shortcutsGroupFixed))
            } footer: {
                Text(L10n.t(.shortcutsFixedHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !appState.shortcuts.isEmpty {
                Section {
                    Button(L10n.t(.shortcutsResetAll)) {
                        recorder.stop()
                        appState.shortcuts.resetAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.stop() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let recording = recorder.action == action
        let combo = appState.shortcuts.combo(for: action)
        return HStack(spacing: 8) {
            Text(L10n.t(action.titleKey))
            Spacer()
            if appState.shortcuts.isChanged(action) && !recording {
                Button {
                    appState.shortcuts.reset(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(L10n.t(.shortcutsReset, action.defaultCombo.label))
            }
            Button {
                if recording { recorder.stop() } else { recorder.start(action, appState: appState) }
            } label: {
                KeyCap(text: recording ? L10n.t(.shortcutsRecording) : (combo?.label ?? L10n.t(.shortcutsNone)),
                       style: recording ? .recording : (combo == nil ? .none : .key))
            }
            .buttonStyle(.plain)
            .help(L10n.t(.shortcutsChangeHelp))
        }
    }
}

/// A key as a small cap, the way the menus and the Help tab show it.
struct KeyCap: View {
    enum Style { case key, fixed, none, recording }
    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(style == .recording || style == .none ? .callout : .system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(foreground)
            .frame(minWidth: 64)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(style == .fixed ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style == .recording ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch style {
        case .key: .primary
        case .fixed, .none: .secondary
        case .recording: .accentColor
        }
    }
}

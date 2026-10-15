import SwiftUI

/// Records a new search shortcut: tap a modifier twice, or press a key with ⌘, ⌃ or ⌥.
///
/// While it listens, the search itself is switched off (`SearchShortcutMonitor.isSuspended`)
/// — the keys pressed are the answer, not a request — and the key presses are
/// swallowed, so a letter does not also land in a text field.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Why the last attempt was not taken, in words the user can act on.
    @Published private(set) var note: String?

    private var token: Any?
    private var detectors: [SearchShortcut.Modifier: DoubleTapDetector] = [:]
    private var onRecorded: ((SearchShortcut) -> Void)?
    private weak var searchMonitor: SearchShortcutMonitor?

    func start(suspending monitor: SearchShortcutMonitor, onRecorded: @escaping (SearchShortcut) -> Void) {
        stop()
        note = nil
        self.onRecorded = onRecorded
        searchMonitor = monitor
        monitor.isSuspended = true
        detectors = Dictionary(uniqueKeysWithValues: SearchShortcut.Modifier.allCases.map { ($0, DoubleTapDetector(modifier: $0)) })
        isRecording = true
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        searchMonitor?.isSuspended = false
        searchMonitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            for modifier in detectors.keys { _ = detectors[modifier]?.feed(.other) }
            if event.keyCode == 53 { stop(); return nil }   // Esc
            let held = SearchShortcutMonitor.modifiers(of: event.modifierFlags)
            guard let key = event.charactersIgnoringModifiers, key.count == 1,
                  let shortcut = SearchShortcut.checkedChord(key: key, modifiers: held)
            else {
                note = L10n.t(.searchShortcutNeedsModifier)
                return nil
            }
            guard !shortcut.isReserved else {
                note = L10n.t(.searchShortcutTaken, shortcut.label)
                return nil
            }
            finish(with: shortcut)
            return nil

        case .flagsChanged:
            let held = SearchShortcutMonitor.modifiers(of: event.modifierFlags)
            for modifier in SearchShortcut.Modifier.allCases {
                if detectors[modifier]?.feed(.modifiers(held, at: event.timestamp)) == true {
                    finish(with: .doubleTap(modifier))
                    break
                }
            }
            return event

        default:
            // A click outside the control ends the listening, as it ends any field.
            for modifier in detectors.keys { _ = detectors[modifier]?.feed(.other) }
            stop()
            return event
        }
    }

    private func finish(with shortcut: SearchShortcut) {
        let callback = onRecorded
        stop()
        callback?(shortcut)
    }
}

/// Settings → General → Search: the keys that open the search, and a way to change them.
struct SearchShortcutSetting: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.t(.searchShortcutTitle))
                Spacer()
                Text(recorder.isRecording ? L10n.t(.searchShortcutRecording) : appState.searchShortcut.label)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(recorder.isRecording ? Color.accentColor : .primary)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                if recorder.isRecording {
                    Button(L10n.t(.searchShortcutCancel)) { recorder.stop() }
                } else {
                    Button(L10n.t(.searchShortcutChange)) {
                        recorder.start(suspending: appState.searchShortcutMonitor) { appState.searchShortcut = $0 }
                    }
                    if appState.searchShortcut != .default {
                        Button(L10n.t(.searchShortcutReset, SearchShortcut.default.label)) {
                            appState.searchShortcut = .default
                        }
                    }
                }
            }
            Text(L10n.t(recorder.isRecording ? .searchShortcutRecordingHelp : .searchShortcutHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = recorder.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { recorder.stop() }
    }
}

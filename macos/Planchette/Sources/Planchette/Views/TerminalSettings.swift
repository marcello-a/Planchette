import SwiftUI

/// Settings → Terminals: how a terminal lives — what survives a quit, when an idle Claude sleeps,
/// how long a result stays news, what comes back at launch, and its notepad. These were spread
/// over General, Project panel and Tabs, each beside settings about something else.
struct TerminalSettings: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section(L10n.t(.durableSection)) {
                Toggle(L10n.t(.durableActive), isOn: $appState.durableTerminals)
                    .disabled(!Durable.isAvailable)
                    .help(L10n.t(.durableHelp))
                Picker(L10n.t(.claudeSleepTitle), selection: $appState.claudeSleep) {
                    Text(L10n.t(.claudeSleepOff)).tag(ClaudeSleep.off)
                    Text(L10n.t(.claudeSleep2h)).tag(ClaudeSleep.after2h)
                    Text(L10n.t(.claudeSleep8h)).tag(ClaudeSleep.after8h)
                    Text(L10n.t(.claudeSleep24h)).tag(ClaudeSleep.after24h)
                }
                .help(L10n.t(.claudeSleepHelp))
                .accessibilityLabel(L10n.t(.claudeSleepTitle))
                Text(L10n.t(Durable.isAvailable ? .durableExplanation : .durableMissingTmux))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !Durable.isAvailable {
                    InstallTmuxRow()
                }
            }
            Section(L10n.t(.terminalStatusSection)) {
                // The check this is about, in front of its name: the one in the terminal's row.
                Picker(selection: $appState.doneExpiry) {
                    ForEach(DoneExpiry.allCases) { Text($0.label).tag($0) }
                } label: {
                    HStack(spacing: 6) {
                        StateIcon(state: .ready, size: 14)
                        Text(L10n.t(.doneExpiryTitle))
                    }
                }
                Text(L10n.t(.doneExpiryHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The icon of the state it holds a terminal at.
                Toggle(isOn: $appState.backgroundCountsAsRunning) {
                    HStack(spacing: 6) {
                        StateIcon(state: .running, size: 14, inBackground: true)
                        Text(L10n.t(.backgroundRunningTitle))
                    }
                }
                Text(L10n.t(.backgroundRunningHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.t(.startupSection)) {
                // Said the way it reads: on means it happens. The stored flag is the question.
                Toggle(L10n.t(.restoreAtLaunch), isOn: Binding(
                    get: { !appState.askBeforeRestore }, set: { appState.askBeforeRestore = !$0 }))
                Text(L10n.t(.restoreAtLaunchHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What ends a prompt in the notepad, and what happens to a prompt once it is sent.
            Section(L10n.t(.notepadSettingsSection)) {
                Picker(L10n.t(.notepadReturnsTitle), selection: $appState.notepad.returnsPerPrompt) {
                    ForEach(Array(NotepadLook.returnsRange), id: \.self) { count in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t(Self.returnsTitle[count] ?? .notepadReturnsTwo))
                            Text(L10n.t(Self.returnsHelp[count] ?? .notepadReturnsTwoHelp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(count)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker(L10n.t(.notepadAfterTitle), selection: $appState.notepad.afterLoading) {
                    ForEach(NotepadAfterLoading.allCases) { action in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t(Self.afterTitle[action] ?? .notepadAfterRemove))
                            Text(L10n.t(Self.afterHelp[action] ?? .notepadAfterRemoveHelp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(action)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }

    private static let returnsTitle: [Int: LKey] = [
        1: .notepadReturnsOne, 2: .notepadReturnsTwo, 3: .notepadReturnsThree,
    ]
    private static let afterTitle: [NotepadAfterLoading: LKey] = [
        .remove: .notepadAfterRemove, .strike: .notepadAfterStrike, .keep: .notepadAfterKeep,
    ]
    private static let afterHelp: [NotepadAfterLoading: LKey] = [
        .remove: .notepadAfterRemoveHelp, .strike: .notepadAfterStrikeHelp, .keep: .notepadAfterKeepHelp,
    ]
    private static let returnsHelp: [Int: LKey] = [
        1: .notepadReturnsOneHelp, 2: .notepadReturnsTwoHelp, 3: .notepadReturnsThreeHelp,
    ]

}

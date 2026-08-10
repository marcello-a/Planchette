import SwiftUI

/// Context-menu block for "I've dealt with this" / "not now": mark free, or
/// snooze until a moment and be reminded then. One component, so a terminal
/// offers the same choices in the sidebar, the tab bar and the notifications
/// panel.
struct SessionAttentionMenu: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession

    var body: some View {
        Button(L10n.t(.markReady)) { appState.markReady(session.id) }
        Menu(L10n.t(.remindMe)) {
            ForEach(SnoozeOption.allCases) { option in
                Button(L10n.t(option.labelKey)) {
                    appState.snooze(session: session.id, until: option.date(from: Date()))
                }
            }
            if session.snoozedUntil != nil {
                Divider()
                Button(L10n.t(.remindCancel)) { appState.clearSnooze(session: session.id) }
            }
        }
        .help(L10n.t(.remindMeHelp))
    }
}

/// The same for a whole project — one reminder for the project, not one per tab.
struct GroupAttentionMenu: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup

    var body: some View {
        Button(L10n.t(.markGroupReady)) { appState.markGroupReady(group.id) }
        Menu(L10n.t(.remindMe)) {
            ForEach(SnoozeOption.allCases) { option in
                Button(L10n.t(option.labelKey)) {
                    appState.snooze(group: group.id, until: option.date(from: Date()))
                }
            }
            if group.snoozedUntil != nil {
                Divider()
                Button(L10n.t(.remindCancel)) { appState.clearSnooze(group: group.id) }
            }
        }
        .help(L10n.t(.remindMeHelp))
    }
}

/// "🔕 quiet until 14:30" — shown wherever a snoozed terminal or project is
/// listed, so a silent inbox is explained rather than mysterious.
struct SnoozeBadge: View {
    let until: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bell.slash.fill")
            Text(SnoozeFormat.until(until))
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .help(L10n.t(.quietUntil, SnoozeFormat.until(until)))
    }
}

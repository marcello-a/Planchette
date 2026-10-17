import AppKit
import SwiftUI

/// Settings → Durable terminals, when tmux is missing: the install command
/// with a copy button, and one click to a terminal with it already typed —
/// pressing Enter there is what runs it, so a click can never install anything
/// by itself. Also on the welcome screen and in the prompt after an update.
struct InstallTmuxRow: View {
    @EnvironmentObject var appState: AppState
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(Durable.installCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Durable.installCommand, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L10n.t(.installTmuxCopy))
            Button(L10n.t(.installTmuxOpen)) {
                appState.openTerminalTyping(Durable.installCommand)
            }
            .help(L10n.t(.installTmuxOpenHelp))
        }
    }
}

/// What durable terminals do and why they matter, with the way to get them: the
/// install command when tmux is missing, the switch when it is installed but off,
/// a confirmation when it is all on. Shared by the welcome screen and the prompt
/// after an update, so the two can never tell different stories.
///
/// It looks for tmux every two seconds while it is on screen: whoever runs the
/// install command in the terminal it opened comes back to a card that already
/// knows, with no "check again" to press.
struct DurableIntroCard: View {
    @EnvironmentObject var appState: AppState
    var showsTitle = true
    @State private var tmuxFound = Durable.isAvailable
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Label(L10n.t(.durableSection), systemImage: "bolt.shield.fill")
                    .font(.headline)
            }
            Text(L10n.t(.durableWhy))
                .fixedSize(horizontal: false, vertical: true)
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .onReceive(poll) { _ in tmuxFound = Durable.isAvailable }
    }

    @ViewBuilder
    private var status: some View {
        if !tmuxFound {
            Text(L10n.t(.durableNeedsTmux))
                .font(.callout)
                .foregroundStyle(.secondary)
            InstallTmuxRow()
        } else if !appState.durableTerminals {
            Text(L10n.t(.durableIsOff))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L10n.t(.durableTurnOn)) { appState.durableTerminals = true }
        } else {
            Label(L10n.t(.durableIsOn), systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The one nudge after an update, for somebody without durable terminals — see
/// `OnboardingState.durablePromptDue`. The checkbox is a setting, not a button's
/// argument: it applies when it is ticked, so Escape and Close mean the same thing.
struct DurablePromptSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var hideForever = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                Text(L10n.t(.durablePromptTitle))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            DurableIntroCard(showsTitle: false)
            Text(L10n.t(.durablePromptNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle(L10n.t(.durablePromptHide), isOn: $hideForever)
                    .toggleStyle(.checkbox)
                Spacer()
                Button(L10n.t(.close)) { appState.closeDurablePrompt() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { hideForever = appState.onboarding.durablePromptHidden }
        .onChange(of: hideForever) { _, hide in appState.hideDurablePrompt(hide) }
    }
}

/// The first thing somebody sees who has never run Planchette: what it is for, the
/// feature that matters most first, the durable terminals with the means to get them
/// right here, and where the settings are. The main area shows it until the first
/// project exists; after that an empty window is only the small start screen.
struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    let openFirstTerminal: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 72, height: 72)
                    Text("Planchette").font(.largeTitle.bold())
                    Text(L10n.t(.tagline)).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    // The two that set Planchette apart, first and set apart.
                    feature("arrow.counterclockwise.circle.fill", .welcomeStaysTitle, .welcomeStaysBody)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    feature("note.text", .welcomeNotepadTitle, .welcomeNotepadBody)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    feature("questionmark.bubble.fill", .welcomeStatesTitle, .welcomeStatesBody)
                    feature("magnifyingglass", .welcomeFindTitle, .welcomeFindBody, appState.searchShortcut.label)
                    feature("bell.badge.fill", .welcomeNotifyTitle, .welcomeNotifyBody)
                }

                DurableIntroCard()

                feature("gearshape.fill", .welcomeSettingsTitle, .welcomeSettingsBody)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(L10n.t(.openFirstTerminal), action: openFirstTerminal)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func feature(_ symbol: String, _ title: LKey, _ body: LKey, _ args: CVarArg...) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title)).fontWeight(.semibold)
                Text(args.isEmpty ? L10n.t(body) : String(format: L10n.t(body), arguments: args))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

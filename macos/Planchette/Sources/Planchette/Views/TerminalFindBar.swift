import SwiftUI

/// The find bar over a terminal (⌘F): a field, how many matches there are, step
/// buttons and a close button. The matches themselves are highlighted in the terminal
/// by whoever searches — libghostty, or tmux for a durable terminal (`AppState.finds`).
struct TerminalFindBar: View {
    @EnvironmentObject var appState: AppState
    let sessionID: UUID
    @State private var needle = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let find = appState.finds[sessionID] {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.t(.findPlaceholder), text: $needle)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .frame(width: 180)
                    .onSubmit { appState.stepFind(in: sessionID, forward: true) }
                    // Return is the field's own (`onSubmit`); with Shift it goes back.
                    .onKeyPress(.return) {
                        guard NSEvent.modifierFlags.contains(.shift) else { return .ignored }
                        appState.stepFind(in: sessionID, forward: false)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        appState.endFind(in: sessionID)
                        return .handled
                    }
                Text(find.countLabel())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(find.hasNoResults ? Color.red : Color.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
                Button { appState.stepFind(in: sessionID, forward: false) } label: {
                    Image(systemName: "chevron.up")
                }
                .help(L10n.t(.findPreviousHelp))
                Button { appState.stepFind(in: sessionID, forward: true) } label: {
                    Image(systemName: "chevron.down")
                }
                .help(L10n.t(.findNextHelp))
                Button { appState.endFind(in: sessionID) } label: {
                    Image(systemName: "xmark")
                }
                .help(L10n.t(.findCloseHelp))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(10)
            .onAppear {
                needle = find.needle
                focused = true
            }
            .onChange(of: needle) { _, text in appState.updateFind(text, in: sessionID) }
            // ⌘F again, with the bar open: the keyboard comes back to the field.
            .onChange(of: find.focusRequests) { _, _ in focused = true }
        }
    }
}

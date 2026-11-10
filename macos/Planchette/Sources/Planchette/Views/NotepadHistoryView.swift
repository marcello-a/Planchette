import AppKit
import SwiftUI

/// What left a notepad, newest first: the prompts that went into the terminal, the lines that were
/// deleted, the pad from before "Format with AI". Each one can go back into the pad or be copied.
struct NotepadHistoryView: View {
    @EnvironmentObject var appState: AppState
    let sessionID: UUID
    /// Put an entry's text back into the pad.
    let onRestore: (String) -> Void
    /// Read when the list opens: the history is not published (see `AppState.notepadHistory`).
    @State private var entries: [NotepadHistoryEntry] = []
    /// The height of all rows. A scroll view in a popover takes no height of its own, so the list
    /// is as high as its rows, up to `maximumHeight`, and scrolls after that.
    @State private var rowsHeight: CGFloat = 0
    private static let maximumHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.t(.notepadHistory)).font(.headline)
                Spacer()
                Button(L10n.t(.notepadHistoryClear)) {
                    appState.clearNotepadHistory(for: sessionID)
                    entries = []
                }
                .controlSize(.small)
                .disabled(entries.isEmpty)
            }
            .padding(10)
            Divider()
            if entries.isEmpty {
                Text(L10n.t(.notepadHistoryEmpty))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            NotepadHistoryRow(entry: entry, onRestore: onRestore)
                            Divider()
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { rowsHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in rowsHeight = height }
                    })
                }
                .frame(height: min(max(rowsHeight, 1), Self.maximumHeight))
            }
        }
        .frame(width: 320)
        .onAppear { entries = appState.notepadHistory(for: sessionID) }
    }
}

private struct NotepadHistoryRow: View {
    let entry: NotepadHistoryEntry
    let onRestore: (String) -> Void
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var kind: (icon: String, label: LKey) {
        switch entry.kind {
        case .sent: ("paperplane", .notepadHistorySent)
        case .deleted: ("trash", .notepadHistoryDeleted)
        case .formatted: ("wand.and.stars", .notepadHistoryFormatted)
        }
    }

    private var when: String {
        Self.relative.locale = Locale(identifier: L10n.current.resolved.rawValue)
        return Self.relative.localizedString(for: entry.date, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 12, design: entry.text.contains("```") ? .monospaced : .default))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.t(kind.label) + " · " + when)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Button { onRestore(entry.text) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L10n.t(.notepadHistoryRestore))
                    .accessibilityLabel(L10n.t(.notepadHistoryRestore))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help(L10n.t(.notepadHistoryCopy))
                    .accessibilityLabel(L10n.t(.notepadHistoryCopy))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A double click puts it back, like the button.
        .onTapGesture(count: 2) { onRestore(entry.text) }
        .help(entry.text)
    }
}

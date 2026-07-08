import SwiftUI

/// Small tag chips ("to test", "review", …).
struct TagChips: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

/// Context-menu section for toggling tags on a session.
struct TagMenu: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession

    var body: some View {
        Menu(L10n.t(.tags)) {
            ForEach(appState.knownTags, id: \.self) { tag in
                Button {
                    appState.toggleTag(tag, on: session.id)
                } label: {
                    HStack {
                        Text(tag)
                        if session.tags.contains(tag) { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button(L10n.t(.newTag)) { promptNewTag() }
            if !session.tags.isEmpty {
                Button(L10n.t(.removeAllTags)) {
                    appState.update(session.id) { $0.tags = [] }
                }
            }
        }
        .help(L10n.t(.tagsHelp))
    }

    private func promptNewTag() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.newTagTitle)
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "to test"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let tag = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            guard !tag.isEmpty else { return }
            appState.toggleTag(tag, on: session.id)
        }
    }
}

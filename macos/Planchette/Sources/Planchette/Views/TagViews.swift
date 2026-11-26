import SwiftUI

/// Small tag chips ("to test", "review", …).
struct TagChips: View {
    let tags: [String]
    /// Given, a chip shows an × while the pointer is on it, and a click on the × takes the tag
    /// off: the project panel, where a tag is done with as soon as its work is.
    var onRemove: ((String) -> Void)?

    @State private var hovered: String?

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags, id: \.self) { tag in
                    chip(tag)
                }
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        let removable = onRemove != nil && hovered == tag
        return HStack(spacing: 2) {
            Text(tag)
            if removable {
                Button {
                    hovered = nil
                    onRemove?(tag)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 9, height: 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t(.removeTagHelp, tag))
            }
        }
        .font(.system(size: 9, weight: .medium))
        // The × takes the room of the padding on its side, so the chip barely grows under it.
        .padding(.leading, 5)
        .padding(.trailing, removable ? 3 : 5)
        .padding(.vertical, 1.5)
        .background(Color.accentColor.opacity(removable ? 0.28 : 0.18), in: Capsule())
        .foregroundStyle(Color.accentColor)
        .onHover { inside in
            guard onRemove != nil else { return }
            if inside { hovered = tag } else if hovered == tag { hovered = nil }
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
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            // The same rules as the tag list in Settings: one line, lowercase, short.
            guard let tag = TagList.normalized(field.stringValue) else { return }
            appState.addTag(tag, on: session.id)
        }
    }
}

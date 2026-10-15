import AppKit
import SwiftUI

/// The "What's new" of the update dialog: every point of the release on one line,
/// each opening to its whole text (see `ReleaseNotes`). It sits in a fixed-height
/// area that scrolls, so a long release never pushes the dialog's buttons away.
struct ReleaseNotesView: View {
    static let width: CGFloat = 440
    private static let headerHeight: CGFloat = 26
    private static let longestList: CGFloat = 230

    let entries: [ReleaseNotes.Entry]
    @State private var open: Set<Int> = []

    /// The dialog's accessory view: this list at its fixed size. A hosting view has
    /// no size of its own inside an alert, and the alert needs one before it lays out.
    @MainActor
    static func accessory(for entries: [ReleaseNotes.Entry]) -> NSView {
        let view = NSHostingView(rootView: ReleaseNotesView(entries: entries))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height(for: entries))
        return view
    }

    /// Closed rows and the section labels between them, up to a limit; beyond it the
    /// list scrolls.
    private static func height(for entries: [ReleaseNotes.Entry]) -> CGFloat {
        let labels = zip(entries, [nil] + entries.map(\.section)).filter { $0.0.section != $0.1 && $0.0.section != nil }.count
        return headerHeight + min(CGFloat(entries.count) * 28 + CGFloat(labels) * 20 + 8, longestList)
    }

    private var expandable: [ReleaseNotes.Entry] { entries.filter { !$0.detail.isEmpty } }
    private var allOpen: Bool { !expandable.isEmpty && expandable.allSatisfy { open.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.t(.whatsNew)).font(.headline)
                Spacer()
                if !expandable.isEmpty {
                    Button(allOpen ? L10n.t(.collapseAll) : L10n.t(.expandAll)) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            open = allOpen ? [] : Set(expandable.map(\.id))
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .frame(height: Self.headerHeight - 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if let section = entry.section, section != (index > 0 ? entries[index - 1].section : nil) {
                            Text(section.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 0 : 6)
                        }
                        row(entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
        }
        .frame(width: Self.width, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ entry: ReleaseNotes.Entry) -> some View {
        let isOpen = open.contains(entry.id)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                guard !entry.detail.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { open.remove(entry.id) } else { open.insert(entry.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                        .opacity(entry.detail.isEmpty ? 0 : 1)
                    Text(entry.title)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Text(entry.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

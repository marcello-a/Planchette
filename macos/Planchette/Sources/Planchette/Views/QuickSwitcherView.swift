import SwiftUI

/// The search: type what you remember — a word of the name, the branch, a tag, a
/// pull request number, the note — and open the terminal. Opened with the search
/// shortcut (Shift twice, unless Settings says otherwise) or ⌘K.
///
/// What it finds and in what order is `SearchRanking`, which is pure and tested.
struct QuickSwitcherView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    /// What the search knows, taken the moment the switcher opens. Ranking against
    /// live data would re-order the list under the user's hands: any state change
    /// (the screen poll ticks every 1.5s) republished AppState, `stateSince` moved a
    /// terminal up, and the Enter or the click resolved its row against a list the
    /// user never saw — opening the wrong terminal. Closed terminals drop out
    /// (`compactMap`); one created while the switcher is open simply isn't listed.
    @State private var snapshot: [SearchEntry] = []
    @State private var hits: [SearchHit] = []

    private var results: [(hit: SearchHit, session: TerminalSession)] {
        hits.compactMap { hit in appState.sessions[hit.id].map { (hit, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.t(.switcherPlaceholder), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { open(at: highlighted) }
                .onChange(of: query) {
                    hits = SearchRanking.rank(query, in: snapshot)
                    highlighted = 0
                }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        let rows = results
                        if rows.isEmpty, !query.isEmpty {
                            Text(L10n.t(.switcherEmpty, query.trimmingCharacters(in: .whitespaces)))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.session.id) { index, row in
                            resultRow(row.session, hit: row.hit, highlighted: index == highlighted)
                                .id(row.session.id)
                                .onTapGesture { open(at: index) }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) {
                    if let id = results[safe: highlighted]?.session.id { proxy.scrollTo(id) }
                }
            }
            Divider()
            Text(L10n.t(.switcherHint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .frame(width: 480)
        .onAppear {
            fieldFocused = true
            snapshot = appState.searchEntries()
            hits = SearchRanking.rank(query, in: snapshot)
        }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0); return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func open(at index: Int) {
        guard let row = results[safe: index] else { return }
        appState.select(session: row.session)
        dismiss()
    }

    private func resultRow(_ session: TerminalSession, hit: SearchHit, highlighted: Bool) -> some View {
        let entry = snapshot.first { $0.id == session.id }
        let shortPath = session.shortPath
        // The row shows the last two folders; the ranges are into the whole path.
        let pathRanges: [Range<Int>] = {
            guard let path = entry?.path, path.hasSuffix(shortPath) else { return [] }
            return SearchRanking.shifted(hit.matches[.path] ?? [], by: shortPath.count - path.count, within: shortPath.count)
        }()
        return HStack(spacing: 8) {
            SessionStateIcon(session: session)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(Highlight.attributed(session.displayTitle, hit.matches[.title] ?? [])).bold()
                    if appState.group(of: session)?.favorite == true {
                        PixelIcon(sprite: PixelSprites.star, size: 11, tint: .yellow)
                    }
                }
                HStack(spacing: 4) {
                    Text(Highlight.attributed(shortPath, pathRanges)).font(.caption).foregroundStyle(.secondary)
                    TagChips(tags: session.tags)
                }
                // Where the match is when the row does not show it: the branch, the
                // pull request, the note, the prompt, what runs in the background.
                if let field = hit.hint, let entry {
                    HStack(spacing: 4) {
                        Image(systemName: field.symbol).font(.system(size: 9))
                        Text(Highlight.attributed(SearchRanking.text(of: field, in: entry), hit.matches[field] ?? []))
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if let summary = session.aiSummary {
                    Text(Highlight.attributed(summary, hit.matches[.summary] ?? []))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Text(appState.group(of: session)?.name ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // Last, so the age is at the right edge here too.
            if session.state.needsAttention {
                WaitingTimeText(since: session.stateSince)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(highlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
    }
}

/// A string with the found characters in the accent color and bold.
enum Highlight {
    static func attributed(_ text: String, _ ranges: [Range<Int>]) -> AttributedString {
        var result = AttributedString(text)
        for range in ranges {
            let lower = max(0, range.lowerBound), upper = min(text.count, range.upperBound)
            guard lower < upper else { continue }
            let start = result.characters.index(result.characters.startIndex, offsetBy: lower)
            let end = result.characters.index(start, offsetBy: upper - lower)
            result[start..<end].foregroundColor = .accentColor
            result[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

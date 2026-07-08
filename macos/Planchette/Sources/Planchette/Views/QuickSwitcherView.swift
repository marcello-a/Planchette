import SwiftUI

/// ⌘K quick switcher. Sessions needing attention come first (favorites on
/// top), then everything else fuzzy-matched by title / path / group.
struct QuickSwitcherView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var results: [TerminalSession] {
        let all = appState.sessions.values
        let ranked = all.sorted { a, b in
            let aScore = urgencyScore(a)
            let bScore = urgencyScore(b)
            if aScore != bScore { return aScore > bScore }
            return a.stateSince > b.stateSince
        }
        guard !query.isEmpty else { return Array(ranked.prefix(12)) }
        let q = query.lowercased()
        return ranked.filter { session in
            let haystack = ([
                session.displayTitle,
                session.currentDirectory,
                appState.group(of: session)?.name ?? "",
                Titles.gitBranch(forDirectory: session.currentDirectory) ?? "",
                session.aiSummary ?? "",
            ] + session.tags).joined(separator: " ").lowercased()
            return fuzzyMatch(needle: q, haystack: haystack)
        }
    }

    private func urgencyScore(_ session: TerminalSession) -> Int {
        let favorite = appState.group(of: session)?.favorite == true
        switch (session.state, favorite) {
        case (.asking, true): return 5
        case (.done, true): return 4
        case (.asking, false): return 3
        case (.done, false): return 2
        default: return favorite ? 1 : 0
        }
    }

    private func fuzzyMatch(needle: String, haystack: String) -> Bool {
        var index = haystack.startIndex
        for char in needle {
            guard let found = haystack[index...].firstIndex(of: char) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Titel, Pfad, Branch, Gruppe…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { open(at: highlighted) }
                .onChange(of: query) { highlighted = 0 }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, session in
                        row(session, highlighted: index == highlighted)
                            .onTapGesture { open(at: index) }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 480)
        .onAppear { fieldFocused = true }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, results.count - 1); return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0); return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func open(at index: Int) {
        guard results.indices.contains(index) else { return }
        appState.select(session: results[index])
        dismiss()
    }

    private func row(_ session: TerminalSession, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.state.symbol)
                .foregroundStyle(session.state.tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.displayTitle).bold()
                    if appState.group(of: session)?.favorite == true {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 4) {
                    Text(session.shortPath).font(.caption).foregroundStyle(.secondary)
                    TagChips(tags: session.tags)
                }
                if let summary = session.aiSummary {
                    Text(summary).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if session.state.needsAttention {
                WaitingTimeText(since: session.stateSince)
            }
            Text(appState.group(of: session)?.name ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(highlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
    }
}

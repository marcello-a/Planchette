import Foundation

/// What the find bar of one terminal knows (⌘F). Pure, so what it says next to the
/// field is tested.
struct TerminalFind: Equatable {
    var needle = ""
    /// How many matches there are. Nil until something was searched, or while the
    /// engine has not answered yet.
    var total: Int?
    /// Which match is selected, counting from 1. Nil when the engine does not say:
    /// libghostty does, tmux only says how many there are.
    var selected: Int?
    /// Bumped by every ⌘F, so a bar that is open takes the keyboard again.
    var focusRequests = 0

    var hasNoResults: Bool { !needle.isEmpty && total == 0 }

    /// What the bar says beside the field: "3 of 12", "12 matches", "No results".
    func countLabel() -> String {
        guard !needle.isEmpty, let total else { return "" }
        if total == 0 { return L10n.t(.findNoResults) }
        if let selected, selected >= 1 { return L10n.t(.findCountOf, selected, total) }
        return total == 1 ? L10n.t(.findMatchOne) : L10n.t(.findMatchMany, total)
    }
}

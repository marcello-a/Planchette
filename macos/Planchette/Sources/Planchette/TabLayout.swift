import Foundation

/// What a tab is named after (Settings → Tabs).
///
/// The default is the summary, not the branch. A branch names a checkout, and
/// three terminals in one checkout then wear the same name; the summary names the
/// *session*, so they read differently. The old name — the ticket of the branch and
/// your last prompt — is still a choice.
enum TabName: String, Codable, CaseIterable, Identifiable {
    /// What the session is about, in Claude's own words: the name Claude Code gives
    /// the conversation (`AgentTitle`), else the AI summary, else the last prompt.
    case summary
    /// The first line of the prompt you sent last.
    case lastPrompt
    /// The prompt that opened the session. It does not move when the conversation does.
    case firstPrompt
    /// `NIE-1902 · Add the switch`: the ticket of the checkout's branch and the last
    /// prompt — what every tab said before the name was a choice.
    case ticketAndPrompt

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .summary: .tabNameSummary
        case .lastPrompt: .tabNameLastPrompt
        case .firstPrompt: .tabNameFirstPrompt
        case .ticketAndPrompt: .tabNameTicket
        }
    }

    var helpKey: LKey {
        switch self {
        case .summary: .tabNameSummaryHelp
        case .lastPrompt: .tabNameLastPromptHelp
        case .firstPrompt: .tabNameFirstPromptHelp
        case .ticketAndPrompt: .tabNameTicketHelp
        }
    }
}

/// How a tab is set up: what names it, and what else it carries. The state icon and
/// the terminal's own color always stay.
///
/// Persisted with the workspace; every field decodes on its own, so a value that no
/// version can read costs that one choice and never the whole `state.json`.
struct TabLayout: Codable, Equatable {
    var name: TabName = .summary
    /// The last two folders of the terminal's working directory.
    var showsPath = true
    /// The git branch of the terminal's checkout. Off by default: the name says what
    /// the terminal is for, and the branch repeats on every tab of one checkout.
    var showsBranch = false
    var showsTags = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(TabName.self, forKey: .name)) ?? .summary
        showsPath = (try? c.decodeIfPresent(Bool.self, forKey: .showsPath)) ?? true
        showsBranch = (try? c.decodeIfPresent(Bool.self, forKey: .showsBranch)) ?? false
        showsTags = (try? c.decodeIfPresent(Bool.self, forKey: .showsTags)) ?? true
    }

    /// Whether anything on a tab is read out of a Claude transcript — the sweep that
    /// finds the conversation's name runs only for what is shown (see
    /// `AppState.refreshContextUsage`).
    var readsTranscripts: Bool { name == .summary }
}

/// The name of a tab, from what is known about its terminal. Pure, so the order in
/// which the sources give way to each other is tested rather than remembered.
enum TabNaming {
    struct Inputs {
        /// A manual rename. It always wins, and is never cut.
        var customTitle: String?
        /// The name Claude Code gave the conversation.
        var conversationTitle: String?
        var aiSummary: String?
        var firstPrompt: String?
        var lastPrompt: String?
        /// The title the running program reports, when it is a name and not a prompt.
        var reportedTitle: String?
        /// The ticket of the checkout's branch. Only asked for by `.ticketAndPrompt`.
        var ticket: String?
        /// What a terminal with nothing to say is called: "free", or its folder.
        var fallback: String
    }

    static func name(_ inputs: Inputs, source: TabName, max: Int = 48) -> String {
        if let custom = inputs.customTitle, !custom.isEmpty { return custom }
        switch source {
        case .summary:
            return first([inputs.conversationTitle, inputs.aiSummary, inputs.lastPrompt, inputs.reportedTitle],
                         max: max) ?? inputs.fallback
        case .lastPrompt:
            return first([inputs.lastPrompt, inputs.reportedTitle], max: max) ?? inputs.fallback
        case .firstPrompt:
            return first([inputs.firstPrompt, inputs.lastPrompt, inputs.reportedTitle], max: max) ?? inputs.fallback
        case .ticketAndPrompt:
            // The length it always had: this is what tabs said before the name was a choice.
            let work = inputs.lastPrompt.flatMap { Titles.taskLabel($0) } ?? inputs.reportedTitle
            return Titles.autoTitle(ticket: inputs.ticket, work: work) ?? inputs.fallback
        }
    }

    /// The first source that has something to say, condensed to fit a tab.
    private static func first(_ sources: [String?], max: Int) -> String? {
        for source in sources {
            if let source, let label = Titles.taskLabel(source, max: max) { return label }
        }
        return nil
    }
}

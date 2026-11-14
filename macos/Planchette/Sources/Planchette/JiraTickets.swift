import Foundation

/// The Jira panel at the right of the tab: saved JQL queries, each a section of ticket cards, read
/// from Jira Cloud's REST API with the user's API token (kept in the Keychain, never in
/// `state.json`). Everything here is pure and unit-tested; the poll is in `Jira.swift`, the panel in
/// `Views/JiraPanel.swift`.

/// One saved query: a name the panel shows and the JQL behind it.
struct JiraQuery: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var jql: String
    /// Folded in the panel.
    var collapsed = false

    init(id: UUID = UUID(), name: String, jql: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.jql = jql
        self.collapsed = collapsed
    }

    // A query a newer build wrote keeps what this one can read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        jql = (try? c.decodeIfPresent(String.self, forKey: .jql)) ?? ""
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
    }
}

/// The Jira site, the account, the queries, and whether the panel is open and how wide — one for
/// the whole app, like the notifications panel. Persisted as `PersistedState.jira`; the token is not
/// in here (`Keychain`).
struct JiraLook: Codable, Equatable {
    static let defaultWidth: Double = 260
    /// Narrower than this a card's title no longer reads.
    static let minimumWidth: Double = 200

    var site = ""
    var email = ""
    var queries: [JiraQuery] = []
    var open = false
    var width: Double = JiraLook.defaultWidth

    init(site: String = "", email: String = "", queries: [JiraQuery] = [],
         open: Bool = false, width: Double = JiraLook.defaultWidth) {
        self.site = site
        self.email = email
        self.queries = queries
        self.open = open
        self.width = Self.sanitized(width)
    }

    // A state written by another build, or by hand, must not cost the whole workspace.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        site = (try? c.decodeIfPresent(String.self, forKey: .site)) ?? ""
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        queries = (try? c.decodeIfPresent([JiraQuery].self, forKey: .queries)) ?? []
        open = (try? c.decodeIfPresent(Bool.self, forKey: .open)) ?? false
        width = Self.sanitized((try? c.decodeIfPresent(Double.self, forKey: .width)) ?? Self.defaultWidth)
    }

    /// Site and account are filled in; whether the token is there is the Keychain's to say.
    var hasAccount: Bool { JiraTickets.normalizedSite(site) != nil && !email.trimmingCharacters(in: .whitespaces).isEmpty }

    static func sanitized(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return max(width, minimumWidth)
    }

    /// The width the panel gets when `available` points are left beside the terminal's minimum.
    static func clamped(width: Double, in available: Double) -> Double {
        let room = available - NotepadLook.terminalMinimumWidth
        guard room >= minimumWidth else { return minimumWidth }
        return min(max(sanitized(width), minimumWidth), room)
    }

    mutating func moveQuery(_ id: UUID, by offset: Int) {
        guard let from = queries.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard queries.indices.contains(to) else { return }
        queries.swapAt(from, to)
    }
}

/// The three colours Jira gives every status, whatever its name.
enum JiraStatusCategory: String, Equatable {
    case todo, inProgress, done

    /// Jira's `statusCategory.key`: `new`, `indeterminate`, `done`. Anything else reads as to do.
    init(key: String?) {
        switch key {
        case "indeterminate": self = .inProgress
        case "done": self = .done
        default: self = .todo
        }
    }
}

/// One ticket as a card shows it.
struct JiraIssue: Equatable, Identifiable {
    let key: String
    let summary: String
    let type: String?
    let priority: String?
    let status: String
    let statusCategory: JiraStatusCategory
    let assignee: String?
    /// When the ticket entered the status it is in — what Jira's board counts "days in column" from.
    var statusSince: Date? = nil

    var id: String { key }

    /// Whole days in the current status at `now`; nil when Jira gave no date.
    func daysInStatus(at now: Date = Date()) -> Int? {
        statusSince.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }
}

/// What a query came back with: its tickets, or why there are none.
struct JiraResult: Equatable {
    var issues: [JiraIssue] = []
    /// Shown in the query's section instead of cards; nil when Jira answered.
    var error: JiraError?
    var checkedAt: Date?
}

/// Why a query has no answer. The panel says it in the user's language.
enum JiraError: Error, Equatable {
    /// 401/403: the e-mail or token is wrong, or the token was revoked.
    case unauthorized
    /// 400: Jira's own words, mostly about the JQL.
    case rejected(String)
    /// No answer at all: offline, a wrong site, a timeout.
    case unreachable
    /// An answer that is not what the API documents.
    case unreadable
}

enum JiraTickets {
    static let pollInterval: TimeInterval = 300
    static let minimumManualInterval: TimeInterval = 5
    static let maxResults = 50
    static let fields = "summary,status,issuetype,priority,assignee,created"

    /// `myposter.atlassian.net`, `https://myposter.atlassian.net/jira/your-work` → the site's root
    /// over https. Nil for something that is not a host; plain http is refused (the token would go
    /// out in the clear).
    static func normalizedSite(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, host.contains("."), !host.contains(" ") else { return nil }
        var root = URLComponents()
        root.scheme = "https"
        root.host = host.lowercased()
        root.port = parts.port
        return root.url
    }

    /// The `Authorization` header Jira Cloud takes for an API token.
    static func authorization(email: String, token: String) -> String {
        "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    /// A query's search: `GET /rest/api/3/search/jql`.
    static func searchRequest(site: URL, email: String, token: String, jql: String) -> URLRequest {
        var parts = URLComponents(url: site.appendingPathComponent("rest/api/3/search/jql"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "jql", value: jql),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            // The history holds the moment the ticket entered its status ("days in column").
            URLQueryItem(name: "expand", value: "changelog"),
        ]
        // `URLComponents` leaves `+` and `=` alone in a query value; Jira would read the `+` as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return request(parts.url!, email: email, token: token)
    }

    /// The account check behind "Check connection": `GET /rest/api/3/myself`.
    static func myselfRequest(site: URL, email: String, token: String) -> URLRequest {
        request(site.appendingPathComponent("rest/api/3/myself"), email: email, token: token)
    }

    private static func request(_ url: URL, email: String, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(authorization(email: email, token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// A ticket's page.
    static func browseURL(site: URL, key: String) -> URL {
        site.appendingPathComponent("browse").appendingPathComponent(key)
    }

    /// The tickets of a search answer, in Jira's order. Nil when the answer is not one.
    static func parse(_ data: Data) -> [JiraIssue]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let issues = root["issues"] as? [[String: Any]] else { return nil }
        return issues.compactMap { issue in
            guard let key = issue["key"] as? String else { return nil }
            let fields = issue["fields"] as? [String: Any] ?? [:]
            let status = fields["status"] as? [String: Any]
            let category = status?["statusCategory"] as? [String: Any]
            return JiraIssue(
                key: key,
                summary: (fields["summary"] as? String) ?? "",
                type: (fields["issuetype"] as? [String: Any])?["name"] as? String,
                priority: (fields["priority"] as? [String: Any])?["name"] as? String,
                status: (status?["name"] as? String) ?? "",
                statusCategory: JiraStatusCategory(key: category?["key"] as? String),
                assignee: (fields["assignee"] as? [String: Any])?["displayName"] as? String,
                statusSince: statusSince(issue: issue, fields: fields)
            )
        }
    }

    /// The last change of the status in the history; a ticket that never moved has been where it
    /// is since it was created.
    static func statusSince(issue: [String: Any], fields: [String: Any]) -> Date? {
        let histories = (issue["changelog"] as? [String: Any])?["histories"] as? [[String: Any]] ?? []
        let changes = histories.compactMap { history -> Date? in
            let items = history["items"] as? [[String: Any]] ?? []
            guard items.contains(where: { ($0["field"] as? String) == "status" }) else { return nil }
            return (history["created"] as? String).flatMap(date)
        }
        return changes.max() ?? (fields["created"] as? String).flatMap(date)
    }

    /// Jira's timestamps: `2026-11-10T09:12:33.123+0100`.
    static func date(_ text: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// What a response that is not a 200 means.
    static func error(status: Int, data: Data) -> JiraError {
        if status == 401 || status == 403 { return .unauthorized }
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var messages = root["errorMessages"] as? [String] ?? []
            if let errors = root["errors"] as? [String: String] {
                messages += errors.keys.sorted().compactMap { errors[$0] }
            }
            if !messages.isEmpty { return .rejected(messages.joined(separator: " ")) }
        }
        return status == 400 ? .rejected("HTTP 400") : .unreachable
    }
}

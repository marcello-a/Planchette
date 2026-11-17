import Foundation

/// The to-do board: the user's own list of what is to be done, laned the way a terminal's state
/// is — queued, running, waiting, done — so a card reads like a terminal at a glance. Global, not
/// per project; a card may point at a project or one terminal of it. Persisted as
/// `PersistedState.todos`. Pure, unit-tested; the page is `Views/TodoBoardView.swift`.

/// Where a card stands. The colours and sprites are the terminal states' own (`state`).
enum TodoLane: String, Codable, CaseIterable {
    case queued    // to do, nobody on it yet
    case running   // being worked on — by you or an agent
    case waiting   // stuck on someone else
    case done

    /// The terminal state whose sprite and colour the lane wears.
    var state: AttentionState {
        switch self {
        case .queued: .free
        case .running: .running
        case .waiting: .waiting
        case .done: .ready
        }
    }

    /// The moves a card offers as buttons, besides drag and drop. Queued is never a button
    /// target: a done card goes back with its undo, anything else is dragged.
    var forward: [TodoLane] {
        switch self {
        case .queued: [.running, .done]
        case .running: [.waiting, .done]
        case .waiting: [.running, .done]
        case .done: []
        }
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var lane: TodoLane = .queued
    var note: String?
    /// An http(s) link — a ticket, a page, a thread — shown as a chip.
    var link: String?
    /// The project the card is about, and optionally the one terminal of it.
    var groupID: UUID?
    var sessionID: UUID?
    var createdAt: Date
    /// When the card last entered `done`; cleared when it leaves.
    var doneAt: Date?

    init(id: UUID = UUID(), text: String, lane: TodoLane = .queued, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.lane = lane
        self.createdAt = createdAt
    }

    // A card a newer build wrote must not cost the board.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        lane = (try? c.decodeIfPresent(TodoLane.self, forKey: .lane)) ?? .queued
        note = try c.decodeIfPresent(String.self, forKey: .note)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
    }
}

/// Every card, in one list: a lane's order is the order its cards have in `items`.
struct TodoBoard: Codable, Equatable {
    var items: [TodoItem] = []

    init(items: [TodoItem] = []) {
        self.items = items
    }

    func items(in lane: TodoLane) -> [TodoItem] {
        items.filter { $0.lane == lane }
    }

    /// The text as a card's title: one line, trimmed. Nothing left means no card.
    static func cleaned(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// A new card at the end of the queue.
    @discardableResult
    mutating func add(_ text: String, groupID: UUID? = nil, now: Date = Date()) -> TodoItem? {
        guard let text = Self.cleaned(text) else { return nil }
        var item = TodoItem(text: text, createdAt: now)
        item.groupID = groupID
        items.append(item)
        return item
    }

    /// Put a card into `lane`, before `before` (a card of that lane) or at the lane's end.
    /// Entering `done` stamps the time, leaving it clears it; a move within a lane only reorders.
    mutating func move(_ id: UUID, to lane: TodoLane, before: UUID? = nil, now: Date = Date()) {
        guard before != id, let from = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: from)
        if item.lane != lane {
            item.doneAt = lane == .done ? now : nil
            item.lane = lane
        }
        if let before, let target = items.firstIndex(where: { $0.id == before && $0.lane == lane }) {
            items.insert(item, at: target)
        } else if let last = items.lastIndex(where: { $0.lane == lane }) {
            items.insert(item, at: last + 1)
        } else {
            items.append(item)
        }
    }

    mutating func update(_ id: UUID, _ change: (inout TodoItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[idx])
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func clearDone() {
        items.removeAll { $0.lane == .done }
    }

    /// Links to projects and terminals that are gone are dropped; a card whose terminal closed
    /// keeps its project.
    mutating func forget(groupsExcept groups: Set<UUID>, sessionsExcept sessions: Set<UUID>) {
        for idx in items.indices {
            if let id = items[idx].sessionID, !sessions.contains(id) { items[idx].sessionID = nil }
            if let id = items[idx].groupID, !groups.contains(id) {
                items[idx].groupID = nil
                items[idx].sessionID = nil
            }
        }
    }

    // A card that does not decode is lost alone, not with the board.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([Lossy].self, forKey: .items) ?? []
        items = raw.compactMap(\.item)
    }

    private struct Lossy: Decodable {
        let item: TodoItem?
        init(from decoder: Decoder) throws {
            item = try? TodoItem(from: decoder)
        }
    }
}

/// What a card's link chip says: the service, read off the host, or the host itself.
enum TodoLink {
    /// The text as a link, or nil when it is not an http(s) URL. A bare host gets `https://`.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, host.contains(".")
        else { return nil }
        return candidate
    }

    static func label(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return link }
        let path = url.path
        if host.hasSuffix("atlassian.net") || host.contains("jira") {
            if path.contains("/wiki") || host.contains("confluence") { return "Confluence" }
            // A ticket's key reads better than the service: PROJ-123.
            if let key = path.split(separator: "/").last(where: { $0.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil }) {
                return String(key)
            }
            return "Jira"
        }
        if host.contains("confluence") { return "Confluence" }
        if host.hasSuffix("slack.com") { return "Slack" }
        if host == "github.com" {
            // owner/repo/pull/12 → repo#12
            let parts = path.split(separator: "/")
            if parts.count >= 4, parts[2] == "pull" || parts[2] == "issues" { return "\(parts[1])#\(parts[3])" }
            return "GitHub"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What a dragged card carries: JSON, never text — a terminal types dropped text (see `TabDragItem`).
enum TodoDrag {
    static func encoded(_ id: UUID) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["planchetteTodo": id.uuidString])) ?? Data()
    }

    static func decoded(_ data: Data) -> UUID? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.count == 1, let text = object["planchetteTodo"] as? String else { return nil }
        return UUID(uuidString: text)
    }
}

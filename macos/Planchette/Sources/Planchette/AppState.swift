import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var groups: [SessionGroup] = []
    @Published var sessions: [UUID: TerminalSession] = [:]
    @Published var selectedGroupID: UUID?
    @Published var quickSwitcherShown = false
    @Published var aiEnabled = false {
        didSet { scheduleSave() }
    }

    private(set) lazy var aiAssist = AIAssist(appState: self)

    /// True while sessions from a previous run are being revived; the registry
    /// uses this to decide whether to replay startup/resume commands.
    private(set) var isRestoring = false

    private var saveTask: Task<Void, Never>?

    static let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Planchette", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        restore()
        observeSurfaceNotifications()
    }

    // MARK: Derived

    var selectedGroup: SessionGroup? {
        groups.first { $0.id == selectedGroupID }
    }

    func sessions(in group: SessionGroup) -> [TerminalSession] {
        group.sessionIDs.compactMap { sessions[$0] }
    }

    func group(of session: TerminalSession) -> SessionGroup? {
        groups.first { $0.id == session.groupID }
    }

    /// Inbox: everything needing attention. Favorites first, asking before
    /// done, longest-waiting first.
    var attentionQueue: [TerminalSession] {
        sessions.values
            .filter { $0.state.needsAttention }
            .sorted { a, b in
                let aFav = group(of: a)?.favorite ?? false
                let bFav = group(of: b)?.favorite ?? false
                if aFav != bFav { return aFav }
                if a.state != b.state { return a.state == .asking }
                return a.stateSince < b.stateSince
            }
    }

    var askingCount: Int { sessions.values.filter { $0.state == .asking }.count }
    var doneCount: Int { sessions.values.filter { $0.state == .done }.count }

    // MARK: Mutations

    @discardableResult
    func addGroup(name: String, favorite: Bool = false) -> SessionGroup {
        var group = SessionGroup(name: name)
        group.favorite = favorite
        groups.append(group)
        selectedGroupID = group.id
        scheduleSave()
        return group
    }

    @discardableResult
    func addSession(directory: String, groupID: UUID? = nil) -> TerminalSession {
        let targetGroupID: UUID
        if let groupID {
            targetGroupID = groupID
        } else if let selected = selectedGroupID {
            targetGroupID = selected
        } else {
            targetGroupID = addGroup(name: (directory as NSString).lastPathComponent).id
        }

        let session = TerminalSession(groupID: targetGroupID, workingDirectory: directory)
        sessions[session.id] = session
        if let idx = groups.firstIndex(where: { $0.id == targetGroupID }) {
            groups[idx].sessionIDs.append(session.id)
            groups[idx].activeSessionID = session.id
        }
        scheduleSave()
        return session
    }

    func closeSession(_ id: UUID) {
        guard let session = sessions[id] else { return }
        TerminalRegistry.shared.close(id)
        sessions[id] = nil
        if let idx = groups.firstIndex(where: { $0.id == session.groupID }) {
            groups[idx].sessionIDs.removeAll { $0 == id }
            if groups[idx].activeSessionID == id {
                groups[idx].activeSessionID = groups[idx].sessionIDs.last
            }
            if groups[idx].sessionIDs.isEmpty {
                let groupID = groups[idx].id
                groups.remove(at: idx)
                if selectedGroupID == groupID { selectedGroupID = groups.first?.id }
            }
        }
        scheduleSave()
    }

    func update(_ id: UUID, _ mutate: (inout TerminalSession) -> Void) {
        guard var session = sessions[id] else { return }
        mutate(&session)
        sessions[id] = session
        scheduleSave()
    }

    func updateGroup(_ id: UUID, _ mutate: (inout SessionGroup) -> Void) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[idx])
        scheduleSave()
    }

    func select(session: TerminalSession) {
        selectedGroupID = session.groupID
        updateGroup(session.groupID) { $0.activeSessionID = session.id }
    }

    /// Jump to the most urgent waiting session (⌘⇧K).
    func jumpToNextWaiting() {
        guard let next = attentionQueue.first else { return }
        select(session: next)
    }

    /// The user focused this terminal: asking → they're answering, done → seen.
    func sessionWasAttended(_ id: UUID) {
        guard let session = sessions[id], session.state.needsAttention else { return }
        setState(id, session.state == .asking ? .working : .free)
    }

    private func setState(_ id: UUID, _ state: AttentionState, message: String? = nil) {
        update(id) {
            guard $0.state != state else { return }
            $0.state = state
            $0.stateSince = Date()
            $0.lastMessage = message
        }
    }

    // MARK: Hook events (from HookServer)

    func applyHookEvent(
        sessionID: UUID,
        hookEvent: String,
        claudeSessionID: String?,
        transcriptPath: String?,
        message: String?
    ) {
        NSLog("hook-event: \(hookEvent) session=\(sessionID) claude=\(claudeSessionID ?? "-") message=\(message ?? "-")")
        guard sessions[sessionID] != nil else { return }
        if claudeSessionID != nil || transcriptPath != nil {
            update(sessionID) {
                if let claudeSessionID { $0.claudeSessionID = claudeSessionID }
                if let transcriptPath { $0.transcriptPath = transcriptPath }
            }
        }
        switch hookEvent {
        case "UserPromptSubmit":
            setState(sessionID, .working)
        case "Notification", "PermissionRequest":
            setState(sessionID, .asking, message: message)
            postUserNotification(sessionID: sessionID, message: message)
            aiAssist.sessionUpdated(sessionID)
        case "Stop", "SubagentStop":
            setState(sessionID, .done)
            aiAssist.sessionUpdated(sessionID)
        case "SessionEnd":
            setState(sessionID, .free)
        case "SessionStart":
            break // claudeSessionID captured above
        default:
            break
        }
    }

    // MARK: Tags

    /// All tags in use plus the default suggestions.
    var knownTags: [String] {
        var tags = TerminalSession.suggestedTags
        for session in sessions.values {
            for tag in session.tags where !tags.contains(tag) { tags.append(tag) }
        }
        return tags
    }

    func toggleTag(_ tag: String, on sessionID: UUID) {
        update(sessionID) {
            if let idx = $0.tags.firstIndex(of: tag) {
                $0.tags.remove(at: idx)
            } else {
                $0.tags.append(tag)
            }
        }
    }

    // MARK: AI ordering

    /// Preview of the AI grouping proposal: topic → sessions that would move.
    var topicProposal: [(topic: String, sessions: [TerminalSession])] {
        var byTopic: [String: [TerminalSession]] = [:]
        for session in sessions.values {
            guard let topic = session.aiTopic, !topic.isEmpty else { continue }
            byTopic[topic, default: []].append(session)
        }
        return byTopic
            .filter { $0.value.count >= 2 }
            .map { (topic: $0.key, sessions: $0.value) }
            .sorted { $0.topic < $1.topic }
    }

    /// Apply the proposal: sessions sharing a topic move into a group named
    /// after it. Only ever called after explicit user confirmation.
    func applyTopicGrouping() {
        for (topic, topicSessions) in topicProposal {
            let target: SessionGroup
            if let existing = groups.first(where: { $0.name.lowercased() == topic }) {
                target = existing
            } else {
                target = addGroup(name: topic)
            }
            for session in topicSessions where session.groupID != target.id {
                moveSession(session.id, to: target.id)
            }
        }
        scheduleSave()
    }

    func moveSession(_ id: UUID, to groupID: UUID) {
        guard let session = sessions[id], session.groupID != groupID else { return }
        if let idx = groups.firstIndex(where: { $0.id == session.groupID }) {
            groups[idx].sessionIDs.removeAll { $0 == id }
            if groups[idx].activeSessionID == id {
                groups[idx].activeSessionID = groups[idx].sessionIDs.last
            }
            if groups[idx].sessionIDs.isEmpty { groups.remove(at: idx) }
        }
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].sessionIDs.append(id)
        }
        update(id) { $0.groupID = groupID }
    }

    /// Manual "summarize everything now" from the AI menu.
    func summarizeAllNow() {
        for id in sessions.keys { aiAssist.sessionUpdated(id, force: true) }
    }

    private func postUserNotification(sessionID: UUID, message: String?) {
        guard let session = sessions[sessionID] else { return }
        // Only interrupt for favorites; side projects just queue in the inbox.
        guard group(of: session)?.favorite == true else { return }
        let notification = NSUserNotification()
        notification.title = "\(session.displayTitle) fragt"
        notification.informativeText = message ?? ""
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: Surface notifications (title / pwd / child exit)

    private func observeSurfaceNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: .planchetteSurfaceTitle, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID,
                  let title = note.userInfo?["title"] as? String else { return }
            Task { @MainActor in self?.update(id) { $0.oscTitle = title } }
        }
        center.addObserver(forName: .planchetteSurfacePwd, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID,
                  let pwd = note.userInfo?["pwd"] as? String else { return }
            Task { @MainActor in self?.update(id) { $0.currentDirectory = pwd } }
        }
        center.addObserver(forName: .planchetteSurfaceChildExited, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID else { return }
            Task { @MainActor in self?.closeSession(id) }
        }
    }

    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let state = PersistedState(
            groups: groups,
            sessions: Array(sessions.values),
            selectedGroupID: selectedGroupID,
            aiEnabled: aiEnabled
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: Self.stateURL, options: .atomic)
        } catch {
            NSLog("save failed: \(error)")
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        isRestoring = true
        groups = state.groups
        sessions = Dictionary(uniqueKeysWithValues: state.sessions.map { ($0.id, $0) })
        selectedGroupID = state.selectedGroupID ?? groups.first?.id
        aiEnabled = state.aiEnabled
        // Terminals from the previous run are no longer live; their agents are
        // resumed lazily when the surface is (re)created by the registry.
        // After a short grace period, new surfaces are ordinary terminals again.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            self.isRestoring = false
        }
    }
}

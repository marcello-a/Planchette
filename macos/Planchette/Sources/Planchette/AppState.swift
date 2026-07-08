import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var groups: [SessionGroup] = []
    @Published var sessions: [UUID: TerminalSession] = [:]
    @Published var windows: [WindowModel] = []
    /// Window the quick switcher is currently shown in (nil = hidden).
    @Published var quickSwitcherWindowID: UUID?
    @Published var aiEnabled = false {
        didSet { scheduleSave() }
    }
    @Published var language: AppLanguage = .system {
        didSet {
            L10n.current = language
            scheduleSave()
        }
    }
    @Published var appearance: AppAppearance = .system {
        didSet {
            appearance.apply()
            scheduleSave()
        }
    }
    @Published var autoUpdateCheck = true {
        didSet { scheduleSave() }
    }
    /// Windows (beyond the main one) that still need to be opened after a
    /// restore; the main window's ContentView consumes this.
    @Published var windowsToOpen: [UUID] = []

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
        // Load the persisted language before any SwiftUI scene (incl. menus)
        // is built, so the whole UI launches in the right language.
        if let saved = Self.loadPersistedState() {
            language = saved.language
            L10n.current = saved.language
            appearance = saved.appearance
            autoUpdateCheck = saved.autoUpdateCheck
        }
        observeSurfaceNotifications()
    }

    // MARK: Windows

    /// Stable id of the main window (SwiftUI's default window value).
    static let mainWindowID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!

    func window(for id: UUID) -> WindowModel? {
        windows.first { $0.id == id }
    }

    func updateWindow(_ id: UUID, _ mutate: (inout WindowModel) -> Void) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        mutate(&windows[idx])
        scheduleSave()
    }

    func groups(inWindow window: WindowModel) -> [SessionGroup] {
        window.groupIDs.compactMap { id in groups.first { $0.id == id } }
    }

    func windowContaining(groupID: UUID) -> WindowModel? {
        windows.first { $0.groupIDs.contains(groupID) }
    }

    /// Ensure there is a main window (stable id) and every group lives in
    /// exactly one window.
    func sanitizeWindows() {
        if !windows.contains(where: { $0.id == Self.mainWindowID }) {
            if windows.isEmpty {
                windows.append(WindowModel(id: Self.mainWindowID))
            } else {
                // Promote the first window to be the main one.
                var main = WindowModel(id: Self.mainWindowID)
                main.groupIDs = windows[0].groupIDs
                main.selectedGroupID = windows[0].selectedGroupID
                windows[0] = main
            }
        }
        // Main window always first.
        windows.sort { a, _ in a.id == Self.mainWindowID }
        var seen = Set<UUID>()
        for idx in windows.indices {
            windows[idx].groupIDs.removeAll { id in
                !groups.contains { $0.id == id } || !seen.insert(id).inserted
            }
        }
        let orphans = groups.map(\.id).filter { !seen.contains($0) }
        windows[0].groupIDs.append(contentsOf: orphans)
        // Drop empty secondary windows.
        windows.removeAll { $0.id != windows[0].id && $0.groupIDs.isEmpty }
        for idx in windows.indices where windows[idx].selectedGroupID == nil
            || !windows[idx].groupIDs.contains(windows[idx].selectedGroupID!) {
            windows[idx].selectedGroupID = windows[idx].groupIDs.first
        }
    }

    /// Move a group into a brand-new window; returns the window id to open.
    func moveGroupToNewWindow(_ groupID: UUID) -> UUID {
        var newWindow = WindowModel()
        newWindow.groupIDs = [groupID]
        newWindow.selectedGroupID = groupID
        for idx in windows.indices {
            windows[idx].groupIDs.removeAll { $0 == groupID }
            if windows[idx].selectedGroupID == groupID {
                windows[idx].selectedGroupID = windows[idx].groupIDs.first
            }
        }
        windows.append(newWindow)
        scheduleSave()
        return newWindow.id
    }

    /// Create a new, empty window; returns its id to open.
    func newWindow() -> UUID {
        let window = WindowModel()
        windows.append(window)
        scheduleSave()
        return window.id
    }

    /// Merge all groups of `sourceID` into `targetID` (default: main window).
    /// The source window model disappears; the caller closes the NSWindow.
    func mergeWindow(_ sourceID: UUID, into targetID: UUID? = nil) {
        guard let source = windows.first(where: { $0.id == sourceID }) else { return }
        let target = targetID ?? windows.first(where: { $0.id != sourceID })?.id
        guard let target, let targetIdx = windows.firstIndex(where: { $0.id == target }) else { return }
        windows[targetIdx].groupIDs.append(contentsOf: source.groupIDs)
        if windows[targetIdx].selectedGroupID == nil {
            windows[targetIdx].selectedGroupID = source.selectedGroupID
        }
        windows.removeAll { $0.id == sourceID }
        scheduleSave()
    }

    // MARK: Derived

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
    func addGroup(name: String, favorite: Bool = false, inWindow windowID: UUID? = nil) -> SessionGroup {
        var group = SessionGroup(name: name)
        group.favorite = favorite
        groups.append(group)
        sanitizeWindows()
        let target = windowID ?? windows[0].id
        if let idx = windows.firstIndex(where: { $0.id == target }) {
            // sanitizeWindows put the orphan into windows[0]; move if needed.
            for i in windows.indices { windows[i].groupIDs.removeAll { $0 == group.id } }
            windows[idx].groupIDs.append(group.id)
            windows[idx].selectedGroupID = group.id
        }
        scheduleSave()
        return group
    }

    @discardableResult
    func addSession(directory: String, groupID: UUID) -> TerminalSession {
        let session = TerminalSession(groupID: groupID, workingDirectory: directory)
        sessions[session.id] = session
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
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
                groups.remove(at: idx)
                sanitizeWindows()
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
        if let window = windowContaining(groupID: session.groupID) {
            updateWindow(window.id) { $0.selectedGroupID = session.groupID }
            WindowRegistry.shared.raise(window.id)
        }
        updateGroup(session.groupID) { $0.activeSessionID = session.id }
    }

    /// Jump to the most urgent waiting session (⌘⇧K).
    func jumpToNextWaiting() {
        guard let next = attentionQueue.first else { return }
        select(session: next)
    }

    func showQuickSwitcher() {
        quickSwitcherWindowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id
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

    private func postUserNotification(sessionID: UUID, message: String?) {
        guard let session = sessions[sessionID] else { return }
        // Only interrupt for favorites; side projects just queue in the inbox.
        guard group(of: session)?.favorite == true else { return }
        let notification = NSUserNotification()
        notification.title = "\(session.displayTitle) fragt"
        notification.informativeText = message ?? ""
        NSUserNotificationCenter.default.deliver(notification)
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
            if groups[idx].sessionIDs.isEmpty {
                groups.remove(at: idx)
                sanitizeWindows()
            }
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

    // MARK: Migration / import

    /// Open a terminal for each directory (used by import & drag-and-drop).
    /// Reuses a group whose sessions already live in the same folder.
    @discardableResult
    func openTerminals(inDirectories dirs: [String], windowID: UUID?) -> Int {
        let target = windowID ?? WindowRegistry.shared.keyWindowID() ?? windows.first?.id
        guard let target else { return 0 }
        var opened = 0
        var lastSession: TerminalSession?
        for dir in dirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let existing = window(for: target).map { groups(inWindow: $0) }?.first { group in
                sessions(in: group).contains { $0.workingDirectory == dir }
            }
            let group = existing ?? addGroup(name: (dir as NSString).lastPathComponent, inWindow: target)
            lastSession = addSession(directory: dir, groupID: group.id)
            opened += 1
        }
        if let lastSession { select(session: lastSession) }
        return opened
    }

    /// Import all tabs/sessions from another terminal app.
    func importFrom(_ source: MigrationService.Source, windowID: UUID?) {
        switch MigrationService.importDirectories(from: source) {
        case .success(let dirs):
            let count = openTerminals(inDirectories: dirs, windowID: windowID)
            if count == 0 { showImportAlert(source, .nothingFound) }
        case .failure(let error):
            showImportAlert(source, error)
        }
    }

    private func showImportAlert(_ source: MigrationService.Source, _ error: MigrationService.MigrationError) {
        let alert = NSAlert()
        switch error {
        case .notRunning:
            alert.messageText = "\(source.displayName) \(L10n.t(.importNotRunning))"
        case .notAuthorized:
            alert.messageText = L10n.t(.importNotAuthorized)
            alert.informativeText = L10n.t(.importAuthHint)
        case .nothingFound:
            alert.messageText = "\(source.displayName): \(L10n.t(.importNothing))"
        case .failed(let detail):
            alert.messageText = L10n.t(.importFailed)
            alert.informativeText = detail
        }
        alert.runModal()
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
        // Never overwrite a real saved state with an empty one before the
        // restore decision was made.
        guard !groups.isEmpty || !windows.isEmpty else { return }
        let state = PersistedState(
            groups: groups,
            sessions: Array(sessions.values),
            windows: windows,
            aiEnabled: aiEnabled,
            language: language,
            appearance: appearance,
            autoUpdateCheck: autoUpdateCheck
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: Self.stateURL, options: .atomic)
        } catch {
            NSLog("save failed: \(error)")
        }
    }

    /// Read the saved state without applying it (for the restore dialog).
    static func loadPersistedState() -> PersistedState? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return nil }
        return state
    }

    /// Apply a saved state ("Wiederherstellen").
    func applyRestore(_ state: PersistedState) {
        isRestoring = true
        groups = state.groups
        sessions = Dictionary(uniqueKeysWithValues: state.sessions.map { ($0.id, $0) })
        windows = state.windows
        // Legacy states (pre-multi-window) had a flat selectedGroupID.
        sanitizeWindows()
        if windows[0].selectedGroupID == nil {
            windows[0].selectedGroupID = state.selectedGroupID ?? windows[0].groupIDs.first
        }
        aiEnabled = state.aiEnabled
        language = state.language
        appearance = state.appearance
        autoUpdateCheck = state.autoUpdateCheck
        windowsToOpen = windows.dropFirst().map(\.id)
        // After a grace period, new surfaces are ordinary terminals again.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            self.isRestoring = false
        }
    }

    /// Start fresh ("Neu") — the previous state is archived, not deleted.
    func startFresh(archiving previous: PersistedState?) {
        if previous != nil {
            let archive = Self.stateURL.deletingLastPathComponent()
                .appendingPathComponent("state-previous.json")
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.copyItem(at: Self.stateURL, to: archive)
        }
        try? FileManager.default.removeItem(at: Self.stateURL)
        groups = []
        sessions = [:]
        windows = [WindowModel(id: Self.mainWindowID)]
        aiEnabled = previous?.aiEnabled ?? aiEnabled
        // Keep the user's chosen language and appearance across a fresh start.
        language = previous?.language ?? language
        appearance = previous?.appearance ?? appearance
        autoUpdateCheck = previous?.autoUpdateCheck ?? autoUpdateCheck
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
}

/// Maps window models to their NSWindows (for raising and key-window lookup).
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var map: [UUID: WeakWindow] = [:]

    private struct WeakWindow { weak var window: NSWindow? }

    func register(_ windowID: UUID, window: NSWindow) {
        map[windowID] = WeakWindow(window: window)
    }

    func raise(_ windowID: UUID) {
        map[windowID]?.window?.makeKeyAndOrderFront(nil)
    }

    func keyWindowID() -> UUID? {
        map.first { $0.value.window?.isKeyWindow == true }?.key
    }

    func close(_ windowID: UUID) {
        map[windowID]?.window?.close()
        map[windowID] = nil
    }
}

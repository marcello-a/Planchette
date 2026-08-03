import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var groups: [SessionGroup] = []
    @Published var sessions: [UUID: TerminalSession] = [:]
    @Published var windows: [WindowModel] = []
    /// Window the quick switcher is currently shown in (nil = hidden).
    @Published var quickSwitcherWindowID: UUID?
    /// Session currently being dragged in a cluster (nil = none). Lets a drop
    /// target decide, during hover, whether a drop would actually rearrange
    /// anything — so it can refuse a no-op instead of showing a phantom highlight.
    @Published var draggingClusterSessionID: UUID?
    @Published var aiEnabled = true {
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
    /// New terminals run inside tmux, so their agents outlive the app (see
    /// Durable.swift). Only takes effect for terminals created from now on —
    /// existing ones keep whatever they were created as.
    @Published var durableTerminals = true {
        didSet { scheduleSave() }
    }
    /// Windows (beyond the main one) that still need to be opened after a
    /// restore; the main window's ContentView consumes this.
    @Published var windowsToOpen: [UUID] = []

    private(set) lazy var aiAssist = AIAssist(appState: self)

    /// True while sessions from a previous run are being revived; the registry
    /// uses this to decide whether to replay startup/resume commands.
    private(set) var isRestoring = false

    /// Claude conversation each restored terminal resumes — resolved as one
    /// batch in `applyRestore` so no two terminals claim the same conversation.
    /// Only meaningful while `isRestoring` is true.
    private(set) var restoreResumeIDs: [UUID: String] = [:]

    /// Durable terminals whose agent is still alive in tmux, so restore must
    /// re-attach instead of replaying anything into them. Resolved once per
    /// restore, off-main; only meaningful while `isRestoring` is true.
    private(set) var restoreLiveDurableIDs: Set<UUID> = []

    private var saveTask: Task<Void, Never>?

    static let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Planchette", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    /// Where per-session scrollback dumps live (one <sessionID>.txt each).
    static let scrollbackDir: URL =
        stateURL.deletingLastPathComponent().appendingPathComponent("scrollback", isDirectory: true)

    static func scrollbackURL(for id: UUID) -> URL {
        scrollbackDir.appendingPathComponent("\(id.uuidString).txt")
    }

    /// Unsent prompt input captured for restore (best-effort).
    static func pendingInputURL(for id: UUID) -> URL {
        scrollbackDir.appendingPathComponent("\(id.uuidString).input")
    }

    /// Capture every live terminal's scrollback to disk (called at durability
    /// moments: quit, resign-active, hide).
    func saveScrollbacks() {
        TerminalRegistry.shared.saveScrollback(to: Self.scrollbackDir)
    }

    init() {
        // Load the persisted language before any SwiftUI scene (incl. menus)
        // is built, so the whole UI launches in the right language.
        if let saved = Self.loadPersistedState() {
            language = saved.language
            L10n.current = saved.language
            appearance = saved.appearance
            autoUpdateCheck = saved.autoUpdateCheck
            durableTerminals = saved.durableTerminals
        }
        observeSurfaceNotifications()
        startAttentionHousekeeping()
        startScreenDetection()
    }

    // MARK: Attention housekeeping (dock badge + gentle escalation)

    /// Sessions already reminded about — one reminder per waiting spell.
    private var escalatedIDs: Set<UUID> = []
    /// How long waiting/error may sit unanswered before the one reminder.
    static let escalationThreshold: TimeInterval = 10 * 60
    private var housekeepingTimer: Timer?

    private func startAttentionHousekeeping() {
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.attentionHousekeeping() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    /// The dock badge mirrors the menu-bar counters: sessions that need you.
    func refreshDockBadge() {
        let count = sessions.values.filter { $0.state.needsAttention }.count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    /// Waiting/error longer than the threshold escalates exactly once per
    /// spell: favorites get a reminder notification, everything else only
    /// counts on in the badges. State changes reset the spell (see setState).
    private func attentionHousekeeping() {
        refreshDockBadge()
        for session in sessions.values
        where session.state.needsAttention
            && Date().timeIntervalSince(session.stateSince) >= Self.escalationThreshold
            && !escalatedIDs.contains(session.id) {
            escalatedIDs.insert(session.id)
            guard group(of: session)?.favorite == true else { continue }
            let minutes = Int(Date().timeIntervalSince(session.stateSince) / 60)
            NotificationService.post(
                title: "\(session.displayTitle) — \(L10n.t(.waitingSince, minutes))",
                body: session.lastMessage ?? session.state.label,
                sessionID: session.id
            )
        }
    }

    // MARK: Screen detection (fallback signal)

    /// Rules for reading agent state off the terminal. Reloaded whenever the
    /// override file changes (see ScreenDetector.overrideURL), so fixing a
    /// pattern — by hand or by a fetched update — never needs a restart.
    private lazy var screenRules: ScreenRuleSet = ScreenDetector.loadRuleSet()
    private var screenRulesStamp: Date? = ScreenDetector.overrideModified()
    private var screenTimer: Timer?
    /// How often a terminal's viewport is read. Slow enough to be free, fast
    /// enough that a permission prompt lights up while you're still looking.
    static let screenPollInterval: TimeInterval = 1.5

    private func startScreenDetection() {
        let timer = Timer(timeInterval: Self.screenPollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollScreens() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        screenTimer = timer
    }

    /// Read every live terminal's viewport and let the screen fill the gaps the
    /// hooks leave. Hooks stay the authority wherever they are live — see
    /// `AttentionState.fromScreen`.
    private func pollScreens() {
        reloadScreenRulesIfChanged()
        for (id, session) in sessions {
            let rules = screenRules.rules(for: session.agentKind)
            // Nothing to match against (e.g. a plain shell, or an agent whose
            // patterns aren't verified yet) → don't even read the surface.
            guard !rules.isEmpty else { continue }
            guard let view = TerminalRegistry.shared.existingView(id),
                  let text = view.readViewport()
            else { continue }
            let detection = ScreenDetector.detect(
                lines: text.components(separatedBy: "\n"), rules: rules)
            guard let newState = AttentionState.fromScreen(
                detection,
                agent: session.agentKind,
                hookAuthority: hasHookAuthority(id),
                current: session.state)
            else { continue }
            // No message: the screen knows a prompt is up, not what it asks.
            // Carrying the previous one over would show a stale question.
            setState(id, newState)
        }
    }

    /// Pick up an edited or freshly downloaded ruleset. One stat per tick; the
    /// file is only parsed when its mtime moved.
    private func reloadScreenRulesIfChanged() {
        let stamp = ScreenDetector.overrideModified()
        guard stamp != screenRulesStamp else { return }
        screenRulesStamp = stamp
        // No file (deleted) → back to the compiled floor.
        guard let stamp else {
            screenRules = ScreenDetector.builtIn
            NSLog("screen rules: override removed, using built-in rules")
            return
        }
        guard let data = try? Data(contentsOf: ScreenDetector.overrideURL),
              let set = ScreenDetector.validated(data)
        else { return }   // validated() logged why; keep the rules we have
        screenRules = set
        NSLog("screen rules: reloaded version \(set.version) (mtime \(stamp))")
    }

    /// Install a fetched ruleset: written to the override path, which the poll
    /// picks up on its next tick. Returns false when it is not an improvement.
    @discardableResult
    func applyFetchedScreenRules(_ data: Data) -> Bool {
        guard let candidate = ScreenDetector.validated(data),
              ScreenDetector.isNewer(candidate, than: screenRules)
        else { return false }
        do {
            try data.write(to: ScreenDetector.overrideURL, options: .atomic)
            return true
        } catch {
            NSLog("screen rules: could not write \(ScreenDetector.overrideURL.path): \(error)")
            return false
        }
    }

    /// True when this terminal's state is owned by hooks: the agent reports its
    /// whole lifecycle *and* is currently live here.
    func hasHookAuthority(_ id: UUID) -> Bool {
        guard let session = sessions[id] else { return false }
        return session.agentKind.reportsFullLifecycle && liveAgentIDs.contains(id)
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

    /// Inbox: everything needing attention. Favorites first, errors before
    /// waiting, longest-waiting first.
    var attentionQueue: [TerminalSession] {
        sessions.values
            .filter { $0.state.needsAttention }
            .sorted { a, b in
                let aFav = group(of: a)?.favorite ?? false
                let bFav = group(of: b)?.favorite ?? false
                if aFav != bFav { return aFav }
                if a.state != b.state { return a.state == .error }
                return a.stateSince < b.stateSince
            }
    }

    var waitingCount: Int { sessions.values.filter { $0.state == .waiting }.count }
    var errorCount: Int { sessions.values.filter { $0.state == .error }.count }

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
        var session = TerminalSession(groupID: groupID, workingDirectory: directory)
        // Decided once, here: the multiplexer has to own the process tree from
        // the very first process. Without tmux installed the terminal is simply
        // an ordinary one — the feature degrades, it never fails.
        session.durable = durableTerminals && Durable.isAvailable
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
        // Closing a terminal on purpose ends its agent — durability is about
        // surviving *our* restarts, not about outliving the terminal itself.
        // Detaching the client is not enough: tmux would keep the session alive
        // forever with nothing to reattach it to.
        if session.durable {
            Task.detached { Durable.killSession(for: id) }
        }
        try? FileManager.default.removeItem(at: Self.scrollbackURL(for: id))
        try? FileManager.default.removeItem(at: Self.pendingInputURL(for: id))
        sessions[id] = nil
        liveAgentIDs.remove(id)
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
        refreshDockBadge()
        scheduleSave()
    }

    // MARK: Worktrees

    /// Create a git worktree for `branch` and open it as its own project.
    /// Running several agents on one repo means running them on several
    /// branches; without this, each checkout is an unrelated-looking folder.
    ///
    /// Git runs off-main (rule 5) and the group is only created once the
    /// checkout exists, so a failure leaves no half-project behind.
    func newWorktreeProject(fromDirectory directory: String, branch: String, base: String?) {
        Task { [weak self] in
            let result: Result<(path: String, repoRoot: String), Error> = await Task.detached {
                guard let repoRoot = Worktrees.repoRoot(of: directory) else {
                    return .failure(Worktrees.GitError(message: "\(directory) is not a git repository"))
                }
                do {
                    let path = try Worktrees.create(repoRoot: repoRoot, branch: branch, base: base)
                    return .success((path, repoRoot))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            switch result {
            case .success(let created):
                let repoName = URL(fileURLWithPath: created.repoRoot).lastPathComponent
                let group = self.addGroup(
                    name: Worktrees.groupName(repoName: repoName, branch: branch))
                self.updateGroup(group.id) {
                    $0.worktreePath = created.path
                    $0.worktreeRepoRoot = created.repoRoot
                }
                self.addSession(directory: created.path, groupID: group.id)
                if let stored = self.groups.first(where: { $0.id == group.id }) {
                    self.select(group: stored)
                }
            case .failure(let error):
                self.presentWorktreeFailure(error)
            }
        }
    }

    private func presentWorktreeFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.worktreeFailed)
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.t(.ok))
        alert.runModal()
    }

    /// Offer to delete the checkout of a closed worktree project. Git itself
    /// refuses while there are uncommitted changes — that refusal is the guard,
    /// so it is reported rather than forced away.
    private func offerWorktreeRemoval(path: String, repoRoot: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.removeWorktreeTitle)
        alert.informativeText = L10n.t(.removeWorktreeBody, path)
        alert.addButton(withTitle: L10n.t(.removeWorktree))
        alert.addButton(withTitle: L10n.t(.keepWorktree))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            let error: Error? = await Task.detached {
                do {
                    try Worktrees.remove(path: path, repoRoot: repoRoot)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error { self?.presentWorktreeFailure(error) }
        }
    }

    /// Close a whole project: free its terminals' surfaces, drop its sessions,
    /// remove the group, and repair window group lists and selection.
    func closeGroup(_ groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        for sid in group.sessionIDs {
            TerminalRegistry.shared.close(sid)
            // Closing a project ends its agents, exactly as closing a single
            // terminal does. Without this a durable session would keep running
            // with nothing attached to it until some later launch reaped it.
            if sessions[sid]?.durable == true {
                Task.detached { Durable.killSession(for: sid) }
            }
            try? FileManager.default.removeItem(at: Self.scrollbackURL(for: sid))
            try? FileManager.default.removeItem(at: Self.pendingInputURL(for: sid))
            sessions[sid] = nil
            liveAgentIDs.remove(sid)
        }
        groups.removeAll { $0.id == groupID }
        sanitizeWindows()
        scheduleSave()
        // The checkout outlives the project unless the user says otherwise.
        if let path = group.worktreePath, let root = group.worktreeRepoRoot {
            offerWorktreeRemoval(path: path, repoRoot: root)
        }
    }

    /// Reorder terminals within a group: place `dragged` right before `target`.
    func reorderSession(_ dragged: UUID, before target: UUID, groupID: UUID) {
        guard dragged != target, let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var ids = groups[gi].sessionIDs
        guard ids.contains(dragged), ids.contains(target) else { return }
        ids.removeAll { $0 == dragged }
        guard let ti = ids.firstIndex(of: target) else { return }
        ids.insert(dragged, at: ti)
        groups[gi].sessionIDs = ids
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

    // MARK: Cluster split layout

    /// The split arrangement for a group's cluster view, synced to its current
    /// sessions (defaults to a single row).
    func clusterLayout(for group: SessionGroup) -> SplitLayout {
        let base = group.clusterLayout ?? .row(group.sessionIDs.map { SplitLayout.leaf($0) })
        return base.synced(to: group.sessionIDs)
    }

    /// The layout that would result from dropping `dragged` on `target`'s edge,
    /// or nil if the move is invalid or wouldn't change anything (e.g. dropping
    /// a pane back where it already is).
    func clusterMoveResult(dragged: UUID, target: UUID, edge: LayoutEdge, groupID: UUID) -> SplitLayout? {
        guard dragged != target, let group = groups.first(where: { $0.id == groupID }) else { return nil }
        let current = clusterLayout(for: group).normalized()
        let removed = current.removingLeaf(dragged) ?? .leaf(target)
        let result = removed.splitting(target, with: dragged, edge: edge).normalized()
        return result == current ? nil : result
    }

    /// Drag-and-drop: place `dragged` on the given edge of `target`. No-op if the
    /// move wouldn't change the arrangement.
    func moveInCluster(_ dragged: UUID, target: UUID, edge: LayoutEdge, groupID: UUID) {
        guard let result = clusterMoveResult(dragged: dragged, target: target, edge: edge, groupID: groupID)
        else { return }
        updateGroup(groupID) { $0.clusterLayout = result }
    }

    /// Whether this terminal is the one on screen: the active tab of the
    /// selected project, in a window that is actually visible.
    func isVisible(_ id: UUID) -> Bool {
        guard let session = sessions[id],
              let group = groups.first(where: { $0.id == session.groupID }),
              group.activeSessionID == id,
              let window = windowContaining(groupID: session.groupID),
              window.selectedGroupID == session.groupID
        else { return false }
        return NSApp?.isActive ?? false
    }

    /// Terminals that finished something nobody has looked at yet.
    var unseenReadyCount: Int {
        sessions.values.filter { $0.state == .ready && !$0.seen }.count
    }

    /// Looking at a terminal marks its finished work as seen. Deliberately only
    /// `ready`: `waiting` and `error` persist until the agent moves on or you
    /// mark them free — a glance isn't an answer.
    func markSeen(_ id: UUID) {
        guard sessions[id]?.seen == false else { return }
        update(id) { $0.seen = true }
    }

    func select(session: TerminalSession) {
        markSeen(session.id)
        if let window = windowContaining(groupID: session.groupID) {
            updateWindow(window.id) { $0.selectedGroupID = session.groupID }
            WindowRegistry.shared.raise(window.id)
        }
        updateGroup(session.groupID) { $0.activeSessionID = session.id }
    }

    /// Jump to a project: its window, its group, its active (or first) tab.
    func select(group: SessionGroup) {
        if let id = group.activeSessionID ?? group.sessionIDs.first,
           let session = sessions[id] {
            select(session: session)
        } else if let window = windowContaining(groupID: group.id) {
            updateWindow(window.id) { $0.selectedGroupID = group.id }
            WindowRegistry.shared.raise(window.id)
        }
    }

    /// Clicked desktop notification (our own banner, or PlanchetteFocus via the
    /// hook socket): bring the app forward and jump to the terminal — its
    /// window, its project, its tab.
    func focusSession(_ id: UUID) {
        guard let session = sessions[id] else {
            // The click launched the app and arrived before the workspace was
            // restored — jump as soon as the terminals exist.
            pendingFocusID = id
            return
        }
        pendingFocusID = nil
        NSApp.activate(ignoringOtherApps: true)
        select(session: session)
    }

    /// A notification click that had no session to jump to yet (see focusSession).
    private var pendingFocusID: UUID?

    /// Apply a click that arrived before restore finished. Called once the
    /// workspace is up.
    func flushPendingFocus() {
        guard let id = pendingFocusID else { return }
        pendingFocusID = nil
        focusSession(id)
    }

    /// Jump to the most urgent waiting session (⌘⇧K).
    func jumpToNextWaiting() {
        guard let next = attentionQueue.first else { return }
        select(session: next)
    }

    func showQuickSwitcher() {
        quickSwitcherWindowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id
    }

    /// Focusing a terminal does NOT clear its attention state — a glance isn't
    /// an answer. `waiting`/`error` persist until the agent moves on (a hook or
    /// command result) or the user explicitly marks it free ("nothing for me
    /// here") — which is what the context-menu action means.
    func markReady(_ id: UUID) {
        setState(id, .free)
    }

    /// OSC 133: the last shell command finished. Non-zero exit → error (red),
    /// otherwise ready (green). Ignored while an agent turn is active so it
    /// doesn't stomp running/waiting.
    func commandFinished(_ id: UUID, exitCode: Int) {
        guard let session = sessions[id],
              let newState = AttentionState.afterCommandFinish(exitCode: exitCode, current: session.state)
        else { return }
        setState(id, newState)
    }

    private func setState(_ id: UUID, _ state: AttentionState, message: String? = nil) {
        // A turn that ended while you were looking at something else is unseen
        // work; one that ended in front of you is not.
        let unseen = state == .ready && !isVisible(id)
        update(id) {
            guard $0.state != state else { return }
            $0.state = state
            $0.stateSince = Date()
            $0.lastMessage = message
            if unseen { $0.seen = false }
        }
        // A new waiting spell may escalate again; badges follow every change.
        escalatedIDs.remove(id)
        refreshDockBadge()
    }

    // MARK: Hook events (from HookServer)

    /// Terminals currently running an agent, from its first hook until
    /// SessionEnd. Deliberately NOT persisted: right after a restart nothing is
    /// running yet — a resumed agent re-announces itself with its first hook.
    private var liveAgentIDs: Set<UUID> = []

    /// Whether a live **Claude Code** session owns this terminal. Both halves
    /// matter for the ⌃V image paste: the agent must be running *and* be the one
    /// that reads images off the clipboard. Codex gets the path instead.
    func hasLiveClaude(_ id: UUID) -> Bool {
        liveAgentIDs.contains(id) && sessions[id]?.agentKind == .claude
    }

    /// Whether any recognized agent is live in this terminal.
    func hasLiveAgent(_ id: UUID) -> Bool { liveAgentIDs.contains(id) }

    func applyHookEvent(
        sessionID: UUID,
        hookEvent: String,
        claudeSessionID: String?,
        transcriptPath: String?,
        message: String?,
        prompt: String? = nil,
        source: String? = nil,
        agent: AgentKind = .claude
    ) {
        guard sessions[sessionID] != nil else { return }
        // A hook firing at all proves the agent is alive in this terminal;
        // SessionEnd is the only event that ends it.
        if hookEvent == "SessionEnd" {
            liveAgentIDs.remove(sessionID)
        } else {
            liveAgentIDs.insert(sessionID)
        }
        // The hook claims the terminal for its agent: from here on the app knows
        // what runs here, which decides how much a later screen reading may say.
        if agent != .none, sessions[sessionID]?.agentKind != agent {
            update(sessionID) { $0.agentKind = agent }
        }
        if claudeSessionID != nil || transcriptPath != nil {
            update(sessionID) {
                if let claudeSessionID { $0.claudeSessionID = claudeSessionID }
                if let transcriptPath { $0.transcriptPath = transcriptPath }
            }
        }
        // The submitted prompt is the task this terminal works on from now on.
        if hookEvent == "UserPromptSubmit",
           let task = prompt.flatMap(TerminalSession.taskLine(fromPrompt:)) {
            update(sessionID) { $0.currentTask = task }
        }
        // Claude is gone — its task is too. So is a `/clear`: the conversation
        // that carried the task no longer exists. A resumed or compacted
        // session keeps working on the same thing, so its task survives.
        if hookEvent == "SessionEnd" || (hookEvent == "SessionStart" && source == "clear") {
            update(sessionID) { $0.currentTask = nil }
        }
        // State transition (pure, tested). Message only carried for `waiting`.
        if let newState = AttentionState.forHookEvent(hookEvent, source: source) {
            setState(sessionID, newState, message: newState == .waiting ? message : nil)
        }
        // Per-event side effects.
        switch hookEvent {
        case "Notification", "PermissionRequest":
            postUserNotification(sessionID: sessionID, message: message)
            aiAssist.sessionUpdated(sessionID)
        case "Stop", "SubagentStop":
            aiAssist.sessionUpdated(sessionID)
        default:
            break
        }
    }

    private func postUserNotification(sessionID: UUID, message: String?) {
        guard let session = sessions[sessionID] else { return }
        // Only interrupt for favorites; side projects just queue in the inbox.
        guard group(of: session)?.favorite == true else { return }
        NotificationService.post(
            title: "\(session.displayTitle) \(L10n.t(.asks))",
            body: message ?? "",
            sessionID: session.id
        )
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

    /// Import all tabs/sessions from another terminal app. The AppleScript +
    /// `lsof` resolution runs off the main thread so the UI never blocks.
    func importFrom(_ source: MigrationService.Source, windowID: UUID?) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                MigrationService.importDirectories(from: source)
            }.value
            switch result {
            case .success(let dirs):
                let count = openTerminals(inDirectories: dirs, windowID: windowID)
                if count == 0 { showImportAlert(source, .nothingFound) }
            case .failure(let error):
                showImportAlert(source, error)
            }
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
            autoUpdateCheck: autoUpdateCheck,
            durableTerminals: durableTerminals
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: Self.stateURL, options: .atomic)
            // User-only: state carries cwd, titles and Claude session ids.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Self.stateURL.path)
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
        durableTerminals = state.durableTerminals
        windowsToOpen = windows.dropFirst().map(\.id)

        refreshDockBadge()

        // Resolve which Claude conversation each terminal resumes as ONE batch
        // over all terminals — so two tabs of the same project can never claim
        // the same conversation (per-terminal fallbacks used to converge them
        // all onto the project's newest transcript).
        restoreResumeIDs = ClaudeResume.resolveAll(
            groups.flatMap(\.sessionIDs)
                .compactMap { sessions[$0] }
                .filter(\.resumeClaudeOnRestore)
                .map {
                    ClaudeResume.Terminal(
                        id: $0.id,
                        claudeSessionID: $0.claudeSessionID,
                        transcriptPath: $0.transcriptPath,
                        currentDirectory: $0.currentDirectory)
                })

        // Which durable terminals still have a live agent, resolved as one batch
        // like the Claude conversations above. Asking tmux per terminal meant a
        // subprocess each, on the main thread, at exactly the moment the UI
        // should be coming up — so it happens once, off-main, and only when
        // there is a durable terminal to ask about. Everything else keeps the
        // synchronous path it always had.
        if sessions.values.contains(where: \.durable) {
            Task { @MainActor in
                self.restoreLiveDurableIDs = await Task.detached {
                    Durable.liveIDs(in: Durable.listSessions())
                }.value
                self.createRestoredSurfaces()
            }
        } else {
            createRestoredSurfaces()
        }

        // After a grace period, new surfaces are ordinary terminals again.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            self.isRestoring = false
            self.restoreResumeIDs = [:]
            self.restoreLiveDurableIDs = []
        }

        reapOrphanedDurableSessions(keeping: Set(sessions.keys))
    }

    /// Eagerly create EVERY terminal's surface (while `isRestoring` is true) so
    /// they all resume in the background — Claude resume, scrollback replay,
    /// startup commands — not just the visible tab. Lazy creation would skip
    /// background tabs and unselected projects/windows, so those sessions would
    /// never restore. Surfaces are registry-cached, so the SwiftUI views reuse
    /// them when they eventually appear.
    private func createRestoredSurfaces() {
        for group in groups {
            for id in group.sessionIDs {
                if let session = sessions[id] {
                    _ = TerminalRegistry.shared.view(for: session, appState: self)
                }
            }
        }
    }

    /// Kill the tmux sessions of terminals that no longer exist. A durable
    /// session outliving its terminal is the whole point *while the terminal is
    /// coming back* — but a terminal closed in a previous run, or lost with a
    /// discarded state, would otherwise leave its agent running forever with
    /// nothing attached to it. Runs off-main: it shells out to tmux.
    ///
    /// Only unattached sessions are considered, so a second Planchette running
    /// at the same time keeps its agents even when this one starts fresh.
    func reapOrphanedDurableSessions(keeping live: Set<UUID>) {
        Task.detached {
            for id in Durable.unattachedSessionIDs() where !live.contains(id) {
                Durable.killSession(for: id)
            }
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
        // Drop stale scrollback dumps so a fresh start shows no old history.
        try? FileManager.default.removeItem(at: Self.scrollbackDir)
        // "Start fresh" means fresh: no durable session from the discarded state
        // may keep running, since nothing will ever attach to it again.
        reapOrphanedDurableSessions(keeping: [])
        groups = []
        sessions = [:]
        windows = [WindowModel(id: Self.mainWindowID)]
        aiEnabled = previous?.aiEnabled ?? aiEnabled
        // Keep the user's chosen language and appearance across a fresh start.
        language = previous?.language ?? language
        appearance = previous?.appearance ?? appearance
        autoUpdateCheck = previous?.autoUpdateCheck ?? autoUpdateCheck
        durableTerminals = previous?.durableTerminals ?? durableTerminals
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
        center.addObserver(forName: .planchetteCommandFinished, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID,
                  let exitCode = note.userInfo?["exitCode"] as? Int else { return }
            Task { @MainActor in self?.commandFinished(id, exitCode: exitCode) }
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

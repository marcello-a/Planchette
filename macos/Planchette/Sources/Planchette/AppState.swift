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
    ///
    /// On by default, like every other setting. The trade-off it carries has not
    /// changed: tmux cannot pass the terminal's keyboard protocol through, so
    /// `Shift+Enter` reaches an agent as a plain `Enter`. Whoever needs multi-line
    /// prompts more than a surviving agent turns it off — the Settings text says
    /// so. Without tmux installed it does nothing (`Durable.isAvailable` gates
    /// every new session), so the default cannot break a machine that lacks it.
    @Published var durableTerminals = true {
        didSet { scheduleSave() }
    }
    /// A collapsed sidebar project still lists its terminals with an unread
    /// question or error (the "peek"). On by default — folding a project is for
    /// space, not for losing a prompt. Off keeps a folded project fully folded.
    @Published var peekCollapsedProjects = true {
        didSet { scheduleSave() }
    }
    /// The IDE the "look at code" button always opens, once one is chosen in
    /// its menu. Nil = no choice made yet: the button falls back to whichever
    /// known IDE is running (see `IDEs.target`).
    @Published var defaultIDEBundleID: String? {
        didSet { scheduleSave() }
    }
    /// Windows (beyond the main one) that still need to be opened after a
    /// restore; the main window's ContentView consumes this.
    @Published var windowsToOpen: [UUID] = []
    /// Saved arrangements. Kept in their own file (see `PresetStore`) so
    /// "Start fresh" — which throws the workspace away — leaves them standing.
    @Published var presets: [Preset] = PresetStore.load()

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

    static let stateURL: URL = SupportPaths.dir.appendingPathComponent("state.json")

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
    ///
    /// `force` is for quit: it always captures and writes synchronously, since
    /// the process is about to exit. Everything else is throttled — Cmd-Tabbing
    /// through apps must not re-capture megabytes of scrollback per switch —
    /// and writes off the main thread.
    func saveScrollbacks(force: Bool = false) {
        if !force {
            guard Date().timeIntervalSince(lastScrollbackSave) >= 15 else { return }
        }
        lastScrollbackSave = Date()
        TerminalRegistry.shared.saveScrollback(to: Self.scrollbackDir, sync: force)
    }

    private var lastScrollbackSave: Date = .distantPast

    init() {
        // Load the persisted language before any SwiftUI scene (incl. menus)
        // is built, so the whole UI launches in the right language.
        if let saved = Self.loadPersistedState() {
            language = saved.language
            L10n.current = saved.language
            appearance = saved.appearance
            autoUpdateCheck = saved.autoUpdateCheck
            durableTerminals = saved.durableTerminals
            peekCollapsedProjects = saved.peekCollapsedProjects
            // Load the opt-in AI flag early too: a launch with a saved-but-
            // sessionless state runs startFresh(archiving: nil), which keeps the
            // *current* value — so without this a user's aiEnabled=false silently
            // flips back to the default and claude -p starts summarizing again.
            aiEnabled = saved.aiEnabled
            defaultIDEBundleID = saved.defaultIDEBundleID
        }
        observeSurfaceNotifications()
        startAttentionHousekeeping()
        startScreenDetection()
        startBranchPolling()
        startDevServerPolling()
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
        let count = sessions.values.filter { $0.state.needsAttention && !isMuted($0) }.count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    /// Waiting/error longer than the threshold escalates exactly once per
    /// spell: favorites get a reminder notification, everything else only
    /// counts on in the badges. State changes reset the spell (see setState).
    private func attentionHousekeeping() {
        checkSnoozeExpiry()
        refreshDockBadge()
        for session in sessions.values
        where session.state.needsAttention && !isMuted(session)
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

    /// Poll ticks elapsed — drives the reduced background rate below.
    private var screenPollTick = 0

    /// Read every live terminal's viewport and let the screen fill the gaps the
    /// hooks leave. Hooks stay the authority wherever they are live — see
    /// `AttentionState.fromScreen`.
    private func pollScreens() {
        // In the background the screen is a notification source, not a live UI:
        // nobody is watching an indicator change within 1.5s. Every read locks
        // the renderer and copies a full viewport, per agent terminal — with
        // the app inactive that cost bought nothing, 24/7, scaling with the
        // session count. A quarter of the rate (6s) keeps background questions
        // arriving promptly while cutting the idle cost by 4×.
        screenPollTick += 1
        if NSApp?.isActive != true && !screenPollTick.isMultiple(of: 4) { return }
        reloadScreenRulesIfChanged()
        for (id, session) in sessions {
            let rules = screenRules.rules(for: session.agentKind)
            // Nothing to match against (e.g. a plain shell, or an agent whose
            // patterns aren't verified yet) → don't even read the surface.
            guard !rules.isEmpty else { continue }
            // Under hook authority the screen may only escalate to waiting —
            // and only while the terminal does not already need attention
            // (see AttentionState.fromScreen). When it does, no reading can
            // change anything, so skip the read: it locks the renderer and
            // dumps the viewport, per terminal, on every tick.
            let hookAuthority = hasHookAuthority(id)
            if hookAuthority && session.state.needsAttention { continue }
            guard let view = TerminalRegistry.shared.existingView(id),
                  let text = view.readViewport()
            else { continue }
            let detection = ScreenDetector.detect(
                lines: text.components(separatedBy: "\n"), rules: rules)
            guard let newState = AttentionState.fromScreen(
                detection,
                agent: session.agentKind,
                hookAuthority: hookAuthority,
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
        var window = windows[idx]
        mutate(&window)
        guard window != windows[idx] else { return }
        windows[idx] = window
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
        sanitizeFolders()
        // A dissolved folder must not keep the main area on an overview of
        // something that no longer exists.
        for idx in windows.indices {
            if let selected = windows[idx].selectedFolderID,
               !windows[idx].folders.contains(where: { $0.id == selected }) {
                windows[idx].selectedFolderID = nil
            }
        }
    }

    /// A folder may only name projects that live in its own window, and each
    /// project in at most one folder. Runs after every window repair, so a
    /// project that was closed or moved away can't leave a ghost behind.
    private func sanitizeFolders() {
        for widx in windows.indices {
            let own = Set(windows[widx].groupIDs)
            var claimed = Set<UUID>()
            for fidx in windows[widx].folders.indices {
                windows[widx].folders[fidx].groupIDs.removeAll { id in
                    !own.contains(id) || !claimed.insert(id).inserted
                }
            }
            // An empty folder is kept: it is a box you just made, or emptied on
            // purpose, and losing it while you fill it would be worse.
        }
    }

    // MARK: Project folders (per window)

    /// Create a folder in a window, optionally with a first project in it.
    @discardableResult
    func addFolder(name: String, inWindow windowID: UUID, containing groupID: UUID? = nil) -> ProjectFolder {
        var folder = ProjectFolder(name: name)
        if let groupID { folder.groupIDs = [groupID] }
        updateWindow(windowID) { window in
            // A project belongs to one folder only.
            for idx in window.folders.indices {
                window.folders[idx].groupIDs.removeAll { $0 == groupID }
            }
            window.folders.append(folder)
        }
        return folder
    }

    func updateFolder(_ folderID: UUID, inWindow windowID: UUID, _ mutate: (inout ProjectFolder) -> Void) {
        updateWindow(windowID) { window in
            guard let idx = window.folders.firstIndex(where: { $0.id == folderID }) else { return }
            mutate(&window.folders[idx])
        }
    }

    /// Dissolve a folder — its projects stay, back at the top level.
    func removeFolder(_ folderID: UUID, inWindow windowID: UUID) {
        updateWindow(windowID) { window in
            window.folders.removeAll { $0.id == folderID }
            // Its overview was what the main area showed: back to the project.
            if window.selectedFolderID == folderID { window.selectedFolderID = nil }
        }
    }

    /// Move a project into a folder, or out of every folder (`folderID` nil).
    func moveGroup(_ groupID: UUID, toFolder folderID: UUID?, inWindow windowID: UUID) {
        moveGroups([groupID], toFolder: folderID, inWindow: windowID)
    }

    /// Drag-and-drop: move projects into a folder (nil = top level), before
    /// `before` or at the end. The ordering itself lives on `WindowModel` so it
    /// is unit-tested; this only owns the persistence.
    func moveGroups(_ ids: [UUID], toFolder folderID: UUID?, before: UUID? = nil,
                    inWindow windowID: UUID) {
        updateWindow(windowID) { $0.move(ids, toFolder: folderID, before: before) }
    }

    /// Bulk versions of the single-project actions, for a multi-selection.
    func markGroupsReady(_ ids: [UUID]) {
        for id in ids { markGroupReady(id) }
    }

    func snooze(groups ids: [UUID], until date: Date) {
        for id in ids { snooze(group: id, until: date) }
    }

    func setFavorite(_ favorite: Bool, forGroups ids: [UUID]) {
        for id in ids { updateGroup(id) { $0.favorite = favorite } }
    }

    /// Park projects, or bring them back. Parking also marks their terminals free:
    /// a project that goes silent must not keep a question or a finished turn
    /// standing, or marking it active again re-opens news that is hours old.
    func setActive(_ active: Bool, forGroups ids: [UUID]) {
        for id in ids {
            updateGroup(id) { $0.active = active }
            if !active { markGroupReady(id) }
        }
    }

    func closeGroups(_ ids: [UUID]) {
        for id in ids { closeGroup(id) }
    }

    /// Terminals across a set of projects — for "close 3 projects and their 7
    /// terminals?" style confirmations.
    func terminalCount(inGroups ids: [UUID]) -> Int {
        ids.reduce(0) { total, id in
            total + (groups.first { $0.id == id }?.sessionIDs.count ?? 0)
        }
    }

    /// The projects of a folder, in the folder's own order.
    func groups(inFolder folder: ProjectFolder) -> [SessionGroup] {
        folder.groupIDs.compactMap { id in groups.first { $0.id == id } }
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
        // Carry the source window's project folders too: the groups they name
        // now live in the target window, so dropping them would silently destroy
        // the user's folder organization on every window merge.
        windows[targetIdx].folders.append(contentsOf: source.folders)
        if windows[targetIdx].selectedGroupID == nil {
            windows[targetIdx].selectedGroupID = source.selectedGroupID
        }
        windows.removeAll { $0.id == sourceID }
        scheduleSave()
    }

    // MARK: Git branch per terminal

    /// Which branch each terminal's checkout is on, keyed by session id.
    /// Derived and never persisted: the checkout on disk is the truth, and it
    /// changes behind the app's back (any `git checkout` in the terminal).
    ///
    /// Per terminal rather than per project because the terminals of one project
    /// can sit in different checkouts, and the sidebar shows the branch on the
    /// project row only while they agree (see `sharedBranch`).
    @Published var branches: [UUID: String] = [:]
    private var branchTimer: Timer?
    /// Cheap enough to be invisible, fast enough that a checkout you just did
    /// shows up while you're still in the terminal.
    static let branchPollInterval: TimeInterval = 10

    private func startBranchPolling() {
        refreshBranches()
        let timer = Timer(timeInterval: Self.branchPollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshBranches() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        branchTimer = timer
    }

    /// One `git branch --show-current` per *distinct* directory, off the main
    /// thread (rule 5). Terminals of a project usually share their checkout, so
    /// asking per directory and fanning the answer back out to the sessions
    /// costs no more subprocesses than the old per-project poll did.
    private func refreshBranches() {
        let dirs: [String: [UUID]] = sessions.values.reduce(into: [:]) { acc, session in
            guard !session.currentDirectory.isEmpty else { return }
            acc[session.currentDirectory, default: []].append(session.id)
        }
        guard !dirs.isEmpty else {
            if !branches.isEmpty { branches = [:] }
            return
        }
        Task.detached {
            let found = dirs.reduce(into: [UUID: String]()) { found, entry in
                guard let branch = Worktrees.currentBranch(of: entry.key) else { return }
                for id in entry.value { found[id] = branch }
            }
            await MainActor.run { [weak self] in
                // Publish only a real change: an unconditional assignment
                // invalidated every observing view on every poll tick.
                guard let self, self.branches != found else { return }
                self.branches = found
            }
        }
    }

    // MARK: Dev servers & IDEs per project

    /// Dev servers running in each project's checkout, keyed by group id.
    /// Derived and never persisted: the processes on the machine are the
    /// truth, and they start and stop behind the app's back — in a Planchette
    /// terminal, in an IDE, anywhere.
    @Published var devServers: [UUID: [DevServer]] = [:]
    /// Known IDEs currently running — refreshed on the same tick, so the
    /// "look at code" button always names a live target.
    @Published var runningIDEs: Set<String> = []
    /// Which IDE markers each project's checkout carries (`.idea`, `.vscode`,
    /// …), keyed by group id. Read off disk on the poll tick, because the
    /// button must not stat directories while a view renders.
    @Published var ideMarkers: [UUID: [String]] = [:]
    /// The known IDE you worked in last. The tie-break when a checkout carries
    /// no marker: of two running IDEs, the one you just came from is the one
    /// you mean.
    @Published private(set) var lastActivatedIDE: String?
    /// The known IDEs on this machine. Cached, because finding them asks
    /// LaunchServices once per candidate — far too much for a view body, which
    /// re-runs on every state change.
    @Published private(set) var installedIDEs: [IDE] = []
    private var devServerTimer: Timer?
    /// Slow enough to be invisible next to the two ~100ms lsof calls (which
    /// run off the main thread), fast enough that `npm run dev` has its link
    /// on screen while the server is still printing its banner.
    static let devServerPollInterval: TimeInterval = 5

    private func startDevServerPolling() {
        observeIDEActivation()
        refreshDevServers()
        let timer = Timer(timeInterval: Self.devServerPollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.devServerTick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        devServerTimer = timer
    }

    /// Ticks elapsed — in the background nobody reads a link chip, so a
    /// quarter of the rate is plenty (same reasoning as the screen poll).
    private var devServerTicks = 0

    private func devServerTick() {
        devServerTicks += 1
        if NSApp?.isActive != true && !devServerTicks.isMultiple(of: 4) { return }
        refreshDevServers()
    }

    /// Remember which IDE was last in front, so a click can prefer it.
    private func observeIDEActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  IDEs.ide(bundleID: bundleID) != nil
            else { return }
            Task { @MainActor in
                self?.lastActivatedIDE = bundleID
                // An IDE you just launched for the first time has to be a
                // target immediately, not after the next poll tick.
                self?.refreshInstalledIDEs()
            }
        }
    }

    /// Re-read which IDEs exist on this machine.
    func refreshInstalledIDEs() {
        let installed = IDEs.installed()
        if installedIDEs != installed { installedIDEs = installed }
        let running = IDEs.runningBundleIDs()
        if running != runningIDEs { runningIDEs = running }
    }

    private func refreshDevServers() {
        let running = IDEs.runningBundleIDs()
        if running != runningIDEs { runningIDEs = running }
        let dirs: [UUID: [String]] = groups.reduce(into: [:]) { acc, group in
            let paths = sessions(in: group)
                .flatMap { [$0.workingDirectory, $0.currentDirectory] }
                .filter { !$0.isEmpty }
            if !paths.isEmpty { acc[group.id] = Array(Set(paths)) }
        }
        // Where each project's IDE would be opened — one directory per project,
        // so the marker read matches what the button acts on.
        let projectDirs: [UUID: String] = groups.reduce(into: [:]) { acc, group in
            if let dir = projectDirectory(of: group) { acc[group.id] = dir }
        }
        guard !dirs.isEmpty else {
            if !devServers.isEmpty { devServers = [:] }
            if !ideMarkers.isEmpty { ideMarkers = [:] }
            return
        }
        Task.detached {
            let found = DevServerScanner.scan(projectDirs: dirs)
            let markers = projectDirs.mapValues { IDEs.markers(in: $0) }
            let installed = IDEs.installed()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.ideMarkers != markers { self.ideMarkers = markers }
                if self.installedIDEs != installed { self.installedIDEs = installed }
                // Carry over (and complete) the announced URLs before comparing:
                // the addresses are part of what a chip shows, so resolving one
                // has to publish.
                let withURLs = self.resolvingServerURLs(found)
                // Publish only a real change (see refreshBranches).
                guard self.devServers != withURLs else { return }
                self.devServers = withURLs
            }
        }
    }

    /// Addresses already learned, keyed by port. Kept because a banner scrolls
    /// away: once a server has told us it serves `https://vite.myposter.de:8082`,
    /// that stays true until the port itself goes away.
    private var serverURLs: [Int: URL] = [:]

    /// Fill in each server's announced URL, reading a terminal's scrollback only
    /// for ports we have never resolved. The read locks the renderer and copies
    /// the whole buffer, so it happens once per port, not once per tick.
    private func resolvingServerURLs(_ found: [UUID: [DevServer]]) -> [UUID: [DevServer]] {
        let livePorts = Set(found.values.flatMap { $0.map(\.port) })
        serverURLs = serverURLs.filter { livePorts.contains($0.key) }
        var result = found
        for (groupID, servers) in found {
            guard let group = groups.first(where: { $0.id == groupID }) else { continue }
            let unresolved = servers.filter { serverURLs[$0.port] == nil }
            if !unresolved.isEmpty {
                // The banner is in the terminal that started the server; which
                // one that is we don't know, so read the project's terminals.
                let texts = sessions(in: group).compactMap {
                    TerminalRegistry.shared.existingView($0.id)?.readScrollback()
                }
                for server in unresolved {
                    for text in texts {
                        if let url = DevServerScanner.bestURL(forPort: server.port, in: text) {
                            serverURLs[server.port] = url
                            break
                        }
                    }
                }
            }
            result[groupID] = servers.map {
                var server = $0
                server.resolvedURL = serverURLs[$0.port]
                return server
            }
        }
        return result
    }

    /// The IDE a click on this project's button opens — nil when there is no
    /// honest target and the button has to ask instead.
    func ideTarget(for group: SessionGroup) -> IDE? {
        IDEs.resolve(
            markers: ideMarkers[group.id] ?? [],
            defaultBundleID: defaultIDEBundleID,
            running: runningIDEs,
            installed: installedIDEs,
            lastActivated: lastActivatedIDE)
    }

    /// The directory the "look at code" button and a new IDE open: where the
    /// project's terminals started, which is the checkout for everything but a
    /// hand-rolled setup.
    func projectDirectory(of group: SessionGroup) -> String? {
        let sessions = sessions(in: group)
        return sessions.first(where: { !$0.workingDirectory.isEmpty })?.workingDirectory
            ?? sessions.first(where: { !$0.currentDirectory.isEmpty })?.currentDirectory
    }

    /// The one branch all terminals of a project are on, or nil when they
    /// disagree — then the branch belongs on each terminal row instead, because
    /// a single line on the project would name a checkout some of them are not in.
    /// A terminal outside a repo counts as a disagreement: it has no branch to
    /// share.
    func sharedBranch(of group: SessionGroup) -> String? {
        Worktrees.sharedBranch(sessions(in: group).map { branches[$0.id] })
    }

    // MARK: Derived

    func sessions(in group: SessionGroup) -> [TerminalSession] {
        group.sessionIDs.compactMap { sessions[$0] }
    }

    func group(of session: TerminalSession) -> SessionGroup? {
        groups.first { $0.id == session.groupID }
    }

    /// Inbox: everything needing attention. Favorites first, errors before
    /// waiting, longest-waiting first. Snoozed terminals are left out — that is
    /// what snoozing them meant.
    var attentionQueue: [TerminalSession] {
        sessions.values
            .filter { $0.state.needsAttention && !isMuted($0) }
            .sorted { a, b in
                let aFav = group(of: a)?.favorite ?? false
                let bFav = group(of: b)?.favorite ?? false
                if aFav != bFav { return aFav }
                if a.state != b.state { return a.state == .error }
                return a.stateSince < b.stateSince
            }
    }

    /// What the menu bar lists: everything that still wants your eyes. The
    /// questions and errors first, in triage order, then the turns that finished
    /// while you were away — a finished turn is news until you look at it, and
    /// the menu bar is where you look when the app is not in front of you.
    var menuBarQueue: [TerminalSession] {
        let done = sessions.values
            .filter { $0.state == .ready && !$0.seen && !isMuted($0) }
            .sorted { $0.stateSince < $1.stateSince }
        return attentionQueue + done
    }

    /// The notifications panel as data: one section per project, in the order the
    /// panel lists them — the given window's projects first (favorites before the
    /// rest, exactly like its sidebar), then every other window's, so nothing
    /// happening elsewhere is invisible. Parked projects are left out: they are
    /// silent (see `isMuted`).
    ///
    /// Shared with the control API on purpose. "What another program can read"
    /// and "what the panel shows" have to be the same list, or the API starts
    /// answering a question about a UI that has moved on.
    func notificationSections(
        windowID: UUID? = nil, unreadOnly: Bool = false, activeOnly: Bool = false
    ) -> [(group: SessionGroup, sessions: [TerminalSession])] {
        let ordered = windows.sorted { a, _ in a.id == windowID }
        var out: [(group: SessionGroup, sessions: [TerminalSession])] = []
        for window in ordered {
            let inWindow = groups(inWindow: window).filter(\.active)
            for group in inWindow.filter(\.favorite) + inWindow.filter({ !$0.favorite }) {
                var tabs = sessions(in: group)
                if activeOnly { tabs = tabs.filter(\.state.isActive) }
                if unreadOnly { tabs = tabs.filter(\.isUnread) }
                if !tabs.isEmpty { out.append((group, tabs)) }
            }
        }
        return out
    }

    /// The name a notification row prints: the branch of this terminal's checkout
    /// from its ticket on (`marcello/feat/NIE-1902-format-switch` →
    /// `NIE-1902-format-switch`) — ticket and branch in one string, which is what
    /// tells two worktrees of one repo apart. A name you typed still wins, and a
    /// terminal outside a repo keeps the title it gives itself.
    ///
    /// Here rather than in the panel so the control API can hand out the same
    /// string (`ControlAPI.describeNotification`): a caller drawing its own
    /// notification list must not have to re-derive it and drift.
    func notificationHeadline(for session: TerminalSession) -> String {
        if let custom = session.customTitle, !custom.isEmpty { return custom }
        if let branch = branches[session.id] {
            let cut = Titles.branchFromTicket(branch)
            if !cut.isEmpty { return cut }
        }
        return session.displayTitle
    }

    var waitingCount: Int {
        sessions.values.filter { $0.state == .waiting && !isMuted($0) }.count
    }
    var errorCount: Int {
        sessions.values.filter { $0.state == .error && !isMuted($0) }.count
    }

    // MARK: Mutations

    /// `select: false` adds the project without showing it — the control API's
    /// contract is "do not steal focus unless asked", and switching the visible
    /// project IS stealing focus.
    @discardableResult
    func addGroup(
        name: String, favorite: Bool = false, inWindow windowID: UUID? = nil,
        select: Bool = true
    ) -> SessionGroup {
        var group = SessionGroup(name: name)
        group.favorite = favorite
        groups.append(group)
        sanitizeWindows()
        let target = windowID ?? windows[0].id
        if let idx = windows.firstIndex(where: { $0.id == target }) {
            // sanitizeWindows put the orphan into windows[0]; move if needed.
            for i in windows.indices { windows[i].groupIDs.removeAll { $0 == group.id } }
            windows[idx].groupIDs.append(group.id)
            if select { windows[idx].selectGroup(group.id) }
        }
        scheduleSave()
        return group
    }

    /// `activate: false` adds the terminal without making it the project's
    /// active tab (again the control API's no-focus-steal contract); the tab
    /// still becomes active when the project had none, or nothing would show it.
    @discardableResult
    func addSession(directory: String, groupID: UUID, activate: Bool = true) -> TerminalSession {
        var session = TerminalSession(groupID: groupID, workingDirectory: directory)
        // Decided once, here: the multiplexer has to own the process tree from
        // the very first process. Without tmux installed the terminal is simply
        // an ordinary one — the feature degrades, it never fails.
        session.durable = durableTerminals && Durable.isAvailable
        sessions[session.id] = session
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].sessionIDs.append(session.id)
            if activate || groups[idx].activeSessionID == nil {
                groups[idx].activeSessionID = session.id
            }
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
        escalatedIDs.remove(id)
        aiAssist.forget(id)
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
            escalatedIDs.remove(sid)
            aiAssist.forget(sid)
        }
        groups.removeAll { $0.id == groupID }
        sanitizeWindows()
        // Closing a project with waiting/error terminals must clear their share
        // of the dock badge now, exactly as closeSession does — otherwise the
        // count stays stale until the next housekeeping tick (up to 60 s).
        refreshDockBadge()
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

    // The three mutation helpers publish only a REAL change. A no-op write
    // still fires objectWillChange (a @Published set has no equality check) and
    // schedules a save — and hook events produce no-op writes constantly: every
    // event re-carries the same Claude session id and transcript path, every
    // OSC title repeat re-writes the same title. Two busy agents turned that
    // into a steady stream of full-window SwiftUI re-layouts plus a state.json
    // write per second, for state that never changed.

    func update(_ id: UUID, _ mutate: (inout TerminalSession) -> Void) {
        guard var session = sessions[id] else { return }
        mutate(&session)
        guard session != sessions[id] else { return }
        sessions[id] = session
        scheduleSave()
    }

    func updateGroup(_ id: UUID, _ mutate: (inout SessionGroup) -> Void) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        var group = groups[idx]
        mutate(&group)
        guard group != groups[idx] else { return }
        groups[idx] = group
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
    var unseenReadyCount: Int { unseenCount(.ready) }

    /// Unread terminals in one state — what the menu bar counts: only news you
    /// have not looked at belongs up there, a report you already read (or
    /// snoozed) must not keep nagging from the top of the screen.
    func unseenCount(_ state: AttentionState) -> Int {
        sessions.values.filter { $0.state == state && !$0.seen && !isMuted($0) }.count
    }

    /// Unread notifications: terminals whose last report you have not looked at.
    /// Snoozed ones are left out, like everywhere else that counts.
    var unreadCount: Int {
        sessions.values.filter { !$0.seen && $0.state.isReport && !isMuted($0) }.count
    }

    /// "I've seen all of it" — the way out of a full unread list without
    /// visiting every terminal. Only clears the reading state; the terminals
    /// keep their colors, since a question stays open until it is answered.
    func markAllRead() {
        for id in sessions.keys where sessions[id]?.seen == false {
            update(id) { $0.seen = true }
        }
    }

    /// Looking at a terminal marks its finished work as seen. Deliberately only
    /// `ready`: `waiting` and `error` persist until the agent moves on or you
    /// mark them free — a glance isn't an answer.
    func markSeen(_ id: UUID) {
        guard sessions[id]?.seen == false else { return }
        update(id) { $0.seen = true }
    }

    /// Put a report back on the unread list — "I looked, but I am not done with
    /// this". The counterpart to markSeen, and the reason reading state is a flag
    /// of its own rather than a side effect of having focused a terminal.
    func markUnread(_ id: UUID) {
        guard let session = sessions[id], session.state.isReport, session.seen else { return }
        update(id) { $0.seen = false }
    }

    func select(session: TerminalSession) {
        markSeen(session.id)
        if let window = windowContaining(groupID: session.groupID) {
            updateWindow(window.id) { $0.selectGroup(session.groupID) }
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
            updateWindow(window.id) { $0.selectGroup(group.id) }
            WindowRegistry.shared.raise(window.id)
        }
    }

    /// Show a folder's overview instead of a terminal — what is in this box,
    /// what each project is doing, and what it reported last.
    func select(folder folderID: UUID, inWindow windowID: UUID) {
        updateWindow(windowID) { window in
            guard window.folders.contains(where: { $0.id == folderID }) else { return }
            window.selectedFolderID = folderID
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
        markSeen(id)
    }

    /// Mark every terminal of a project free — "I've dealt with this project".
    func markGroupReady(_ groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        for id in group.sessionIDs { markReady(id) }
    }

    // MARK: Snooze ("not now — remind me then")

    /// Is this terminal currently silenced? Either on its own, or because its
    /// whole project is. Snoozed terminals are out of the inbox, the badges,
    /// the menu bar and every notification — their state still tracks reality,
    /// it just stops shouting about it.
    func isSnoozed(_ session: TerminalSession, now: Date = Date()) -> Bool {
        Snooze.isActive(
            sessionUntil: session.snoozedUntil,
            groupUntil: group(of: session)?.snoozedUntil,
            now: now)
    }

    func isSnoozed(sessionID: UUID, now: Date = Date()) -> Bool {
        sessions[sessionID].map { isSnoozed($0, now: now) } ?? false
    }

    /// Is this terminal silent? Either snoozed, or parked with its project (see
    /// `SessionGroup.active`). THE filter for anything that counts or announces
    /// attention — a badge, a dock count, a banner, the inbox. The two reasons
    /// differ only in how they end: a snooze runs out by itself, a parked project
    /// waits to be marked active again.
    func isMuted(_ session: TerminalSession, now: Date = Date()) -> Bool {
        if isSnoozed(session, now: now) { return true }
        return group(of: session)?.active == false
    }

    /// When this terminal comes back (its own snooze, or its project's — the
    /// later of the two is what actually silences it).
    func snoozeEnd(for session: TerminalSession) -> Date? {
        Snooze.end(
            sessionUntil: session.snoozedUntil,
            groupUntil: group(of: session)?.snoozedUntil)
    }

    /// Silence a terminal until `date`, and set it free right away: the point of
    /// "not now" is that it stops asking. The reminder fires in
    /// `checkSnoozeExpiry`.
    func snooze(session id: UUID, until date: Date) {
        setState(id, .free)
        update(id) {
            $0.snoozedUntil = date
            $0.seen = true
        }
        refreshDockBadge()
    }

    /// Same for a whole project — one reminder for the project, not one per tab.
    func snooze(group groupID: UUID, until date: Date) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        for id in group.sessionIDs {
            setState(id, .free)
            update(id) { $0.seen = true }
        }
        updateGroup(groupID) { $0.snoozedUntil = date }
        refreshDockBadge()
    }

    func clearSnooze(session id: UUID) {
        update(id) { $0.snoozedUntil = nil }
        refreshDockBadge()
    }

    /// Cancels the *project's* reminder only. A terminal you silenced by itself
    /// stays silenced — it was a separate decision.
    func clearSnooze(group groupID: UUID) {
        updateGroup(groupID) { $0.snoozedUntil = nil }
        refreshDockBadge()
    }

    /// Fire the reminders that came due and let those terminals speak again.
    /// Called every housekeeping tick and once after a restore — so a snooze
    /// that ran out while the app was closed reminds you when you come back
    /// rather than expiring in silence.
    func checkSnoozeExpiry(now: Date = Date()) {
        for group in groups {
            guard let until = group.snoozedUntil, until <= now else { continue }
            updateGroup(group.id) { $0.snoozedUntil = nil }
            NotificationService.post(
                title: "\(group.name) — \(L10n.t(.reminder))",
                body: L10n.t(.reminderBody),
                sessionID: group.activeSessionID ?? group.sessionIDs.first)
        }
        for session in sessions.values {
            guard let until = session.snoozedUntil, until <= now else { continue }
            update(session.id) { $0.snoozedUntil = nil }
            NotificationService.post(
                title: "\(session.displayTitle) — \(L10n.t(.reminder))",
                body: session.lastMessage ?? session.currentTask ?? L10n.t(.reminderBody),
                sessionID: session.id)
        }
        refreshDockBadge()
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
        // Anything that happened while you were looking elsewhere is unread: a
        // turn that finished, a question, an error. What happened in front of you
        // has been read by definition — and `running` is not a report at all, it
        // is the terminal starting the work you just gave it.
        let unseen = state.isReport && !isVisible(id)
        update(id) {
            let stateChanged = $0.state != state
            if stateChanged {
                $0.state = state
                $0.stateSince = Date()
            }
            // A fresh event can carry a new message (a second permission question)
            // even without a state change — record it and re-mark it unread.
            // Suppress only the truly-nothing case (same state, no message), so
            // the equality guard in update() still skips a pointless publish.
            if stateChanged || message != nil {
                $0.lastMessage = message
                if unseen { $0.seen = false }
            }
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
        if let newState = AttentionState.forHookEvent(
            hookEvent, source: source, message: message) {
            setState(sessionID, newState, message: newState == .waiting ? message : nil)
        }
        // Per-event side effects.
        switch hookEvent {
        case "Notification", "PermissionRequest":
            // The idle nudge is not a question (see `isIdleNudge`), so it must not
            // arrive as "X asks" either — the banner would be the same lie as the
            // blue dot, just louder.
            guard !AttentionState.isIdleNudge(message) else { break }
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
        // Silent means silent: no banner while snoozed, and none at all from a
        // project that was parked.
        guard !isMuted(session) else { return }
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

    /// Add a tag if the session does not already carry it. The "New tag…" prompt
    /// uses this, not toggleTag: typing the name of an existing tag must add (or
    /// keep) it, never silently remove it.
    func addTag(_ tag: String, on sessionID: UUID) {
        update(sessionID) {
            if !$0.tags.contains(tag) { $0.tags.append(tag) }
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

    // MARK: Presets (saved arrangements)

    /// Capture a window's shape as a reusable arrangement: its folders,
    /// projects, terminals and cluster splits — no live state (see `Preset`).
    /// An existing preset of the same name is replaced, which is what "save
    /// again" means after you rearranged something.
    @discardableResult
    func savePreset(name: String, fromWindow windowID: UUID) -> Preset? {
        guard let window = window(for: windowID) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var projects: [PresetProject] = []
        for group in groups(inWindow: window) {
            let tabs = sessions(in: group)
            guard !tabs.isEmpty else { continue }
            var project = PresetProject(name: group.name)
            project.color = group.color
            project.favorite = group.favorite
            project.viewMode = group.viewMode
            if let folder = window.folder(of: group.id) {
                project.folderName = folder.name
                project.folderColor = folder.color
            }
            project.terminals = tabs.map { session in
                var terminal = PresetTerminal(workingDirectory: session.currentDirectory)
                terminal.customTitle = session.customTitle
                terminal.color = session.color
                terminal.tags = session.tags
                terminal.startupCommand = session.startupCommand
                return terminal
            }
            if group.viewMode == .cluster {
                project.clusterLayout = PresetLayout.from(
                    clusterLayout(for: group), sessionIDs: tabs.map(\.id))
            }
            projects.append(project)
        }
        guard !projects.isEmpty else { return nil }

        var preset = Preset(name: trimmed, projects: projects)
        if let idx = presets.firstIndex(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            preset = Preset(
                id: presets[idx].id, name: trimmed,
                createdAt: presets[idx].createdAt, projects: projects)
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        PresetStore.save(presets)
        return preset
    }

    /// Build a preset's projects and terminals in a window and jump to the first
    /// one. Adds to whatever is already there — it never clears the window.
    func openPreset(_ preset: Preset, inWindow windowID: UUID) {
        var firstSession: TerminalSession?
        for project in preset.projects {
            let group = addGroup(name: project.name, favorite: project.favorite, inWindow: windowID)
            updateGroup(group.id) {
                $0.color = project.color
                $0.viewMode = project.viewMode
            }
            var createdIDs: [UUID] = []
            for terminal in project.terminals {
                let session = addSession(directory: terminal.workingDirectory, groupID: group.id)
                update(session.id) {
                    $0.customTitle = terminal.customTitle
                    $0.color = terminal.color
                    $0.tags = terminal.tags
                    $0.startupCommand = terminal.startupCommand
                }
                createdIDs.append(session.id)
                if firstSession == nil { firstSession = sessions[session.id] }
            }
            if let layout = project.clusterLayout?.resolved(with: createdIDs) {
                updateGroup(group.id) { $0.clusterLayout = layout }
            }
            if let folderName = project.folderName {
                let existing = window(for: windowID)?.folders
                    .first { $0.name.lowercased() == folderName.lowercased() }
                if let existing {
                    moveGroup(group.id, toFolder: existing.id, inWindow: windowID)
                } else {
                    let folder = addFolder(name: folderName, inWindow: windowID, containing: group.id)
                    updateFolder(folder.id, inWindow: windowID) { $0.color = project.folderColor }
                }
            }
        }
        if let firstSession, let stored = sessions[firstSession.id] {
            select(session: stored)
        }
        scheduleSave()
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        PresetStore.save(presets)
    }

    func renamePreset(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].name = trimmed
        PresetStore.save(presets)
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
            durableTerminals: durableTerminals,
            peekCollapsedProjects: peekCollapsedProjects,
            defaultIDEBundleID: defaultIDEBundleID
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
    ///
    /// Resolve first, publish second. The moment `sessions` is published,
    /// SwiftUI may build any terminal's surface (`makeNSView` runs on the first
    /// render, and the registry caches what it builds) — so every input to the
    /// replay decision must exist BEFORE that. Resolving tmux liveness after
    /// publishing raced the first render: a live agent read as dead, and the
    /// restore typed `clear; cat <scrollback>` + `claude --resume` into its TUI.
    func applyRestore(_ state: PersistedState) {
        isRestoring = true
        if state.sessions.contains(where: \.durable), Durable.isAvailable {
            // Off-main: it shells out to tmux. The UI shows the welcome screen
            // for the few milliseconds `list-sessions` takes.
            Task { @MainActor in
                self.restoreLiveDurableIDs = await Task.detached {
                    Durable.liveIDs(in: Durable.listSessions())
                }.value
                self.finishRestore(state)
            }
        } else {
            finishRestore(state)
        }
    }

    /// The publishing half of a restore — runs only once every replay decision
    /// (live durable agents, Claude resume ids) is answerable synchronously.
    private func finishRestore(_ state: PersistedState) {
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
        peekCollapsedProjects = state.peekCollapsedProjects
        defaultIDEBundleID = state.defaultIDEBundleID
        windowsToOpen = windows.dropFirst().map(\.id)

        // A "remind me in 2 hours" that ran out while the app was closed is due
        // now, not in up to a minute — and it must not expire unnoticed.
        checkSnoozeExpiry()
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

        // `restoreLiveDurableIDs` was resolved in `applyRestore`, before any of
        // this state was published — so every surface built from here on (this
        // eager batch AND any the first SwiftUI render triggers) classifies its
        // agent correctly.
        createRestoredSurfaces()

        // After a grace period, new surfaces are ordinary terminals again.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            self.isRestoring = false
            self.restoreResumeIDs = [:]
            self.restoreLiveDurableIDs = []
        }

        reapOrphanedDurableSessions(keeping: Set(sessions.keys))
        // A notification click may have launched the app; with the restore now
        // asynchronous, the delegate's flush can run before the terminals
        // exist — flush again now that they do.
        flushPendingFocus()
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
        // Archive whatever is on disk before deleting it — not only a state we
        // decoded. A file that failed to decode (a downgrade, an unknown enum
        // case) and a workspace with projects but no live terminals both reach
        // `startFresh(archiving: nil)`; without this they vanish with no backup.
        // Keeping the file recoverable in state-previous.json is the safety net.
        if FileManager.default.fileExists(atPath: Self.stateURL.path) {
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
        peekCollapsedProjects = previous?.peekCollapsedProjects ?? peekCollapsedProjects
        defaultIDEBundleID = previous?.defaultIDEBundleID ?? defaultIDEBundleID
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

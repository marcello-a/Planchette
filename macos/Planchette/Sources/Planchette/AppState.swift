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
    /// What the pointer carries while a tab or a pane is being dragged — read by the drop
    /// zones to show where it would land, since the pasteboard answers only after the drop.
    @Published var draggingTabItem: TabDragItem?
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
    /// Ask "Restore your last session?" at every launch. Off by default: the last session comes
    /// back without a question — after an update, a crash or a plain quit.
    @Published var askBeforeRestore = false {
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
    /// How long a terminal keeps its done check before it goes back to free
    /// (Settings → Project panel). Applied by the housekeeping tick.
    @Published var doneExpiry: DoneExpiry = .default {
        didSet {
            scheduleSave()
            if doneExpiry != oldValue { expireDoneChecks() }
        }
    }
    /// Which extra details the project panel shows (Settings → Project panel).
    @Published var sidebarDetails = SidebarDetails() {
        didSet {
            scheduleSave()
            // The transcript reads run only while something shows them.
            if sidebarDetails != oldValue { refreshContextUsage() }
        }
    }

    func shows(_ detail: SidebarDetail) -> Bool { sidebarDetails.shows(detail) }
    /// The tags a terminal's Tags menu offers, in your order (Settings → Project
    /// panel → Tags). Starts as the four suggestions.
    @Published var tagList: [String] = TagList.defaults {
        didSet { scheduleSave() }
    }
    /// The keys that open the search from anywhere in the app (Settings → General).
    @Published var searchShortcut: SearchShortcut = .default {
        didSet {
            scheduleSave()
            searchShortcutMonitor.shortcut = searchShortcut
        }
    }
    /// What names a tab and what else it carries (Settings → Tabs).
    @Published var tabLayout = TabLayout() {
        didSet {
            scheduleSave()
            // The conversation's name is read out of the transcripts only while a tab shows it.
            if tabLayout.readsTranscripts != oldValue.readsTranscripts { refreshContextUsage() }
        }
    }
    /// Where a project's color shows and how strong it is (Settings → General → Project color).
    @Published var projectColor = ProjectColorLook() {
        didSet { scheduleSave() }
    }
    /// A terminal whose Claude still runs a shell or an agent in the background shows as running
    /// once its turn has ended: the turn is over, the work is not (Settings → Project panel →
    /// Behavior; `AttentionState.settled`). On by default.
    @Published var backgroundCountsAsRunning = true {
        didSet { scheduleSave() }
    }
    /// The notepad strip at the right of the tab: open or not, and how wide. Persisted.
    @Published var notepad = NotepadLook() {
        didSet { scheduleSave() }
    }
    /// What each terminal's notepad says. Deliberately not `@Published`: a keystroke in the pad
    /// must not redraw the window. Written to `TerminalSession.notepad` when the state is saved.
    private(set) var notepadText: [UUID: String] = [:]
    /// The notepad has the keyboard. A terminal that was just redrawn takes the keyboard when it
    /// is the active one (`focusIfActive`); while you type in the pad it must not.
    var notepadEditing = false
    /// What each terminal's notepad says, as the pad's text view reads it.
    func notepadText(for id: UUID) -> String { notepadText[id] ?? "" }

    func setNotepad(_ text: String, for id: UUID) {
        guard sessions[id] != nil, notepadText[id, default: ""] != text else { return }
        notepadText[id] = text.isEmpty ? nil : text
        scheduleSave()
    }

    /// The pad was just opened by hand and its text view should take the keyboard: you opened it
    /// to write. A pad that comes back with the workspace, or with another terminal, does not.
    /// Read once by the text view that appears (`NotepadEditor.makeNSView`).
    var notepadWantsKeyboard = false

    /// Open or close the pad of one terminal (the tab bar's button) — or, with no terminal named,
    /// of the one the key window shows (⌘J, the hint).
    func toggleNotepad(for id: UUID? = nil) {
        guard let id = id ?? keyTerminalID() else { return }
        let opening = !notepad.isOpen(for: id)
        notepadWantsKeyboard = opening
        if opening {
            completeHint(.notepad)      // used: it needs no introduction any more
        }
        notepad.setOpen(opening, for: id)
    }

    /// The terminal the key window shows: the active one of its selected project.
    func keyTerminalID() -> UUID? {
        guard let windowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id,
              let groupID = window(for: windowID)?.selectedGroupID,
              let group = groups.first(where: { $0.id == groupID }) else { return nil }
        let strip = tabs(of: group)
        let tab = group.activeSessionID.flatMap { TabStrip.index(of: $0, in: strip) }.map { strip[$0] }
        return tab.flatMap { paneToFocus(in: $0, groupID: groupID) } ?? group.activeSessionID
    }

    /// Put a line of the pad into the terminal's prompt, the way `session.prompt` does: a paste,
    /// and — with `submit` — a Return after it. The keyboard goes to the terminal: the line is in
    /// its prompt, and the next thing you do is edit it or press Return.
    func loadPrompt(_ text: String, into id: UUID, submit: Bool, onLoaded: (() -> Void)? = nil) {
        guard !text.isEmpty, let session = sessions[id] else { return }
        Task { @MainActor in
            guard let view = ControlAPI.liveView(for: session, state: self) else { return }
            // Run directly, and something is already typed in Claude Code's input: start a new line
            // (a line break inside a paste is a newline in the box, never Enter).
            let busy = submit && ClaudeInputDraft.hasDraft(in: view.readViewport() ?? "")
            await ControlAPI.deliverPrompt(busy ? "\n" + text : text, submit: submit, to: view, session: id)
            view.window?.makeFirstResponder(view)
            // Only now — the prompt is in the terminal — does the pad do what the setting says.
            onLoaded?()
        }
    }

    /// What the user has already been told: the welcome screen of a first launch and the
    /// durable terminals prompt after an update. Persisted — asking twice is nagging.
    @Published var onboarding = OnboardingState() {
        didSet { scheduleSave() }
    }
    /// The durable terminals prompt is up (see `evaluateOnboarding`).
    @Published var durablePromptShown = false
    private var onboardingEvaluated = false
    /// The IDE the "look at code" button always opens, once one is chosen in
    /// its menu. Nil = no choice made yet: the button falls back to whichever
    /// known IDE is running (see `IDEs.target`).
    @Published var defaultIDEBundleID: String? {
        didSet { scheduleSave() }
    }
    /// Whether the one question about the macOS Space setting has been asked
    /// (see `SpaceSwitchPrompt`). Persisted, because asking twice about a
    /// system preference the user declined is nagging.
    @Published var askedAboutSpaceSwitching = false {
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
            askBeforeRestore = saved.askBeforeRestore
            durableTerminals = saved.durableTerminals
            peekCollapsedProjects = saved.peekCollapsedProjects
            doneExpiry = saved.doneExpiry
            sidebarDetails = saved.sidebarDetails
            tagList = saved.tagList
            searchShortcut = saved.searchShortcut
            // Load the opt-in AI flag early too: a launch with a saved-but-
            // sessionless state runs startFresh(archiving: nil), which keeps the
            // *current* value — so without this a user's aiEnabled=false silently
            // flips back to the default and claude -p starts summarizing again.
            aiEnabled = saved.aiEnabled
            defaultIDEBundleID = saved.defaultIDEBundleID
            askedAboutSpaceSwitching = saved.askedAboutSpaceSwitching
            onboarding = saved.onboarding
            tabLayout = saved.tabLayout
            projectColor = saved.projectColor
            backgroundCountsAsRunning = saved.backgroundCountsAsRunning
            notepad = saved.notepad
            reviews = saved.reviews
        } else if !FileManager.default.fileExists(atPath: Self.stateURL.path) {
            // Not "a file that does not decode" (a downgrade): that is somebody's workspace.
            onboarding = .firstLaunch
        }
        observeSurfaceNotifications()
        _ = searchShortcutMonitor   // listening from the first moment
        startAttentionHousekeeping()
        startScreenDetection()
        startBranchPolling()
        startDevServerPolling()
        startPullRequestPolling()
        startReviewPolling()
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
        guard let app = NSApp else { return }
        let count = sessions.values.filter { $0.state.needsAttention && !isMuted($0) }.count
        let label = count > 0 ? "\(count)" : nil
        // Called after every state change and every minute: a dock tile that is
        // told the same label again still redraws, so only a real change is sent.
        guard label != lastDockBadge else { return }
        lastDockBadge = label
        app.dockTile.badgeLabel = label
    }

    private var lastDockBadge: String?

    /// Waiting/error longer than the threshold escalates exactly once per
    /// spell: favorites get a reminder notification, everything else only
    /// counts on in the badges. State changes reset the spell (see setState).
    private func attentionHousekeeping() {
        checkSnoozeExpiry()
        expireDoneChecks()
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

    /// A done check older than `doneExpiry` goes back to free — read or not,
    /// a turn that finished that long ago is no longer news. Only `ready`:
    /// a question or an error stays until it is answered.
    func expireDoneChecks(now: Date = Date()) {
        for session in sessions.values
        where session.state == .ready && doneExpiry.isExpired(since: session.stateSince, now: now) {
            setState(session.id, .free)
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
        // On the quiet ticks only the terminals that are asking are read: that is where a
        // slow answer costs something (a permission granted and the tool running, still
        // shown as a question), and there are few of them.
        let quietTick = NSApp?.isActive != true && !screenPollTick.isMultiple(of: 4)
        if quietTick && !sessions.values.contains(where: { $0.state == .waiting }) { return }
        reloadScreenRulesIfChanged()
        for (id, session) in sessions {
            if quietTick && session.state != .waiting { continue }
            let rules = screenRules.rules(for: session.agentKind)
            // Nothing to match against (e.g. a plain shell, or an agent whose
            // patterns aren't verified yet) → don't even read the surface.
            guard !rules.isEmpty else { continue }
            // Under hook authority the screen may raise a missed question and end
            // a turn nobody reported (see AttentionState.fromScreen) — for a
            // running or a waiting terminal, that is. An error it cannot change,
            // so skip the read there: it locks the renderer and dumps the
            // viewport, per terminal, on every tick. (A waiting terminal used to
            // be skipped too, which kept an Esc at a permission dialog from ever
            // being seen.)
            let hookAuthority = hasHookAuthority(id)
            guard AttentionState.screenRulesApply(
                hookAuthority: hookAuthority, durable: session.durable)
            else { continue }
            if hookAuthority && session.state == .error { continue }
            guard let view = TerminalRegistry.shared.existingView(id),
                  let text = view.readViewport()
            else { continue }
            // Claude Code names a long context window only in its banner
            // ("Opus 5.5 (1M context)"), never in the transcript — so the
            // viewport we already hold is where the ring learns its scale.
            if shows(.contextUsage), session.agentKind == .claude,
               let claudeID = session.claudeSessionID,
               !extendedContextSessions.contains(claudeID),
               ContextWindow.screenShowsExtended(text) {
                extendedContextSessions.insert(claudeID)
                refreshContextUsage()
            }
            let detection = ScreenDetector.detect(
                lines: text.components(separatedBy: "\n"), rules: rules)
            // A terminal held at running by its background work sits at an idle prompt on
            // purpose: that is not "a turn that ended without a hook", and "free" would be
            // undone at once anyway (`setState` settles it) — after rewriting the state its
            // turn is in, which the control API reads.
            if session.state == .running, heldByBackground[id] != nil, detection?.idlePrompt == true {
                screenConfirmation.forget(id)
                continue
            }
            let raised = screenRaisedIDs.contains(id)
            let newState = AttentionState.fromScreen(
                detection,
                agent: session.agentKind,
                hookAuthority: hookAuthority,
                current: session.state,
                raisedByScreen: raised)
            // Three readings move a terminal on the screen's word alone and must
            // hold on two polls in a row (see ScreenConfirmation): an idle
            // prompt over a turn the hooks call running, a question that
            // is no longer on the screen, and a question that was answered (the
            // footer of a live turn where the dialog was).
            let bold: ScreenConfirmation.Reading?
            if hookAuthority, session.state == .running, detection?.idlePrompt == true {
                bold = .idlePrompt
            } else if !hookAuthority, raised, session.state == .waiting, detection == nil {
                bold = .questionGone
            } else if hookAuthority, session.state == .waiting, detection?.state == .working {
                bold = .answered
            } else {
                bold = nil
            }
            if bold != nil {
                guard screenConfirmation.confirm(bold, for: id) else { continue }
                screenConfirmation.forget(id)
            } else {
                _ = screenConfirmation.confirm(nil, for: id)
            }
            guard let newState else { continue }
            // Without hooks the screen is the only one who can take its own
            // question back, so remember whose word the "waiting" is.
            if newState == .waiting && !hookAuthority { screenRaisedIDs.insert(id) }
            // No message: the screen knows a prompt is up, not what it asks.
            // Carrying the previous one over would show a stale question.
            setState(id, newState)
        }
    }

    /// Terminals whose `waiting` the screen raised (no hook did), which the
    /// screen may therefore end again.
    private var screenRaisedIDs: Set<UUID> = []
    private var screenConfirmation = ScreenConfirmation()

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

    /// Drag-and-drop: reorder the folders of a window.
    func moveFolder(_ id: UUID, before: UUID?, inWindow windowID: UUID) {
        updateWindow(windowID) { $0.moveFolder(id, before: before) }
    }

    /// Drag-and-drop in the project panel: put a terminal into project `groupID` as a tab of its
    /// own, before the tab of terminal `before` (nil = at the end). From another project it moves
    /// over first; a project it leaves empty closes, as when its tab is dragged away.
    func placeTerminal(_ id: UUID, inProject groupID: UUID, before target: UUID?) {
        guard let session = sessions[id], target != id else { return }
        if session.groupID != groupID { moveSession(id, to: groupID) }
        extractPane(id, before: target, groupID: groupID)
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
        guard branchFlight.begin() else { return }
        let dirs: [String: [UUID]] = sessions.values.reduce(into: [:]) { acc, session in
            guard !session.currentDirectory.isEmpty else { return }
            acc[session.currentDirectory, default: []].append(session.id)
        }
        guard !dirs.isEmpty else {
            if !branches.isEmpty { branches = [:] }
            _ = branchFlight.end()   // nothing was started, so nothing can be queued
            return
        }
        Task.detached {
            let found = dirs.reduce(into: [UUID: String]()) { found, entry in
                guard let branch = Worktrees.currentBranch(of: entry.key) else { return }
                for id in entry.value { found[id] = branch }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Publish only a real change: an unconditional assignment
                // invalidated every observing view on every poll tick.
                if self.branches != found {
                    // The PR of the branch a terminal left is not its PR any more:
                    // take it away now, not when `gh` answers for the new one.
                    let moved = PullRequests.movedSessions(from: self.branches, to: found)
                    if !moved.isEmpty {
                        var kept = self.pullRequests
                        for id in moved { kept[id] = nil }
                        if kept != self.pullRequests { self.pullRequests = kept }
                    }
                    // Tab names and tickets read the branch through a cache.
                    Titles.forgetBranches()
                    self.branches = found
                    // A new branch may already have a PR — do not make it wait
                    // a whole PR poll interval to show it.
                    self.refreshPullRequests()
                }
                if self.branchFlight.end() { self.refreshBranches() }
            }
        }
    }

    /// One branch poll at a time (see `SingleFlight`).
    private var branchFlight = SingleFlight()

    /// When `gitMayHaveChanged` last asked `gh` (see `PullRequests.eagerGap`).
    private var lastEagerPullRequestRefresh: Date?

    /// A command or an agent's turn just ended in a terminal: it may have switched
    /// the branch (`git checkout`, `git switch`) or made or changed a PR
    /// (`gh pr create`, `git push`). Look now rather than at the next poll. The
    /// branch is a local read; `gh` goes over the network, so it is asked at most
    /// once per `PullRequests.eagerGap` — a branch that did change asks anyway.
    func gitMayHaveChanged(now: Date = Date()) {
        refreshBranches()
        if PullRequests.eagerRefreshDue(last: lastEagerPullRequestRefresh, now: now) {
            lastEagerPullRequestRefresh = now
            refreshPullRequests()
        }
    }

    // MARK: Pull request per terminal

    /// The PR of each terminal's branch, keyed by session id. Derived and never
    /// persisted, like `branches`: GitHub is the truth. Empty without `gh`.
    @Published var pullRequests: [UUID: PullRequest] = [:]
    private var pullRequestTimer: Timer?
    private var pullRequestTicks = 0
    /// One `gh` call per checkout goes over the network, so this is slow on
    /// purpose; a review arriving a minute late is still news on time.
    static let pullRequestPollInterval: TimeInterval = 60

    private func startPullRequestPolling() {
        let timer = Timer(timeInterval: Self.pullRequestPollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pullRequestTicks += 1
                // In the background nobody reads a pill: a quarter of the rate.
                if NSApp?.isActive != true && !self.pullRequestTicks.isMultiple(of: 4) { return }
                self.refreshPullRequests()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pullRequestTimer = timer
        // In the background the poll slows to one sweep in four minutes; coming
        // back to the app is when a stale pill would be read.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.gitMayHaveChanged() }
        }
    }

    /// One `gh pr list` per distinct checkout + branch, off-main. Terminals on a
    /// trunk branch are skipped (see `PullRequests.trunkBranches`).
    func refreshPullRequests() {
        guard PullRequests.ghPath() != nil else { return }
        guard pullRequestFlight.begin() else { return }
        let checkouts: [String: (dir: String, branch: String, ids: [UUID])] =
            sessions.values.reduce(into: [:]) { acc, session in
                guard let branch = branches[session.id], PullRequests.isWorkBranch(branch),
                      !session.currentDirectory.isEmpty else { return }
                let key = "\(session.currentDirectory)\u{0}\(branch)"
                acc[key, default: (session.currentDirectory, branch, [])].ids.append(session.id)
            }
        guard !checkouts.isEmpty else {
            if !pullRequests.isEmpty { pullRequests = [:] }
            _ = pullRequestFlight.end()
            return
        }
        let asked = checkouts.values.reduce(into: [UUID: String]()) { acc, checkout in
            for id in checkout.ids { acc[id] = checkout.branch }
        }
        Task.detached {
            var found: [UUID: PullRequests.Lookup] = [:]
            for checkout in checkouts.values {
                let answer = PullRequests.lookup(branch: checkout.branch, in: checkout.dir)
                for id in checkout.ids { found[id] = answer }
            }
            let answers = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A terminal that switched branch while `gh` was asked keeps no
                // answer for the branch it left (the rerun asks for the new one),
                // and one whose lookup failed keeps the PR it showed.
                let result = PullRequests.merge(
                    answers: answers, asked: asked, branches: self.branches,
                    previous: self.pullRequests)
                if self.pullRequests != result { self.pullRequests = result }
                if self.pullRequestFlight.end() { self.refreshPullRequests() }
            }
        }
    }

    /// One `gh` sweep at a time: each lookup is a network call of up to 20s, so
    /// a slow connection used to stack a fresh sweep on every minute tick.
    private var pullRequestFlight = SingleFlight()

    // MARK: Review requests (state; the logic is in Reviews.swift)

    /// Every PR that asked for the user's review and what its review is up to,
    /// by PR URL. Persisted: the stage and the decisions are the user's own work.
    @Published var reviews: [String: ReviewRecord] = [:]
    /// The findings of each review, read from its `findings.json`. Derived from
    /// the files, never persisted.
    @Published var reviewFindings: [String: ReviewFindings] = [:]
    /// The checkouts a review could run in, per PR URL — gathered when its row opens.
    @Published var reviewCheckouts: [String: [ReviewRequests.Checkout]] = [:]
    /// When GitHub last answered; nil until the first answer.
    @Published var reviewsCheckedAt: Date?
    /// False when `gh` is missing or not logged in: the panel says how to fix it.
    @Published var reviewsReachable = true
    /// The row the panel should open — set by a banner click.
    @Published var reviewFocus: String?
    /// The last line a send or a start left for the user ("Review sent to …").
    @Published var reviewNotice: String?
    var reviewFlight = SingleFlight()
    var reviewTimer: Timer?
    var reviewWatchTimer: Timer?
    var reviewPolls = 0
    var reviewLastManualRefresh: Date?

    /// The PR a project row shows: the one its terminals share, like the branch.
    func sharedPullRequest(of group: SessionGroup) -> PullRequest? {
        let prs = sessions(in: group).map { pullRequests[$0.id] }
        guard let first = prs.first, let pr = first, prs.allSatisfy({ $0 == pr }) else { return nil }
        return pr
    }

    // MARK: Background tasks per terminal

    /// What each Claude terminal still runs in the background — shells started
    /// with `run_in_background`, agents launched without waiting — as its hooks
    /// report it (see `BackgroundTasks`). A terminal without any has no entry.
    /// Never persisted: the tasks are processes of a Claude that a restart
    /// ends, and the next hook says what is true.
    @Published private(set) var backgroundTasks: [UUID: [BackgroundTask]] = [:]

    /// The terminals shown as running only because of their background work
    /// (`AttentionState.settled`), with the idle state their turn is in: `ready` or `free`.
    /// The control API talks about the turn, not about the mark — prompting a terminal that
    /// sits at its prompt interrupts nothing, and a worker whose turn ended has answered.
    @Published private(set) var heldByBackground: [UUID: AttentionState] = [:]

    /// Whether this terminal is shown as running *only* because of its background work: its turn is
    /// over, so its icon is the globe, not the robot.
    func runsInBackground(_ session: TerminalSession) -> Bool {
        session.state == .running && heldByBackground[session.id] != nil
    }

    /// The state of the terminal's turn: what its hooks say, without the mark above.
    func turnState(of id: UUID) -> AttentionState? {
        heldByBackground[id] ?? sessions[id]?.state
    }

    private func applyBackground(_ signal: BackgroundTaskSignal, to id: UUID) {
        let before = backgroundTasks[id] ?? []
        let after = BackgroundTasks.apply(signal, to: before)
        // Equal writes stay no-ops: a `Stop` that repeats the list republishes nothing.
        guard after != before else { return }
        backgroundTasks[id] = after.isEmpty ? nil : after
    }

    // MARK: Context usage per terminal

    /// How full each Claude terminal's context window is, and its model, keyed
    /// by session id. Derived from the transcript tail (see
    /// `ContextUsageReader`), never persisted, and only read while the model or
    /// the context usage is switched on in Settings → Project panel.
    @Published var contextUsage: [UUID: ContextUsage] = [:]
    /// What each Claude terminal's conversation is about: the title Claude Code
    /// writes into its own transcript (`AgentTitle`), keyed by session id. Read
    /// in the same sweep as the usage above, never persisted — the transcript
    /// is the truth, and a title kept across a restart could name a
    /// conversation that is over.
    @Published var agentTitles: [UUID: String] = [:]
    /// Claude sessions whose terminal showed the "1M context" banner.
    private var extendedContextSessions: Set<String> = []
    /// Terminals whose agent ended (SessionEnd) — their transcript is history.
    private var endedAgentIDs: Set<UUID> = []
    /// Size and mtime of each transcript at its last read, so an idle session
    /// costs one stat per tick, not a 512 KB read.
    private var transcriptStamps: [String: String] = [:]
    private var transcriptScans: [String: TranscriptScan] = [:]

    /// Re-read the transcripts that changed and publish the usage and the
    /// conversation title of every Claude terminal. The file reads run off-main.
    func refreshContextUsage() {
        guard sidebarDetails.readsTranscripts || tabLayout.readsTranscripts else {
            forgetTranscriptReadings()
            return
        }
        let targets: [UUID: (path: String, claudeID: String?)] = sessions.reduce(into: [:]) { acc, entry in
            let session = entry.value
            guard session.agentKind == .claude, let path = session.transcriptPath,
                  !endedAgentIDs.contains(entry.key) else { return }
            acc[entry.key] = (path, session.claudeSessionID)
        }
        guard !targets.isEmpty else {
            forgetTranscriptReadings()
            return
        }
        guard contextFlight.begin() else { return }
        let stamps = transcriptStamps
        let known = transcriptScans
        let extended = extendedContextSessions
        Task.detached {
            let configured = ContextWindow.configuredModel()
            var newStamps = stamps
            var scanByPath = known
            let livePaths = Set(targets.values.map(\.path))
            for path in livePaths {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let stamp = "\((attrs?[.size] as? Int) ?? -1)-\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                guard newStamps[path] != stamp else { continue }
                newStamps[path] = stamp
                scanByPath[path] = ContextUsageReader.scan(path: path)
            }
            // Every Claude conversation is a new transcript path. Keeping the
            // readings of conversations that are over would grow these two
            // tables, and the copy made on every tick, for as long as the app
            // runs.
            newStamps = newStamps.filter { livePaths.contains($0.key) }
            scanByPath = scanByPath.filter { livePaths.contains($0.key) }
            let titles: [UUID: String] = targets.reduce(into: [:]) { acc, entry in
                acc[entry.key] = scanByPath[entry.value.path]?.title
            }
            let found: [UUID: ContextUsage] = targets.reduce(into: [:]) { acc, entry in
                guard let usage = scanByPath[entry.value.path]?.usage else { return }
                let window = ContextWindow.size(
                    usedTokens: usage.usedTokens,
                    sawExtendedBanner: entry.value.claudeID.map(extended.contains) ?? false,
                    configuredModel: configured)
                acc[entry.key] = ContextUsage(
                    model: usage.model, usedTokens: usage.usedTokens, windowTokens: window,
                    cacheTouchedAt: usage.at,
                    cacheTTL: usage.cacheTTL ?? PromptCache.defaultTTL)
            }
            let stampsNow = newStamps, scansNow = scanByPath
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.transcriptStamps = stampsNow
                self.transcriptScans = scansNow
                if self.contextUsage != found { self.contextUsage = found }
                if self.agentTitles != titles { self.agentTitles = titles }
                // A Stop hook asks for a fresh reading *because* the transcript
                // just changed: a request that arrived mid-run gets its own run.
                if self.contextFlight.end() { self.refreshContextUsage() }
            }
        }
    }

    /// What the line under a terminal says it works on: the source chosen in
    /// Settings → Project panel, and the last prompt whenever that source has
    /// nothing to say. A row that falls blank because a conversation has no
    /// title yet, or because this one was resumed and never got a first prompt
    /// from us, would be worse than one that repeats itself.
    ///
    /// Here rather than in the row because two views draw it, and because the
    /// choice behind it lives here. It is deliberately *not* what the control
    /// API hands out: `task` there is the last prompt, by contract
    /// (docs/API.md), and a setting in this app must not change what another
    /// program reads.
    func rowPrompt(for session: TerminalSession, max: Int = 48) -> String? {
        let chosen: String? = switch sidebarDetails.promptSource {
        case .firstPrompt: session.firstTask
        case .lastPrompt: session.currentTask
        case .agentTitle: agentTitles[session.id]
        }
        return (chosen ?? session.currentTask).flatMap { Titles.taskLabel($0, max: max) }
    }

    /// What a tab (and a cluster tile, and a project overview card) calls a terminal:
    /// the source chosen in Settings → Tabs, the manual name above all of them.
    ///
    /// Deliberately *not* what the control API hands out as `title`: that is the
    /// ticket-and-task name by contract (docs/API.md), and a setting in this app must
    /// not change what another program reads.
    func tabName(for session: TerminalSession) -> String {
        TabNaming.name(
            TabNaming.Inputs(
                customTitle: session.customTitle,
                conversationTitle: agentTitles[session.id],
                aiSummary: session.aiSummary,
                firstPrompt: session.firstTask,
                lastPrompt: session.currentTask,
                reportedTitle: session.reportedTitle,
                // A filesystem probe: only for the one name that uses it.
                ticket: tabLayout.name == .ticketAndPrompt ? session.ticket : nil,
                fallback: session.fallbackTitle),
            source: tabLayout.name)
    }

    /// Drop everything the transcripts told us — nothing is being read any more,
    /// so nothing may keep standing in a row.
    private func forgetTranscriptReadings() {
        if !contextUsage.isEmpty { contextUsage = [:] }
        if !agentTitles.isEmpty { agentTitles = [:] }
    }

    /// One transcript sweep at a time (see `SingleFlight`).
    private var contextFlight = SingleFlight()

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
    /// Which IDEs already have each project open, keyed by group id. The
    /// strongest evidence there is: then the button's job is to take you to a
    /// window that exists, not to open one.
    @Published private(set) var projectOpenInIDEs: [UUID: Set<String>] = [:]
    /// Whether each dev-server port speaks TLS, keyed by port. Asked once per
    /// port (see `DevServerScanner.probeScheme`) — a chip that guesses `http`
    /// for an `https` server opens a page that never answers.
    fileprivate var serverSchemes: [Int: String] = [:]
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
        // Same cadence: a stat per transcript, a read only when one grew.
        refreshContextUsage()
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
        guard devServerFlight.begin() else { return }
        let knownSchemes = serverSchemes
        Task.detached {
            // Nil: `lsof` did not finish. Everything below that depends on its
            // answer is left as it was rather than blanked for one tick.
            let scanned = DevServerScanner.scan(projectDirs: dirs)
            let scanFinished = scanned != nil
            let found = scanned ?? [:]
            let markers = projectDirs.mapValues { IDEs.markers(in: $0) }
            let installed = IDEs.installed()
            // Ask each new port whether it speaks TLS. Off-main and once per
            // port: the answer cannot change while the server runs.
            var schemes = knownSchemes
            for port in Set(found.values.flatMap { $0.map(\.port) }) where schemes[port] == nil {
                schemes[port] = DevServerScanner.probeScheme(port: port)
            }
            // Which IDE already shows each project — read from the IDEs' own
            // state files, so it costs no permission and no window peeking.
            let openProjects = installed.reduce(into: [String: Set<String>]()) {
                $0[$1.bundleID] = IDEs.openProjects(of: $1)
            }
            let openIn = projectDirs.mapValues { dir in
                Set(openProjects.filter { $0.value.contains(dir) }.keys)
            }
            await MainActor.run { [weak self] in
                self?.serverSchemes = schemes
                guard let self else { return }
                if self.ideMarkers != markers { self.ideMarkers = markers }
                if self.installedIDEs != installed { self.installedIDEs = installed }
                if self.projectOpenInIDEs != openIn { self.projectOpenInIDEs = openIn }
                if scanFinished {
                    // Carry over (and complete) the announced URLs before comparing:
                    // the addresses are part of what a chip shows, so resolving one
                    // has to publish.
                    let withURLs = self.resolvingServerURLs(found)
                    // Publish only a real change (see refreshBranches).
                    if self.devServers != withURLs { self.devServers = withURLs }
                }
                if self.devServerFlight.end() { self.refreshDevServers() }
            }
        }
    }

    /// One dev-server sweep at a time (see `SingleFlight`): it runs `lsof`, whose
    /// cost grows with the machine's open sockets.
    private var devServerFlight = SingleFlight()

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
                // What the server announced, else at least the right scheme:
                // the port was probed, and `https://localhost:8082` is a page,
                // while `http://localhost:8082` on a TLS server is not.
                server.resolvedURL = serverURLs[$0.port]
                    ?? URL(string: "\(serverSchemes[$0.port] ?? "http")://localhost:\($0.port)")
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
            lastActivated: lastActivatedIDE,
            alreadyOpenIn: projectOpenInIDEs[group.id] ?? [])
    }

    /// Is this project already open in the IDE a click would go to? Then the
    /// button takes you to a window instead of opening one — which is what its
    /// tooltip should say.
    func ideAlreadyOpen(_ group: SessionGroup, in ide: IDE) -> Bool {
        projectOpenInIDEs[group.id]?.contains(ide.bundleID) ?? false
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
    ///
    /// `activeOnly` keeps what is waiting or failed, and the finished terminals whose done
    /// check has not cleared yet; running ones too with `includeRunning`
    /// (`AttentionState.isCurrent`).
    func notificationSections(
        windowID: UUID? = nil, unreadOnly: Bool = false, activeOnly: Bool = false,
        includeRunning: Bool = false, now: Date = Date()
    ) -> [(group: SessionGroup, sessions: [TerminalSession])] {
        let ordered = windows.sorted { a, _ in a.id == windowID }
        var out: [(group: SessionGroup, sessions: [TerminalSession])] = []
        for window in ordered {
            let inWindow = groups(inWindow: window).filter(\.active)
            for group in inWindow.filter(\.favorite) + inWindow.filter({ !$0.favorite }) {
                var tabs = sessions(in: group)
                if activeOnly {
                    tabs = tabs.filter {
                        $0.state.isCurrent(
                            since: $0.stateSince, expiry: doneExpiry, now: now, includeRunning: includeRunning)
                    }
                }
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
            // Bring the strip up to date first: the new terminal is then a tab of its own.
            groups[idx].tabs = TabStrip.synced(groups[idx].tabs, to: groups[idx].sessionIDs)
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
        notepadText[id] = nil
        finds[id] = nil
        findTasks[id]?.cancel()
        findTasks[id] = nil
        liveAgentIDs.remove(id)
        backgroundTasks[id] = nil
        if heldByBackground[id] != nil { heldByBackground[id] = nil }
        screenRaisedIDs.remove(id)
        screenConfirmation.forget(id)
        escalatedIDs.remove(id)
        aiAssist.forget(id)
        if let idx = groups.firstIndex(where: { $0.id == session.groupID }) {
            takeOut(id, ofGroupAt: idx)
            if groups[idx].sessionIDs.isEmpty {
                groups.remove(at: idx)
                sanitizeWindows()
            }
        }
        refreshDockBadge()
        scheduleSave()
    }

    /// Leave a terminal out of a project's strip. When it was the one in front, the one
    /// beside it takes over: its neighbour pane, else the next tab, else the previous one.
    private func takeOut(_ id: UUID, ofGroupAt idx: Int) {
        let strip = TabStrip.synced(groups[idx].tabs, to: groups[idx].sessionIDs)
        let next = TabStrip.successor(of: id, in: strip)
        groups[idx].sessionIDs.removeAll { $0 == id }
        let rest = TabStrip.removing(id, from: strip)
        groups[idx].tabAnchors = TabStrip.carriedAnchors(
            old: strip, oldAnchors: groups[idx].tabAnchors, new: rest, preferring: nil)
        groups[idx].tabs = rest
        if groups[idx].activeSessionID == id {
            groups[idx].activeSessionID = next ?? groups[idx].sessionIDs.last
        }
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
        // Shown after an `await`, i.e. from inside the main queue: see `ModalAlert`.
        ModalAlert.show(alert)
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
        removeWorktree(path: path, repoRoot: repoRoot)
    }

    /// `git worktree remove`, off-main; a refusal is shown, never forced. A branch
    /// to delete goes only after the checkout is gone: git keeps a checked-out
    /// branch. It is the review's own branch, so `-D` deletes it unmerged.
    func removeWorktree(path: String, repoRoot: String, deletingBranch branch: String? = nil) {
        Task { [weak self] in
            let error: Error? = await Task.detached {
                do {
                    try Worktrees.remove(path: path, repoRoot: repoRoot)
                    if let branch {
                        _ = try? Worktrees.git(["branch", "-D", branch], in: repoRoot)
                    }
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error { self?.presentWorktreeFailure(error) }
        }
    }

    /// What closing a worktree project does with its checkout.
    enum WorktreeOnClose {
        /// Ask, the default: the checkout may hold work.
        case ask
        /// Remove it without asking — a review's temporary worktree, whose work
        /// is on GitHub — and then the local branch the review made in it. Git
        /// still refuses while there are uncommitted changes.
        case remove(deletingBranch: String?)
    }

    /// Close a whole project: free its terminals' surfaces, drop its sessions,
    /// remove the group, and repair window group lists and selection.
    func closeGroup(_ groupID: UUID, worktree: WorktreeOnClose = .ask) {
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
            backgroundTasks[sid] = nil
            screenRaisedIDs.remove(sid)
            screenConfirmation.forget(sid)
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
            switch worktree {
            case .ask: offerWorktreeRemoval(path: path, repoRoot: root)
            case .remove(let branch): removeWorktree(path: path, repoRoot: root, deletingBranch: branch)
            }
        }
    }

    /// Reorder terminals within a group: place `dragged` right before `target`.

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

    // MARK: Tabs and their splits

    /// The strip of a project, in step with its terminals: a terminal that was added or closed
    /// since the strip was stored is already accounted for.
    func tabs(of group: SessionGroup) -> [SplitLayout] {
        TabStrip.synced(group.tabs, to: group.sessionIDs)
    }

    /// The tab that is in front: the one holding the terminal that has the keyboard.
    func currentTab(of group: SessionGroup) -> SplitLayout? {
        let strip = tabs(of: group)
        if let active = group.activeSessionID, let at = TabStrip.index(of: active, in: strip) {
            return strip[at]
        }
        return strip.first
    }

    /// Store a rearranged strip. The terminals must be the same ones: anything else is a
    /// bug in the caller and changes nothing. `sessionIDs` follows, so the sidebar lists the
    /// terminals in the order the tabs show them.
    @discardableResult
    private func applyTabs(_ tabs: [SplitLayout]?, to groupID: UUID, target: UUID? = nil) -> Bool {
        guard let tabs, let group = groups.first(where: { $0.id == groupID }),
              Set(TabStrip.order(tabs)) == Set(group.sessionIDs),
              TabStrip.order(tabs).count == group.sessionIDs.count
        else { return false }
        // Every tab keeps the name it had; a terminal that was moved into a tab does not rename it.
        let anchors = TabStrip.carriedAnchors(
            old: self.tabs(of: group), oldAnchors: group.tabAnchors, new: tabs, preferring: target)
        updateGroup(groupID) {
            $0.tabs = tabs
            $0.tabAnchors = anchors
            $0.sessionIDs = TabStrip.order(tabs)
        }
        return true
    }

    /// The terminal that speaks for a tab: its name is the tab's name.
    func speaker(of tab: SplitLayout, in group: SessionGroup) -> TerminalSession? {
        TabStrip.speaker(of: tab, anchors: group.tabAnchors).flatMap { sessions[$0] }
    }

    /// Drag a tab before another (`before` is a tab's first terminal) or to the end (`nil`).
    func moveTab(_ tab: UUID, before target: UUID?, groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let strip = tabs(of: group)
        guard let from = TabStrip.index(of: tab, in: strip) else { return }
        let to = target.flatMap { TabStrip.index(of: $0, in: strip) } ?? strip.count
        applyTabs(TabStrip.moveTab(from: from, before: to, in: strip), to: groupID)
    }

    /// The strip a tab dropped on a pane's edge would leave — nil when the drop is invalid or
    /// changes nothing. The drop zones ask before they light up.
    func dropTabResult(_ tab: UUID, onto target: UUID, edge: LayoutEdge, groupID: UUID) -> [SplitLayout]? {
        guard let group = groups.first(where: { $0.id == groupID }) else { return nil }
        let strip = tabs(of: group)
        guard let from = TabStrip.index(of: tab, in: strip) else { return nil }
        return TabStrip.dropTab(at: from, onto: target, edge: edge, in: strip)
    }

    func dropTab(_ tab: UUID, onto target: UUID, edge: LayoutEdge, groupID: UUID) {
        applyTabs(dropTabResult(tab, onto: target, edge: edge, groupID: groupID), to: groupID, target: target)
    }

    func dropPaneResult(_ pane: UUID, onto target: UUID, edge: LayoutEdge, groupID: UUID) -> [SplitLayout]? {
        guard let group = groups.first(where: { $0.id == groupID }) else { return nil }
        return TabStrip.dropPane(pane, onto: target, edge: edge, in: tabs(of: group))
    }

    func dropPane(_ pane: UUID, onto target: UUID, edge: LayoutEdge, groupID: UUID) {
        applyTabs(dropPaneResult(pane, onto: target, edge: edge, groupID: groupID), to: groupID, target: target)
    }

    /// Take a pane out to a tab of its own, before the tab whose first terminal is `target`
    /// (the end of the strip when nil).
    func extractPane(_ pane: UUID, before target: UUID?, groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let strip = tabs(of: group)
        let to = target.flatMap { TabStrip.index(of: $0, in: strip) } ?? strip.count
        applyTabs(TabStrip.extractPane(pane, before: to, in: strip), to: groupID)
        updateGroup(groupID) { $0.activeSessionID = pane }
    }

    /// All tabs of a project in one view, as a grid.
    func combineTabs(groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        applyTabs(TabStrip.combined(tabs(of: group)), to: groupID)
    }

    /// Every pane its own tab again.
    func separateTabs(groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        applyTabs(TabStrip.separated(tabs(of: group)), to: groupID)
    }

    /// iTerm2's ⌘D and ⌘⇧D: a new terminal in the project's folder, split off the one that has
    /// the keyboard — to its right, or below it. In a project that has no terminal it is just
    /// the first one.
    func splitTerminal(in groupID: UUID, edge: LayoutEdge) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        guard let anchor = group.activeSessionID.flatMap({ sessions[$0] }) ?? sessions(in: group).first else {
            addTerminalToGroup(groupID)
            return
        }
        let directory = [anchor.currentDirectory, anchor.workingDirectory]
            .first { !$0.isEmpty } ?? FileManager.default.homeDirectoryForCurrentUser.path
        let created = addSession(directory: directory, groupID: groupID, activate: false)
        if let stored = groups.first(where: { $0.id == groupID }) {
            applyTabs(
                TabStrip.dropPane(created.id, onto: anchor.id, edge: edge, in: tabs(of: stored)),
                to: groupID, target: anchor.id)
        }
        select(session: created)
    }

    /// The terminal in the pane that was clicked or focused has the keyboard: it is the
    /// project's active terminal. Does not raise a window or switch project — it follows
    /// where the user already is.
    func focusPane(_ id: UUID) {
        guard let session = sessions[id] else { return }
        rememberFocus(id, in: session.groupID)
        updateGroup(session.groupID) { $0.activeSessionID = id }
    }

    /// Which pane of a tab has the keyboard when you come back to it: the one that had it
    /// last, as in iTerm2. Not persisted — after a restart a tab opens on its first pane.
    private var focusHistory: [UUID: [UUID]] = [:]

    private func rememberFocus(_ id: UUID, in groupID: UUID) {
        var history = focusHistory[groupID] ?? []
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
        focusHistory[groupID] = Array(history.prefix(64))
    }

    /// The pane of `tab` that gets the keyboard when the tab comes to the front.
    func paneToFocus(in tab: SplitLayout, groupID: UUID) -> UUID? {
        let leaves = tab.leaves
        if let active = groups.first(where: { $0.id == groupID })?.activeSessionID, leaves.contains(active) {
            return active
        }
        return focusHistory[groupID]?.first { leaves.contains($0) } ?? leaves.first
    }

    /// ⌘D and ⌘⇧D: split the project the key window shows.
    func splitInKeyWindow(edge: LayoutEdge) {
        guard let windowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id,
              let groupID = window(for: windowID)?.selectedGroupID,
              groups.contains(where: { $0.id == groupID }) else { return }
        splitTerminal(in: groupID, edge: edge)
    }

    /// Whether this terminal is on screen: in the tab in front of the selected project —
    /// every pane of a split tab is — in a window that is actually visible.
    func isVisible(_ id: UUID) -> Bool {
        guard let session = sessions[id],
              let group = groups.first(where: { $0.id == session.groupID }),
              currentTab(of: group)?.leaves.contains(id) == true,
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
        rememberFocus(session.id, in: session.groupID)
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

    /// A click on a project's own row: its overview page — every terminal as a card — or, when the
    /// project holds a single terminal, that terminal. The page would be one card between you and
    /// the terminal (`WindowModel.opensOverview`).
    func openProject(_ group: SessionGroup, inWindow windowID: UUID) {
        let terminals = sessions(in: group)
        if WindowModel.opensOverview(terminalCount: terminals.count) {
            updateWindow(windowID) { $0.showProjectOverview(group.id) }
        } else if let only = terminals.first {
            select(session: only)
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

    /// What the search knows about every terminal right now. A snapshot: the
    /// switcher takes one when it opens and ranks against it, so a state change
    /// while it is open cannot reorder the list under the user's hand.
    func searchEntries() -> [SearchEntry] {
        sessions.values.map { session in
            let pullRequest = pullRequests[session.id]
            return SearchEntry(
                id: session.id,
                title: session.displayTitle,
                project: group(of: session)?.name ?? "",
                // The cached branch — never a filesystem walk per terminal per keystroke.
                branch: branches[session.id] ?? "",
                path: session.currentDirectory,
                tags: session.tags,
                note: session.note ?? "",
                task: session.currentTask ?? "",
                summary: session.aiSummary ?? "",
                message: session.lastMessage ?? "",
                pullRequest: pullRequest?.number,
                pullRequestTitle: pullRequest?.title ?? "",
                background: backgroundTasks[session.id]?.map(\.title) ?? [],
                urgency: searchUrgency(session),
                stateSince: session.stateSince)
        }
    }

    /// An error or a question first, in a favorite project before any other, then the
    /// favorites, then the rest — the order the switcher has always opened in.
    private func searchUrgency(_ session: TerminalSession) -> Int {
        let favorite = group(of: session)?.favorite == true
        switch (session.state, favorite) {
        case (.error, true): return 6
        case (.waiting, true): return 5
        case (.error, false): return 4
        case (.waiting, false): return 3
        default: return favorite ? 1 : 0
        }
    }

    /// The keys that open the search, for a tooltip: the one Settings holds, and ⌘K, which
    /// the menu keeps whatever Settings says.
    var searchShortcutLabels: String {
        let menu = SearchShortcut.chord(key: "k", modifiers: [.command])
        return searchShortcut == menu ? menu.label : "\(searchShortcut.label) · \(menu.label)"
    }

    /// Watches for the search shortcut (Settings → General); see `SearchShortcutMonitor`.
    private(set) lazy var searchShortcutMonitor = SearchShortcutMonitor(shortcut: searchShortcut) { [weak self] in
        self?.searchShortcutPressed()
    }

    /// The shortcut opens the search over the window you are in, and the same keys
    /// close it again. From Settings, or with no window in front, there is nothing to
    /// search from: it does nothing.
    func searchShortcutPressed() {
        if quickSwitcherWindowID != nil {
            quickSwitcherWindowID = nil
        } else if WindowRegistry.shared.keyWindowID() != nil {
            showQuickSwitcher()
        }
    }

    // MARK: Find in a terminal (⌘F)

    /// The find bar of every terminal that has one open, and what it knows.
    @Published private(set) var finds: [UUID: TerminalFind] = [:]
    private var findTasks: [UUID: Task<Void, Never>] = [:]

    /// Who searches: libghostty looks through its own scrollback, but a durable
    /// terminal runs inside tmux, whose history it never sees — there tmux's copy
    /// mode does the searching, and highlights the matches itself.
    private func searchesInTmux(_ session: TerminalSession) -> Bool {
        session.durable && Durable.isAvailable
    }

    private func surfaceView(of id: UUID) -> GhosttySurfaceNSView? {
        sessions[id].flatMap { TerminalRegistry.shared.view(for: $0, appState: self) } as? GhosttySurfaceNSView
    }

    /// The terminal ⌘F means: the one the key window shows, when it shows one.
    func findTargetID() -> UUID? {
        guard let windowID = WindowRegistry.shared.keyWindowID() ?? windows.first?.id,
              let window = window(for: windowID), window.selectedFolderID == nil,
              !window.showsProjectOverview, let groupID = window.selectedGroupID,
              let group = groups.first(where: { $0.id == groupID })
        else { return nil }
        if let active = group.activeSessionID, sessions[active] != nil { return active }
        return group.sessionIDs.first { sessions[$0] != nil }
    }

    /// ⌘F: open the find bar over this terminal — or, when it is open, take the keyboard
    /// back into it.
    func startFind(in id: UUID) {
        guard let session = sessions[id] else { return }
        guard finds[id] != nil else {
            finds[id] = TerminalFind()
            if !searchesInTmux(session) { surfaceView(of: id)?.startSearch() }
            return
        }
        finds[id]?.focusRequests += 1
    }

    /// The text in the field changed.
    func updateFind(_ needle: String, in id: UUID) {
        guard let session = sessions[id], finds[id] != nil, finds[id]?.needle != needle else { return }
        finds[id]?.needle = needle
        findTasks[id]?.cancel()
        findTasks[id] = nil
        if searchesInTmux(session) {
            guard !needle.isEmpty else {
                finds[id]?.total = nil
                Task.detached { Durable.endSearch(in: id) }
                return
            }
            // One tmux call per pause in the typing, not per key: it is a process each.
            findTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                let total = await Task.detached { Durable.search(needle, in: id) }.value
                guard !Task.isCancelled, let self, self.finds[id]?.needle == needle else { return }
                self.finds[id]?.total = total
            }
        } else {
            if needle.isEmpty {
                finds[id]?.total = nil
                finds[id]?.selected = nil
            }
            surfaceView(of: id)?.search(needle)
        }
    }

    /// Enter / ⌘G steps to the next match, ⇧Enter / ⌘⇧G to the previous one. "Next" is
    /// the order the search presents them in: tmux starts at the newest line and goes
    /// back, so its next match is the older one.
    func stepFind(in id: UUID, forward: Bool) {
        guard let session = sessions[id], let find = finds[id], !find.needle.isEmpty else { return }
        if searchesInTmux(session) {
            Task.detached { Durable.step(older: forward, in: id) }
        } else {
            surfaceView(of: id)?.navigateSearch(next: forward)
        }
    }

    /// Esc or the close button: the bar goes, the highlights with it, and the keyboard
    /// goes back to the terminal.
    func endFind(in id: UUID) {
        findTasks[id]?.cancel()
        findTasks[id] = nil
        guard finds[id] != nil else { return }
        finds[id] = nil
        if let session = sessions[id] {
            if searchesInTmux(session) {
                Task.detached { Durable.endSearch(in: id) }
            } else {
                surfaceView(of: id)?.endSearch()
            }
            focusTerminal(id)
        }
    }

    private func focusTerminal(_ id: UUID) {
        guard let view = surfaceView(of: id), let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    /// The menu: Find…, Find Next, Find Previous.
    func findInKeyWindow() {
        if let id = findTargetID() { startFind(in: id) }
    }

    func findNextInKeyWindow(forward: Bool) {
        guard let id = findTargetID() else { return }
        if finds[id] == nil { startFind(in: id) } else { stepFind(in: id, forward: forward) }
    }

    /// What libghostty says about the search of a plain terminal.
    func applySearchEvent(_ event: String, for id: UUID, value: Int?, needle: String?) {
        switch event {
        case "start":
            if finds[id] == nil { finds[id] = TerminalFind(needle: needle ?? "") }
        case "end":
            if finds[id] != nil {
                finds[id] = nil
                focusTerminal(id)
            }
        case "total":
            finds[id]?.total = (value ?? -1) >= 0 ? value : nil
        case "selected":
            // libghostty counts from 0.
            finds[id]?.selected = (value ?? -1) >= 0 ? (value ?? 0) + 1 : nil
        default:
            break
        }
    }

    // MARK: Onboarding

    /// Once, when the main window is up: is the durable terminals prompt due? It is shown
    /// after an update to somebody who has no durable terminals and did not ask us to stop
    /// (`OnboardingState.durablePromptDue`). The running version is recorded either way, so
    /// the prompt belongs to one update and never to every launch.
    ///
    /// Never in an isolated instance: that is a demo or a test, handed its workspace on
    /// purpose, and a sheet over it would stop whatever drives it.
    func evaluateOnboarding() {
        guard !onboardingEvaluated else { return }
        onboardingEvaluated = true
        let version = OnboardingState.runningVersion
        let due = onboarding.durablePromptDue(
            runningVersion: version, durableOn: durableTerminals && Durable.isAvailable)
        onboarding.lastLaunchedVersion = version
        if due, !SupportPaths.isIsolated { durablePromptShown = true }
    }

    /// The first project exists: the welcome screen has done its job.
    func markWelcomeSeen() {
        if !onboarding.welcomeSeen { onboarding.welcomeSeen = true }
    }

    // MARK: Feature hints

    /// The hint that is open now, if any. Session only: whether one is due again is `HintBook`.
    @Published var hintShowing: FeatureHint?
    /// Offered in this run already: a hint that was closed is not offered again until the next launch.
    private var hintsOffered: Set<FeatureHint> = []

    /// Offer a hint, at the moment the user does something that makes it useful. Quiet when it is
    /// not the time: before the window is up, over the durable terminals prompt, while another
    /// hint is open, in an isolated instance, once it was offered or its feature was used, or
    /// after "Don't show this again". The caller needs no checks of its own.
    func offerHint(_ hint: FeatureHint) {
        guard onboardingEvaluated, !SupportPaths.isIsolated, !durablePromptShown, hintShowing == nil,
              !hintsOffered.contains(hint), onboarding.hints.isDue(hint) else { return }
        hintsOffered.insert(hint)
        hintShowing = hint
    }

    /// The feature was used: its hint is done for good, and closes if it is open.
    func completeHint(_ hint: FeatureHint) {
        if onboarding.hints.done.insert(hint.rawValue).inserted { scheduleSave() }
        if hintShowing == hint { hintShowing = nil }
    }

    func closeHint() { hintShowing = nil }

    /// "Don't show this again": a setting, applied the moment it is ticked.
    func hideHints(_ hide: Bool) {
        if onboarding.hints.hidden != hide { onboarding.hints.hidden = hide }
    }

    /// A terminal was opened by the user (⌘T, the + button, a new project): the moment to mention
    /// what a terminal can do. Never called while a workspace is restored.
    func userOpenedTerminal() {
        offerHint(.notepad)
    }

    func closeDurablePrompt() {
        durablePromptShown = false
    }

    /// The prompt's "Don't show this again": a setting, applied the moment it is ticked.
    func hideDurablePrompt(_ hide: Bool) {
        if onboarding.durablePromptHidden != hide { onboarding.durablePromptHidden = hide }
    }

    /// Focusing a terminal does NOT clear its attention state — a glance isn't
    /// an answer. `waiting`/`error` persist until the agent moves on (a hook or
    /// command result) or the user explicitly marks it free ("nothing for me
    /// here") — which is what the context-menu action means.
    func markReady(_ id: UUID) {
        setState(id, .free, settle: false)
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

    /// OSC 133: the last shell command finished — the foreground job is over and
    /// the shell is at its prompt. The exit code decides the state: non-zero →
    /// error (red), Ctrl+C → free, otherwise ready (green), whatever the terminal
    /// showed before (see `AttentionState.afterCommandFinish`).
    ///
    /// Hooks that still call an agent live here are stale then: it was killed or
    /// crashed and could not say SessionEnd, or its last hooks arrived out of
    /// order. The prompt is the better witness, so that session ends now — its
    /// task, context ring and background tasks go with it. Should the agent turn
    /// out to run (in the background, say), its next hook brings it all back.
    func commandFinished(_ id: UUID, exitCode: Int) {
        guard let session = sessions[id] else { return }
        if liveAgentIDs.contains(id) {
            applyHookEvent(
                sessionID: id, hookEvent: "SessionEnd", claudeSessionID: nil,
                transcriptPath: nil, message: nil, agent: session.agentKind,
                background: .reset)
        }
        setState(id, AttentionState.afterCommandFinish(exitCode: exitCode))
        gitMayHaveChanged()
    }

    private func setState(_ id: UUID, _ requested: AttentionState, message: String? = nil, settle: Bool = true) {
        // A turn that ended while the terminal still runs a shell or an agent in the background is
        // not done, and an idle prompt on its screen is not "free": the terminal keeps showing what
        // is true (`AttentionState.settled`). Every writer comes through here — a hook, the screen,
        // a finished command — so none of them can undo it. What you decide yourself ("Mark as
        // done") is not a reading of the terminal, and passes as it is.
        let state = settle && backgroundCountsAsRunning
            ? requested.settled(hasBackgroundWork: !(backgroundTasks[id] ?? []).isEmpty)
            : requested
        // Only a real change is written: the icon follows this, and it is published.
        let held: AttentionState? = state == requested ? nil : requested
        if heldByBackground[id] != held { heldByBackground[id] = held }
        if state != .waiting { screenRaisedIDs.remove(id) }
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

    /// An agent (Claude Code, Codex) is alive in this terminal, idle or not.
    func isAgentLive(_ id: UUID) -> Bool { liveAgentIDs.contains(id) }

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
        agent: AgentKind = .claude,
        background: BackgroundTaskSignal? = nil
    ) {
        guard sessions[sessionID] != nil else { return }
        if let background { applyBackground(background, to: sessionID) }
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
        // The submitted prompt is the task this terminal works on from now on —
        // unless it is Claude Code's own "a background task ended" notice, which
        // reaches the hook as a prompt but says nothing about the work.
        if hookEvent == "UserPromptSubmit",
           let task = prompt.flatMap({ BackgroundTasks.isNotification($0) ? nil : $0 })
               .flatMap(TerminalSession.taskLine(fromPrompt:)) {
            update(sessionID) {
                $0.currentTask = task
                // The assignment is the first prompt of *this* conversation —
                // whatever is there already belongs to it, not to a new one.
                if $0.firstTask == nil { $0.firstTask = task }
            }
        }
        // Context usage follows the agent: gone when it ends, back (and read
        // at once) on anything else — a finished turn is when it changed.
        if hookEvent == "SessionEnd" {
            endedAgentIDs.insert(sessionID)
            contextUsage[sessionID] = nil
            agentTitles[sessionID] = nil
        } else {
            endedAgentIDs.remove(sessionID)
            if hookEvent == "Stop" || hookEvent == "SessionStart" { refreshContextUsage() }
        }
        // Claude is gone — its task is too. So is a `/clear`: the conversation
        // that carried the task no longer exists. A resumed or compacted
        // session keeps working on the same thing, so its task survives.
        if hookEvent == "SessionEnd" || (hookEvent == "SessionStart" && source == "clear") {
            update(sessionID) {
                $0.currentTask = nil
                $0.firstTask = nil
            }
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
            gitMayHaveChanged()
        case "PostToolUse":
            // A tool call can be the `git checkout` or `gh pr create` itself.
            gitMayHaveChanged()
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

    /// What a terminal's Tags menu offers: your list, then the tags some terminal
    /// carries that the list does not have.
    var knownTags: [String] {
        TagList.known(list: tagList, inUse: sessions.values.map(\.tags))
    }

    /// Tags terminals carry that are not on your list, for Settings to offer.
    var strayTags: [String] {
        TagList.strays(list: tagList, inUse: sessions.values.map(\.tags))
    }

    /// On how many terminals a tag sits.
    func tagUsage(_ tag: String) -> Int {
        TagList.usage(of: tag, in: sessions.values.map(\.tags))
    }

    func addTagToList(_ name: String) {
        tagList = TagList.adding(name, to: tagList)
    }

    /// A rename is meant everywhere — the list, every terminal that carries the
    /// tag, the saved arrangements (`TagBook` holds the rules).
    func renameTag(_ old: String, to name: String) {
        apply(tagBook.renaming(old, to: name))
    }

    /// A delete is meant everywhere too: the tag comes off every terminal.
    func deleteTag(_ tag: String) {
        apply(tagBook.deleting(tag))
    }

    func restoreDefaultTagList() {
        tagList = TagList.defaults
    }

    private var tagBook: TagBook {
        TagBook(list: tagList, terminals: sessions.mapValues(\.tags), presets: presets)
    }

    private func apply(_ book: TagBook) {
        tagList = book.list
        for (id, tags) in book.terminals where sessions[id]?.tags != tags {
            update(id) { $0.tags = tags }
        }
        if book.presets != presets {
            presets = book.presets
            PresetStore.save(book.presets)
        }
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
            takeOut(id, ofGroupAt: idx)
            if groups[idx].sessionIDs.isEmpty {
                groups.remove(at: idx)
                sanitizeWindows()
            }
        }
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            // Bring the strip up to date first: the new terminal is then a tab of its own.
            groups[idx].tabs = TabStrip.synced(groups[idx].tabs, to: groups[idx].sessionIDs)
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
            // The strip, if any tab holds a split: a plain row of tabs is what opening
            // creates anyway.
            let strip = self.tabs(of: group)
            if strip.contains(where: { $0.leaves.count > 1 }) {
                let order = TabStrip.order(strip)
                project.terminals = order.compactMap { sessions[$0] }.map { session in
                    var terminal = PresetTerminal(workingDirectory: session.currentDirectory)
                    terminal.customTitle = session.customTitle
                    terminal.color = session.color
                    terminal.tags = session.tags
                    terminal.startupCommand = session.startupCommand
                    return terminal
                }
                project.tabLayouts = strip.compactMap { PresetLayout.from($0, sessionIDs: order) }
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
            updateGroup(group.id) { $0.color = project.color }
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
            let strip = project.resolvedTabs(with: createdIDs)
            if !strip.isEmpty { applyTabs(strip, to: group.id) }
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
        // Runs after the import's `await`, i.e. from inside the main queue: see
        // `ModalAlert`.
        ModalAlert.show(alert)
    }

    // MARK: Persistence

    func scheduleSave() {
        let delay = saveDebounce.delay(changeAt: Date())
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Tracks how long the oldest unsaved change has been waiting, so a steady
    /// stream of changes cannot postpone the save indefinitely.
    private var saveDebounce = SaveDebounce()

    func saveNow() {
        // Whatever was pending is being written (or there is nothing to write):
        // the next change starts a fresh wait, and a timer still sleeping would
        // only repeat this write.
        saveDebounce.saved()
        saveTask?.cancel()
        // Never overwrite a real saved state with an empty one before the
        // restore decision was made.
        guard !groups.isEmpty || !windows.isEmpty else { return }
        let state = PersistedState(
            groups: groups,
            // The notepads are written here, from where they live while the app runs.
            sessions: sessions.values.map { session in
                var stored = session
                stored.notepad = notepadText[session.id]
                return stored
            },
            windows: windows,
            aiEnabled: aiEnabled,
            language: language,
            appearance: appearance,
            autoUpdateCheck: autoUpdateCheck,
            askBeforeRestore: askBeforeRestore,
            durableTerminals: durableTerminals,
            peekCollapsedProjects: peekCollapsedProjects,
            doneExpiry: doneExpiry,
            sidebarDetails: sidebarDetails,
            tagList: tagList,
            searchShortcut: searchShortcut,
            defaultIDEBundleID: defaultIDEBundleID,
            askedAboutSpaceSwitching: askedAboutSpaceSwitching,
            onboarding: onboarding,
            tabLayout: tabLayout,
            projectColor: projectColor,
            backgroundCountsAsRunning: backgroundCountsAsRunning,
            notepad: notepad,
            reviews: reviews
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
            let durableIDs = Set(state.sessions.filter(\.durable).map(\.id))
            Task { @MainActor in
                self.restoreLiveDurableIDs = await Task.detached {
                    Durable.liveIDsForRestore(listed: Durable.listSessions(), durableIDs: durableIDs)
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
        // Nothing runs after a restart that the restart did not start: a state
        // saved as running or waiting belongs to a process that is gone. Only a
        // durable agent that is still alive in tmux keeps it — its hooks say.
        for id in Array(sessions.keys) {
            guard let saved = sessions[id]?.state else { continue }
            let agentSurvived = sessions[id]?.durable == true && restoreLiveDurableIDs.contains(id)
            let restored = AttentionState.afterRestart(saved, agentSurvived: agentSurvived)
            if restored != saved {
                sessions[id]?.state = restored
                sessions[id]?.stateSince = Date()
            }
        }
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
        askBeforeRestore = state.askBeforeRestore
        durableTerminals = state.durableTerminals
        peekCollapsedProjects = state.peekCollapsedProjects
        doneExpiry = state.doneExpiry
        sidebarDetails = state.sidebarDetails
        tagList = state.tagList
        searchShortcut = state.searchShortcut
        defaultIDEBundleID = state.defaultIDEBundleID
        askedAboutSpaceSwitching = state.askedAboutSpaceSwitching
        onboarding = state.onboarding
        tabLayout = state.tabLayout
        projectColor = state.projectColor
        backgroundCountsAsRunning = state.backgroundCountsAsRunning
        notepad = state.notepad
        // One switch for all pads, from before they were per terminal: they all come up open.
        if notepad.openForAllFromOldState {
            notepad.openTerminals = Set(state.sessions.map(\.id))
            notepad.openForAllFromOldState = false
        }
        reviews = state.reviews
        notepadText = Dictionary(uniqueKeysWithValues: state.sessions.compactMap { session in
            session.notepad.flatMap { $0.isEmpty ? nil : (session.id, $0) }
        })
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
        askBeforeRestore = previous?.askBeforeRestore ?? askBeforeRestore
        durableTerminals = previous?.durableTerminals ?? durableTerminals
        peekCollapsedProjects = previous?.peekCollapsedProjects ?? peekCollapsedProjects
        doneExpiry = previous?.doneExpiry ?? doneExpiry
        sidebarDetails = previous?.sidebarDetails ?? sidebarDetails
        tagList = previous?.tagList ?? tagList
        searchShortcut = previous?.searchShortcut ?? searchShortcut
        defaultIDEBundleID = previous?.defaultIDEBundleID ?? defaultIDEBundleID
        askedAboutSpaceSwitching =
            previous?.askedAboutSpaceSwitching ?? askedAboutSpaceSwitching
        onboarding = previous?.onboarding ?? onboarding
        tabLayout = previous?.tabLayout ?? tabLayout
        projectColor = previous?.projectColor ?? projectColor
        backgroundCountsAsRunning = previous?.backgroundCountsAsRunning ?? backgroundCountsAsRunning
        notepad = previous?.notepad ?? notepad
        notepadText = [:]
        // The reviews outlive the workspace (they come from GitHub), but the
        // terminals and projects they pointed at are gone.
        reviews = reviews.mapValues { record in
            var kept = record
            kept.sessionID = nil
            kept.groupID = nil
            return kept
        }
    }

    // MARK: Surface notifications (title / pwd / child exit)

    private func observeSurfaceNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: .planchetteSurfaceTitle, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID,
                  let title = note.userInfo?["title"] as? String else { return }
            // Stored without the status glyph, so an animated one is not a change
            // (see `TerminalSession.cleanedTitle`).
            let cleaned = TerminalSession.cleanedTitle(title)
            Task { @MainActor in
                self?.update(id) { $0.oscTitle = cleaned.isEmpty ? nil : cleaned }
            }
        }
        center.addObserver(forName: .planchetteSurfacePwd, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID,
                  let pwd = note.userInfo?["pwd"] as? String else { return }
            Task { @MainActor in
                guard let self, self.sessions[id]?.currentDirectory != pwd else { return }
                self.update(id) { $0.currentDirectory = pwd }
                // Another directory can be another repo: its branch, and its PR,
                // are due now, not at the next poll.
                self.gitMayHaveChanged()
            }
        }
        center.addObserver(forName: .planchetteSurfaceChildExited, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID else { return }
            Task { @MainActor in self?.closeSession(id) }
        }
        center.addObserver(forName: .planchetteSurfaceSearch, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? UUID,
                  let event = note.userInfo?["event"] as? String else { return }
            let value = note.userInfo?["value"] as? Int
            let needle = note.userInfo?["needle"] as? String
            Task { @MainActor in self?.applySearchEvent(event, for: id, value: value, needle: needle) }
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

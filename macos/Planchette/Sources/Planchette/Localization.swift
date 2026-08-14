import AppKit
import Foundation

/// Supported UI languages. `.system` follows the OS preference.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system, en, de, fr, es, it, nl, pt

    var id: String { rawValue }

    /// Human-readable name shown in the picker (in that language itself).
    var displayName: String {
        switch self {
        case .system: return L10n.t(.langSystem)
        case .en: return "English"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .it: return "Italiano"
        case .nl: return "Nederlands"
        case .pt: return "Português"
        }
    }

    /// Resolves `.system` to a concrete language based on the OS preference,
    /// falling back to English.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        for code in Locale.preferredLanguages {
            let base = String(code.prefix(2))
            if let match = AppLanguage(rawValue: base), match != .system { return match }
        }
        return .en
    }
}

/// Light/dark/system appearance choice.
enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.t(.langSystem)
        case .light: return L10n.t(.appearanceLight)
        case .dark: return L10n.t(.appearanceDark)
        }
    }

    /// The AppKit appearance to apply (nil = follow the system).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func apply() {
        NSApp.appearance = nsAppearance
    }
}

/// Translation keys — compile-checked so a missing usage is caught, and a
/// missing translation falls back to English, then to the raw key.
enum LKey: String, CaseIterable {
    // Languages / settings
    case langSystem, settingsTitle, language, appearance, aiSection
    case appearanceLight, appearanceDark, appearanceHelp, settingsHelp

    // Sidebar sections & group/session menus
    case mainProjects, projects, sideProjects
    case makeFavorite, unmakeFavorite, color, colorNone, rename, moveToNewWindow
    case tags, newTag, removeAllTags, startupCommand, close
    case closeProject, closeProjectBody
    case renameGroup, renameTerminal, startupCommandPrompt, newTagTitle
    case ok, cancel

    // Waiting time
    case now, minutesShort, hoursShort

    // Terminal area
    case noTerminalsInGroup, newTerminalHint

    // Inbox
    case attention, allQuiet, waitingForAnswer, doneSeeResult

    // Staged ("install on quit") updates
    case updateInstallOnQuit, updateStagedTitle, updateStagedBody, updatePendingQuit

    // Quitting while agents work
    case quitWhileRunningTitle, quitWhileRunningBody, quitAnyway

    // Durable terminals (tmux-backed)
    case durableSection, durableActive, durableHelp, durableExplanation, durableMissingTmux

    // Worktrees
    case newWorktree, newWorktreeHelp, worktreeBranchPrompt, worktreeBasePrompt
    case worktreeFailed, removeWorktreeTitle, removeWorktreeBody, removeWorktree, keepWorktree

    // Quick switcher
    case switcherPlaceholder

    // Menus / commands
    case newWindow, sessionMenu, newTerminal, quickSwitcher, jumpToWaiting
    case aiMenu, aiActive, aiExplanation, summarizeAll, groupByTopic

    // Toolbar
    case aiAssist, aiAssistOn, aiAssistOff, aiAssistOnHelp, aiAssistOffHelp
    case inbox, inboxHelp, mergeIntoMain, mergeIntoMainHelp
    case newTerminalHelp, newWindowHelp, quickSwitcherHelp, jumpToWaitingHelp
    case moveToNewWindowHelp, favoriteHelp, tagsHelp, startupCommandHelp
    case renameHelp, colorHelp, closeHelp, summarizeAllHelp, groupByTopicHelp
    case languageHelp

    // Welcome
    case tagline, openFirstTerminal

    // Restore dialog
    case restoreTitle, restoreBody, restore, startFresh

    // Grouping alerts
    case noGroupingTitle, noGroupingBody, groupByTopicTitle, group

    // Menu bar
    case allQuietShort, openPlanchette, asks

    // Open panel
    case chooseFolder

    // Merged window placeholder
    case windowMerged

    // Migration / import
    case importMenu, importFromITerm, importFromTerminal
    case importNothing, importNotRunning, importNotAuthorized, importAuthHint, importFailed
    case importMenuHelp, dropHint

    // Updates
    case updates, checkForUpdates, autoUpdateCheck, autoUpdateHelp
    case updateAvailable, updateAvailableBody, updateDownload
    case updateUpToDate, updateCurrentVersion, updateFailed
    case updateInstallRelaunch, updateInstallBody, updateInstalling, updateLater, updateNoReleases, updateDownloading
    case whatsNew, andMoreChanges

    // Status colors / states
    case stateReady, stateRunning, stateWaiting, stateError, stateFree, errorOccurred, free
    case generalTab, infoTab, colorLegendTitle, colorLegendIntro
    case readyDesc, runningDesc, waitingDesc, errorDesc, freeDesc
    case needsYou, waitingSince

    // Projects / terminals / sidebar
    case newProject, newProjectHelp, addTerminalHelp
    case fontSmaller, fontLarger, fontReset
    case minifySidebar, expandSidebar, markReady

    // Notifications panel (right sidebar)
    case notificationsPanel, notificationsPanelHelp, onlyActive, clearReady
    case onlyUnread, onlyUnreadHelp, markAllRead, markRead, markUnread

    // Empty states
    case noProjectsYet

    // Terminal context menu
    case menuCopy, menuPaste, menuSelectAll

    // Project folders (grouping projects in the sidebar)
    case newFolder, newFolderTitle, newFolderHelp, renameFolder
    case moveToFolder, noFolder, dissolveFolder, dissolveFolderHelp

    // Folder overview page (what is inside a folder)
    case folderOverviewHelp, folderEmpty, openProjectHelp, terminalsCount, terminalCountOne
    case newProjectInFolder

    // Help tab (the searchable feature catalogue — see Help.swift)
    case helpTab, helpSearch, helpNoResults, helpMissing, requestFeature, requestFeatureHelp
    case helpSectionTerminals, helpSectionWindows
    case helpWhereSidebar, helpWhereTabBar, helpWhereContextMenu, helpWhereSettings
    case helpWhereMenuBar, helpWhereToolbar
    case newProjectInFolderShort, newProjectInFolderHelp, folderOverviewTitle
    case dropIntoFolderHelp, selectedProjectsShort, helpMultiSelectDetail
    case helpClusterTitle, helpClusterDetail, helpDropTitle, helpCLITitle, helpCLIDetail
    case helpInstallOnQuitDetail
    case helpBranchTitle, helpBranchDetail
    case latestNotifications, nothingReported

    // Snooze ("remind me later")
    case remindMe, remindMeHelp, remindIn1h, remindIn2h, remindTomorrow, remindCancel
    case quietUntil, reminder, reminderBody, markGroupReady

    // Presets (saved arrangements)
    case arrangements, arrangementsHelp, saveArrangement, saveArrangementTitle
    case saveArrangementHelp, openArrangement, renameArrangement, deleteArrangement
    case noArrangements, arrangementSummary, savedArrangements

    // Multi-selection of projects + drag-and-drop between folders
    case selectedProjects, markProjectsFree, closeProjects, closeProjectsBody, dropIntoFolder
}

/// Central localizer. `current` is set by AppState; views observe AppState so
/// changing the language re-renders everything.
enum L10n {
    static var current: AppLanguage = .system

    static func t(_ key: LKey) -> String {
        let lang = current.resolved
        if let table = tables[lang], let value = table[key] { return value }
        if let value = tables[.en]?[key] { return value }
        return key.rawValue
    }

    /// Interpolate a count/argument, e.g. waiting "12 min".
    static func t(_ key: LKey, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    private static let tables: [AppLanguage: [LKey: String]] = [
        .en: en, .de: de, .fr: fr, .es: es, .it: it, .nl: nl, .pt: pt,
    ]

    // MARK: English (base)
    private static let en: [LKey: String] = [
        .langSystem: "System", .settingsTitle: "Settings", .language: "Language",
        .appearance: "Appearance", .aiSection: "AI",
        .appearanceLight: "Light", .appearanceDark: "Dark", .appearanceHelp: "Light, dark, or follow the system", .settingsHelp: "Open settings (⌘,)",
        .mainProjects: "Main projects", .projects: "Projects", .sideProjects: "Side projects",
        .makeFavorite: "Mark as main project", .unmakeFavorite: "Remove main project",
        .color: "Color", .colorNone: "None", .rename: "Rename…",
        .moveToNewWindow: "Move to new window",
        .tags: "Tags", .newTag: "New tag…", .removeAllTags: "Remove all",
        .startupCommand: "Startup command…", .close: "Close",
        .closeProject: "Close Project", .closeProjectBody: "Close \"%@\" and its %d terminal(s)? This ends any running sessions.",
        .renameGroup: "Rename group", .renameTerminal: "Rename terminal",
        .startupCommandPrompt: "Startup command (runs again after a restore)",
        .newTagTitle: "New tag", .ok: "OK", .cancel: "Cancel",
        .now: "now", .minutesShort: "%d min", .hoursShort: "%dh %dm",
        .noTerminalsInGroup: "No terminals in this group",
        .newTerminalHint: "⌘T opens a new terminal",
        .attention: "Attention", .allQuiet: "All quiet — nothing needs you.",
        .waitingForAnswer: "Waiting for an answer", .doneSeeResult: "Done — see the result",
        .switcherPlaceholder: "Title, path, branch, group…",
        .newWindow: "New window", .sessionMenu: "Session", .newTerminal: "New terminal…",
        .quickSwitcher: "Quick switcher", .jumpToWaiting: "Jump to waiting session",
        .aiMenu: "AI", .aiActive: "AI assist active", .aiExplanation: "Shows a one-line summary of what each terminal is working on (and a topic to group them). It reads each session's local Claude transcript and condenses it with your existing Claude login — no API key, and it only runs while this is on.", .summarizeAll: "Summarize all sessions now",
        .groupByTopic: "Group by topic…",
        .aiAssist: "AI assist", .aiAssistOn: "AI: On", .aiAssistOff: "AI: Off",
        .aiAssistOnHelp: "AI assist on: sessions are summarized and can be grouped by topic",
        .aiAssistOffHelp: "AI assist off — turn on to summarize agent sessions and group them by topic",
        .inbox: "Inbox", .inboxHelp: "Attention inbox: sessions that ask or finished, most urgent first",
        .mergeIntoMain: "Merge into main window",
        .mergeIntoMainHelp: "Move all groups of this window into the main window",
        .newTerminalHelp: "Open a new terminal in this window (⌘T)",
        .newWindowHelp: "Open a new, empty window (⌘N)",
        .quickSwitcherHelp: "Search and jump to any terminal (⌘K)",
        .jumpToWaitingHelp: "Jump to the most urgent waiting session (⌘⇧K)",
        .moveToNewWindowHelp: "Pull this group out into its own window",
        .favoriteHelp: "Main projects are prioritized in the inbox, notifications and switcher",
        .tagsHelp: "Tag this terminal (to test, review, …) — searchable in the switcher",
        .startupCommandHelp: "Command re-run automatically after a restore (e.g. npm run dev)",
        .renameHelp: "Set a custom name",
        .colorHelp: "Pick a color", .closeHelp: "Close this terminal",
        .summarizeAllHelp: "Summarize every session now using claude -p",
        .groupByTopicHelp: "Propose grouping sessions that share a topic (applied only after you confirm)",
        .languageHelp: "Language of the Planchette interface",
        .tagline: "points you to the session that speaks",
        .openFirstTerminal: "Open your first terminal (⌘T)",
        .restoreTitle: "Restore your last session?",
        .restoreBody: "%d terminal(s) in %d group(s). Claude sessions resume, startup commands run again.",
        .restore: "Restore", .startFresh: "Start fresh",
        .noGroupingTitle: "No grouping suggestion",
        .noGroupingBody: "Not enough sessions share a topic yet. Summarize first.",
        .groupByTopicTitle: "Group by topic?",
        .group: "Group",
        .allQuietShort: "All quiet", .openPlanchette: "Open Planchette", .asks: "asks",
        .chooseFolder: "Choose the project folder for the new terminal",
        .windowMerged: "Window was merged",
        .importMenu: "Import", .importFromITerm: "Import from iTerm2", .importFromTerminal: "Import from Terminal.app",
        .importNothing: "no open terminals found", .importNotRunning: "is not running", .importNotAuthorized: "Automation not allowed", .importAuthHint: "Allow Planchette to control the terminal app in System Settings → Privacy & Security → Automation, then try again.", .importFailed: "Import failed", .importMenuHelp: "Open the working directories of another terminal app as Planchette terminals", .dropHint: "Drop a folder here to open a terminal",
        .updates: "Updates", .checkForUpdates: "Check for updates…", .autoUpdateCheck: "Automatically check for updates", .autoUpdateHelp: "Check GitHub for a newer stable release on launch",
        .updateAvailable: "Version %@ is available", .updateAvailableBody: "Download the new version and drag it into Applications.", .updateDownload: "Download",
        .updateUpToDate: "You're up to date", .updateCurrentVersion: "Current version: %@", .updateFailed: "Update check failed",
        .updateInstallRelaunch: "Install & Relaunch", .updateInstallBody: "Planchette will download the new version, install it, and relaunch itself.", .updateInstalling: "Installing update…", .updateLater: "Later", .updateNoReleases: "Couldn't find any releases yet.", .updateDownloading: "Downloading update… %d%%",
        .whatsNew: "What's new", .andMoreChanges: "…and %d more",
        .stateReady: "Done", .stateFree: "Free", .stateRunning: "Running", .stateWaiting: "Waiting for input", .stateError: "Error", .errorOccurred: "An error occurred", .free: "free",
        .generalTab: "General", .infoTab: "Information", .colorLegendTitle: "Status colors", .colorLegendIntro: "Each terminal shows a colored status dot:",
        .readyDesc: "the turn or command finished — a result awaits your review", .freeDesc: "empty prompt, nothing to review — this terminal is up for grabs", .needsYou: "Needs you", .waitingSince: "waiting for %d min", .runningDesc: "an agent or command is running", .waitingDesc: "the agent is waiting for you to answer or approve", .errorDesc: "the last command or agent exited with an error",
        .newProject: "New project…", .newProjectHelp: "Add a project from a folder", .addTerminalHelp: "Add a terminal in this project's folder",
        .fontSmaller: "Smaller font (⌘-)", .fontLarger: "Larger font (⌘+)", .fontReset: "Reset font size (⌘0)",
        .minifySidebar: "Collapse sidebar", .expandSidebar: "Expand sidebar", .markReady: "Mark as ready", .notificationsPanel: "Notifications", .notificationsPanelHelp: "Show the notifications panel on the right", .onlyActive: "Only active", .clearReady: "Hide idle", .noProjectsYet: "No projects yet — click + to add one.", .menuCopy: "Copy", .menuPaste: "Paste", .menuSelectAll: "Select All",
        .onlyUnread: "Only unread", .onlyUnreadHelp: "Show only terminals whose last report you haven't looked at", .markAllRead: "Mark all as read", .markRead: "Mark as read", .markUnread: "Mark as unread",
        .newWorktree: "New worktree…", .newWorktreeHelp: "Create a git worktree and open it as a project", .worktreeBranchPrompt: "Branch for the new worktree", .worktreeBasePrompt: "Base (empty = current HEAD)", .worktreeFailed: "Could not create the worktree", .removeWorktreeTitle: "Remove the checkout?", .removeWorktreeBody: "Delete the worktree at \"%@\"? Git refuses while it still has uncommitted changes.", .removeWorktree: "Remove", .keepWorktree: "Keep",
        .quitWhileRunningTitle: "Quit while agents are working?", .quitWhileRunningBody: "%d terminal(s) are still running. Quitting ends them — a restore can bring the conversation back, but not the work in flight.", .quitAnyway: "Quit anyway",
        .durableSection: "Durable terminals", .durableActive: "New terminals survive a restart", .durableHelp: "Runs each new terminal inside tmux, so its agent keeps working when Planchette quits, crashes or installs an update.", .durableExplanation: "New terminals run inside tmux. Quitting, installing an update or even a crash leaves the agent running — reopening re-attaches to the live session instead of resuming a conversation. A reboot still ends everything. Existing terminals keep what they were created as. The cost: tmux cannot pass the terminal's keyboard protocol through, so Shift+Enter reaches an agent as a plain Enter (it submits instead of adding a line). Leave this off unless an agent needs to outlive the app.", .durableMissingTmux: "Needs tmux, which was not found. Install it (e.g. brew install tmux) and reopen Settings.",
        .updateInstallOnQuit: "Install on quit", .updateStagedTitle: "Version %@ is ready", .updateStagedBody: "It is downloaded and verified. Nothing changes until you quit Planchette — the next launch runs the new version, and your running agents are left alone.", .updatePendingQuit: "An update will be installed when you quit.",
        .newFolder: "New folder…", .newFolderTitle: "Name of the folder", .newFolderHelp: "Group projects in a named folder", .renameFolder: "Rename folder", .moveToFolder: "Move to folder", .noFolder: "No folder", .dissolveFolder: "Dissolve folder", .dissolveFolderHelp: "Removes the folder; its projects stay",
        .folderOverviewHelp: "Show what is inside this folder", .newProjectInFolder: "Add a project in \"%@\"", .folderEmpty: "No projects in this folder yet — drag one in from the sidebar.", .openProjectHelp: "Open this project", .terminalsCount: "%d terminals", .terminalCountOne: "1 terminal", .latestNotifications: "Latest notifications", .nothingReported: "Nothing reported yet",
        .helpTab: "Help", .helpBranchTitle: "Checked-out branch", .helpBranchDetail: "Each project shows the branch of its checkout, refreshed while you work", .helpSearch: "Search features and shortcuts", .helpNoResults: "Nothing matches that.", .helpMissing: "Missing something?", .requestFeature: "Request a feature…", .requestFeatureHelp: "Opens a pre-filled feature request on GitHub", .helpSectionTerminals: "Terminals", .helpSectionWindows: "Windows & navigation", .helpWhereSidebar: "Sidebar", .helpWhereTabBar: "Tab bar", .helpWhereContextMenu: "Right-click menu", .helpWhereSettings: "Settings", .helpWhereMenuBar: "Menu bar", .helpWhereToolbar: "Toolbar", .newProjectInFolderShort: "New project in a folder", .newProjectInFolderHelp: "The + on a folder row adds a project inside that folder", .folderOverviewTitle: "Folder overview", .dropIntoFolderHelp: "Drag a project onto a folder, or between two rows to place it exactly", .selectedProjectsShort: "Several projects at once", .helpMultiSelectDetail: "⌘/⇧-click picks a batch; drag or act on all of them at once", .helpClusterTitle: "Cluster view", .helpClusterDetail: "Show every terminal of a project at once; drag a pane onto another edge to split", .helpDropTitle: "Open a folder from Finder", .helpCLITitle: "Drive Planchette from an agent", .helpCLIDetail: "A socket API and the planchette CLI in every terminal: list, open, prompt, wait, read", .helpInstallOnQuitDetail: "Downloads the update and installs it the next time you quit, so no running turn is interrupted",
        .remindMe: "Remind me…", .remindMeHelp: "Goes quiet until then, then reminds you", .remindIn1h: "In 1 hour", .remindIn2h: "In 2 hours", .remindTomorrow: "Tomorrow 9:00", .remindCancel: "Cancel reminder", .quietUntil: "quiet until %@", .reminder: "Reminder", .reminderBody: "You asked to be reminded about this.", .markGroupReady: "Mark project as free",
        .arrangements: "Arrangements", .arrangementsHelp: "Saved arrangements of projects and terminals", .saveArrangement: "Save arrangement…", .saveArrangementTitle: "Name of the arrangement", .saveArrangementHelp: "Save this window's projects and terminals as a reusable arrangement", .openArrangement: "Open", .renameArrangement: "Rename arrangement", .deleteArrangement: "Delete arrangement", .noArrangements: "No saved arrangements yet", .arrangementSummary: "%d projects · %d terminals", .savedArrangements: "Saved arrangements",
        .selectedProjects: "%d projects selected", .markProjectsFree: "Mark %d projects as free", .closeProjects: "Close %d projects", .closeProjectsBody: "Close %d projects and their %d terminal(s)? This ends any running sessions.", .dropIntoFolder: "Move into \"%@\"",
    ]

    // MARK: German
    private static let de: [LKey: String] = [
        .langSystem: "System", .settingsTitle: "Einstellungen", .language: "Sprache",
        .appearance: "Darstellung", .aiSection: "KI",
        .appearanceLight: "Hell", .appearanceDark: "Dunkel", .appearanceHelp: "Hell, dunkel oder dem System folgen", .settingsHelp: "Einstellungen öffnen (⌘,)",
        .mainProjects: "Hauptprojekte", .projects: "Projekte", .sideProjects: "Side Projects",
        .makeFavorite: "Als Hauptprojekt", .unmakeFavorite: "Kein Hauptprojekt mehr",
        .color: "Farbe", .colorNone: "Keine", .rename: "Umbenennen…",
        .moveToNewWindow: "In neues Fenster verschieben",
        .tags: "Tags", .newTag: "Neues Tag…", .removeAllTags: "Alle entfernen",
        .startupCommand: "Startup-Command…", .close: "Schließen",
        .closeProject: "Projekt schließen", .closeProjectBody: "„%@“ und seine %d Terminal(s) schließen? Laufende Sitzungen werden beendet.",
        .renameGroup: "Gruppe umbenennen", .renameTerminal: "Terminal umbenennen",
        .startupCommandPrompt: "Startup-Command (läuft nach einem Restore erneut)",
        .newTagTitle: "Neues Tag", .ok: "OK", .cancel: "Abbrechen",
        .now: "jetzt", .minutesShort: "%d min", .hoursShort: "%d h %d min",
        .noTerminalsInGroup: "Keine Terminals in dieser Gruppe",
        .newTerminalHint: "⌘T öffnet ein neues Terminal",
        .attention: "Aufmerksamkeit", .allQuiet: "Alles ruhig — nichts wartet auf dich.",
        .waitingForAnswer: "Wartet auf eine Antwort", .doneSeeResult: "Fertig — Ergebnis ansehen",
        .switcherPlaceholder: "Titel, Pfad, Branch, Gruppe…",
        .newWindow: "Neues Fenster", .sessionMenu: "Session", .newTerminal: "Neues Terminal…",
        .quickSwitcher: "Quick Switcher", .jumpToWaiting: "Zur wartenden Session",
        .aiMenu: "KI", .aiActive: "KI-Assistenz aktiv", .aiExplanation: "Zeigt eine einzeilige Zusammenfassung, woran jedes Terminal gerade arbeitet (und ein Thema zum Gruppieren). Liest das lokale Claude-Transcript jeder Session und verdichtet es mit deinem bestehenden Claude-Login — kein API-Key, läuft nur wenn aktiv.", .summarizeAll: "Alle Sessions jetzt zusammenfassen",
        .groupByTopic: "Nach Themen gruppieren…",
        .aiAssist: "KI-Assistenz", .aiAssistOn: "KI: An", .aiAssistOff: "KI: Aus",
        .aiAssistOnHelp: "KI-Assistenz aktiv: Sessions werden zusammengefasst und können nach Themen gruppiert werden",
        .aiAssistOffHelp: "KI-Assistenz aus — einschalten, um Agent-Sessions zusammenzufassen und nach Themen zu gruppieren",
        .inbox: "Inbox", .inboxHelp: "Aufmerksamkeits-Inbox: Sessions, die fragen oder fertig sind, dringendste zuerst",
        .mergeIntoMain: "In Hauptfenster mergen",
        .mergeIntoMainHelp: "Alle Gruppen dieses Fensters ins Hauptfenster verschieben",
        .newTerminalHelp: "Neues Terminal in diesem Fenster öffnen (⌘T)",
        .newWindowHelp: "Neues, leeres Fenster öffnen (⌘N)",
        .quickSwitcherHelp: "Beliebiges Terminal suchen und dorthin springen (⌘K)",
        .jumpToWaitingHelp: "Zur dringendsten wartenden Session springen (⌘⇧K)",
        .moveToNewWindowHelp: "Diese Gruppe in ein eigenes Fenster herausziehen",
        .favoriteHelp: "Hauptprojekte werden in Inbox, Notifications und Switcher bevorzugt",
        .tagsHelp: "Terminal taggen (to test, review, …) — im Switcher durchsuchbar",
        .startupCommandHelp: "Command läuft nach einem Restore automatisch erneut (z.B. npm run dev)",
        .renameHelp: "Eigenen Namen setzen",
        .colorHelp: "Farbe wählen", .closeHelp: "Dieses Terminal schließen",
        .summarizeAllHelp: "Jede Session jetzt per claude -p zusammenfassen",
        .groupByTopicHelp: "Gruppierung nach gemeinsamem Thema vorschlagen (erst nach Bestätigung angewendet)",
        .languageHelp: "Sprache der Planchette-Oberfläche",
        .tagline: "führt dich zu der Session, die spricht",
        .openFirstTerminal: "Erstes Terminal öffnen (⌘T)",
        .restoreTitle: "Letzte Sitzung wiederherstellen?",
        .restoreBody: "%d Terminal(s) in %d Gruppe(n). Claude-Sessions werden fortgesetzt, Startup-Commands laufen erneut an.",
        .restore: "Wiederherstellen", .startFresh: "Neu starten",
        .noGroupingTitle: "Kein Gruppierungs-Vorschlag",
        .noGroupingBody: "Noch zu wenige Sessions mit gleichem Thema. Erst zusammenfassen lassen.",
        .groupByTopicTitle: "Nach Themen gruppieren?",
        .group: "Gruppieren",
        .allQuietShort: "Alles ruhig", .openPlanchette: "Planchette öffnen", .asks: "fragt",
        .chooseFolder: "Projektordner für das neue Terminal wählen",
        .windowMerged: "Fenster wurde zusammengeführt",
        .importMenu: "Import", .importFromITerm: "Aus iTerm2 importieren", .importFromTerminal: "Aus Terminal.app importieren",
        .importNothing: "keine offenen Terminals gefunden", .importNotRunning: "läuft nicht", .importNotAuthorized: "Automatisierung nicht erlaubt", .importAuthHint: "Erlaube Planchette in Systemeinstellungen → Datenschutz & Sicherheit → Automatisierung, die Terminal-App zu steuern, und versuche es erneut.", .importFailed: "Import fehlgeschlagen", .importMenuHelp: "Die Arbeitsverzeichnisse einer anderen Terminal-App als Planchette-Terminals öffnen", .dropHint: "Ordner hierher ziehen, um ein Terminal zu öffnen",
        .updates: "Updates", .checkForUpdates: "Nach Updates suchen…", .autoUpdateCheck: "Automatisch nach Updates suchen", .autoUpdateHelp: "Beim Start auf GitHub nach einer neueren stabilen Version prüfen",
        .updateAvailable: "Version %@ ist verfügbar", .updateAvailableBody: "Lade die neue Version herunter und ziehe sie in „Programme“.", .updateDownload: "Herunterladen",
        .updateUpToDate: "Alles aktuell", .updateCurrentVersion: "Aktuelle Version: %@", .updateFailed: "Update-Suche fehlgeschlagen",
        .updateInstallRelaunch: "Installieren & Neustart", .updateInstallBody: "Planchette lädt die neue Version herunter, installiert sie und startet sich neu.", .updateInstalling: "Update wird installiert…", .updateLater: "Später", .updateNoReleases: "Noch keine Releases gefunden.", .updateDownloading: "Update wird geladen… %d%%",
        .whatsNew: "Das ist neu", .andMoreChanges: "…und %d weitere",
        .stateReady: "Fertig", .stateFree: "Frei", .stateRunning: "Läuft", .stateWaiting: "Wartet auf Eingabe", .stateError: "Fehler", .errorOccurred: "Ein Fehler ist aufgetreten", .free: "frei",
        .generalTab: "Allgemein", .infoTab: "Information", .colorLegendTitle: "Status-Farben", .colorLegendIntro: "Jedes Terminal zeigt einen farbigen Statuspunkt:",
        .readyDesc: "Turn oder Befehl beendet — ein Ergebnis wartet auf deinen Blick", .freeDesc: "leerer Prompt, nichts zu reviewen — dieses Terminal ist zu haben", .needsYou: "Braucht dich", .waitingSince: "wartet seit %d min", .runningDesc: "ein Agent oder Befehl läuft", .waitingDesc: "der Agent wartet auf deine Antwort oder Freigabe", .errorDesc: "der letzte Befehl oder Agent endete mit einem Fehler",
        .newProject: "Neues Projekt…", .newProjectHelp: "Projekt aus einem Ordner hinzufügen", .addTerminalHelp: "Terminal im Ordner dieses Projekts hinzufügen",
        .fontSmaller: "Kleinere Schrift (⌘-)", .fontLarger: "Größere Schrift (⌘+)", .fontReset: "Schriftgröße zurücksetzen (⌘0)",
        .minifySidebar: "Seitenleiste einklappen", .expandSidebar: "Seitenleiste ausklappen", .markReady: "Als frei markieren", .notificationsPanel: "Benachrichtigungen", .notificationsPanelHelp: "Benachrichtigungs-Sidebar rechts anzeigen", .onlyActive: "Nur aktive", .clearReady: "Ruhige ausblenden", .noProjectsYet: "Noch keine Projekte — mit + eines hinzufügen.", .menuCopy: "Kopieren", .menuPaste: "Einsetzen", .menuSelectAll: "Alles auswählen",
        .onlyUnread: "Nur ungelesen", .onlyUnreadHelp: "Nur Terminals zeigen, deren letzte Meldung du noch nicht gesehen hast", .markAllRead: "Alle als gelesen markieren", .markRead: "Als gelesen markieren", .markUnread: "Als ungelesen markieren",
        .newWorktree: "Neuer Worktree…", .newWorktreeHelp: "Git-Worktree anlegen und als Projekt öffnen", .worktreeBranchPrompt: "Branch für den neuen Worktree", .worktreeBasePrompt: "Basis (leer = aktueller HEAD)", .worktreeFailed: "Worktree konnte nicht angelegt werden", .removeWorktreeTitle: "Arbeitskopie entfernen?", .removeWorktreeBody: "Worktree unter \"%@\" löschen? Git verweigert das, solange dort uncommittete Änderungen liegen.", .removeWorktree: "Entfernen", .keepWorktree: "Behalten",
        .quitWhileRunningTitle: "Beenden, während Agents arbeiten?", .quitWhileRunningBody: "%d Terminal(s) laufen noch. Beim Beenden werden sie abgebrochen — eine Wiederherstellung bringt die Unterhaltung zurück, nicht aber die laufende Arbeit.", .quitAnyway: "Trotzdem beenden",
        .durableSection: "Dauerhafte Terminals", .durableActive: "Neue Terminals überleben einen Neustart", .durableHelp: "Führt jedes neue Terminal in tmux aus, damit sein Agent weiterarbeitet, wenn Planchette beendet wird, abstürzt oder ein Update installiert.", .durableExplanation: "Neue Terminals laufen in tmux. Beenden, ein Update oder selbst ein Absturz lassen den Agent weiterlaufen — beim Öffnen wird die laufende Sitzung wieder verbunden, statt eine Unterhaltung fortzusetzen. Ein Neustart des Rechners beendet trotzdem alles. Bestehende Terminals bleiben, wie sie erstellt wurden. Der Preis: tmux leitet das Tastatur-Protokoll des Terminals nicht durch, deshalb kommt Shift+Enter beim Agent als einfaches Enter an (es sendet ab, statt eine Zeile einzufügen). Lass das aus, außer ein Agent soll die App überleben.", .durableMissingTmux: "Benötigt tmux, das nicht gefunden wurde. Installiere es (z. B. brew install tmux) und öffne die Einstellungen erneut.",
        .updateInstallOnQuit: "Beim Beenden installieren", .updateStagedTitle: "Version %@ ist bereit", .updateStagedBody: "Sie ist geladen und geprüft. Bis du Planchette beendest, ändert sich nichts — der nächste Start läuft mit der neuen Version, laufende Agents bleiben unberührt.", .updatePendingQuit: "Ein Update wird beim Beenden installiert.",
        .newFolder: "Neuer Ordner…", .newFolderTitle: "Name des Ordners", .newFolderHelp: "Projekte in einem benannten Ordner bündeln", .renameFolder: "Ordner umbenennen", .moveToFolder: "In Ordner verschieben", .noFolder: "Kein Ordner", .dissolveFolder: "Ordner auflösen", .dissolveFolderHelp: "Entfernt den Ordner; die Projekte bleiben",
        .folderOverviewHelp: "Zeigen, was in diesem Ordner steckt", .newProjectInFolder: "Ein Projekt in \"%@\" anlegen", .folderEmpty: "Noch keine Projekte in diesem Ordner — eines aus der Seitenleiste hineinziehen.", .openProjectHelp: "Projekt öffnen", .terminalsCount: "%d Terminals", .terminalCountOne: "1 Terminal", .latestNotifications: "Neueste Benachrichtigungen", .nothingReported: "Noch nichts gemeldet",
        .helpTab: "Hilfe", .helpBranchTitle: "Ausgecheckter Branch", .helpBranchDetail: "Jedes Projekt zeigt den Branch seines Checkouts, laufend aktualisiert", .helpSearch: "Funktionen und Kurzbefehle suchen", .helpNoResults: "Dazu passt nichts.", .helpMissing: "Fehlt etwas?", .requestFeature: "Funktion vorschlagen…", .requestFeatureHelp: "Öffnet einen vorbereiteten Feature-Request auf GitHub", .helpSectionTerminals: "Terminals", .helpSectionWindows: "Fenster & Navigation", .helpWhereSidebar: "Seitenleiste", .helpWhereTabBar: "Tab-Leiste", .helpWhereContextMenu: "Rechtsklick-Menü", .helpWhereSettings: "Einstellungen", .helpWhereMenuBar: "Menüleiste", .helpWhereToolbar: "Symbolleiste", .newProjectInFolderShort: "Neues Projekt in einem Ordner", .newProjectInFolderHelp: "Das + auf einer Ordnerzeile legt ein Projekt darin an", .folderOverviewTitle: "Ordner-Übersicht", .dropIntoFolderHelp: "Ein Projekt auf einen Ordner ziehen — oder zwischen zwei Zeilen, um es genau zu platzieren", .selectedProjectsShort: "Mehrere Projekte auf einmal", .helpMultiSelectDetail: "⌘/⇧-Klick wählt einen Stapel; ziehen oder alle zusammen bearbeiten", .helpClusterTitle: "Cluster-Ansicht", .helpClusterDetail: "Alle Terminals eines Projekts gleichzeitig zeigen; ein Feld an den Rand eines anderen ziehen teilt es", .helpDropTitle: "Ordner aus dem Finder öffnen", .helpCLITitle: "Planchette aus einem Agenten steuern", .helpCLIDetail: "Socket-API und das planchette-CLI in jedem Terminal: auflisten, öffnen, Prompt senden, auf Status warten, Ausgabe lesen", .helpInstallOnQuitDetail: "Lädt das Update und installiert es beim nächsten Beenden — kein laufender Turn wird unterbrochen",
        .remindMe: "Erinnere mich…", .remindMeHelp: "Bis dahin still, danach eine Erinnerung", .remindIn1h: "In 1 Stunde", .remindIn2h: "In 2 Stunden", .remindTomorrow: "Morgen 9:00", .remindCancel: "Erinnerung abbrechen", .quietUntil: "still bis %@", .reminder: "Erinnerung", .reminderBody: "Du wolltest daran erinnert werden.", .markGroupReady: "Projekt als frei markieren",
        .arrangements: "Anordnungen", .arrangementsHelp: "Gespeicherte Anordnungen von Projekten und Terminals", .saveArrangement: "Anordnung speichern…", .saveArrangementTitle: "Name der Anordnung", .saveArrangementHelp: "Projekte und Terminals dieses Fensters als wiederverwendbare Anordnung speichern", .openArrangement: "Öffnen", .renameArrangement: "Anordnung umbenennen", .deleteArrangement: "Anordnung löschen", .noArrangements: "Noch keine Anordnungen gespeichert", .arrangementSummary: "%d Projekte · %d Terminals", .savedArrangements: "Gespeicherte Anordnungen",
        .selectedProjects: "%d Projekte ausgewählt", .markProjectsFree: "%d Projekte als frei markieren", .closeProjects: "%d Projekte schließen", .closeProjectsBody: "%d Projekte mit ihren %d Terminals schließen? Laufende Sessions werden beendet.", .dropIntoFolder: "In \"%@\" verschieben",
    ]

    // MARK: French
    private static let fr: [LKey: String] = [
        .langSystem: "Système", .settingsTitle: "Réglages", .language: "Langue",
        .appearance: "Apparence", .aiSection: "IA",
        .appearanceLight: "Clair", .appearanceDark: "Sombre", .appearanceHelp: "Clair, sombre ou suivre le système", .settingsHelp: "Ouvrir les réglages (⌘,)",
        .mainProjects: "Projets principaux", .projects: "Projets", .sideProjects: "Projets secondaires",
        .makeFavorite: "Définir comme projet principal", .unmakeFavorite: "Retirer des projets principaux",
        .color: "Couleur", .colorNone: "Aucune", .rename: "Renommer…",
        .moveToNewWindow: "Déplacer vers une nouvelle fenêtre",
        .tags: "Étiquettes", .newTag: "Nouvelle étiquette…", .removeAllTags: "Tout retirer",
        .startupCommand: "Commande de démarrage…", .close: "Fermer",
        .closeProject: "Fermer le projet", .closeProjectBody: "Fermer « %@ » et ses %d terminal(aux) ? Les sessions en cours seront arrêtées.",
        .renameGroup: "Renommer le groupe", .renameTerminal: "Renommer le terminal",
        .startupCommandPrompt: "Commande de démarrage (relancée après une restauration)",
        .newTagTitle: "Nouvelle étiquette", .ok: "OK", .cancel: "Annuler",
        .now: "maintenant", .minutesShort: "%d min", .hoursShort: "%d h %d min",
        .noTerminalsInGroup: "Aucun terminal dans ce groupe",
        .newTerminalHint: "⌘T ouvre un nouveau terminal",
        .attention: "Attention", .allQuiet: "Tout est calme — rien ne vous attend.",
        .waitingForAnswer: "En attente d'une réponse", .doneSeeResult: "Terminé — voir le résultat",
        .switcherPlaceholder: "Titre, chemin, branche, groupe…",
        .newWindow: "Nouvelle fenêtre", .sessionMenu: "Session", .newTerminal: "Nouveau terminal…",
        .quickSwitcher: "Sélecteur rapide", .jumpToWaiting: "Aller à la session en attente",
        .aiMenu: "IA", .aiActive: "Assistance IA active", .aiExplanation: "Affiche un résumé d'une ligne de ce sur quoi chaque terminal travaille (et un thème pour les regrouper). Lit le transcript Claude local de chaque session et le condense avec votre connexion Claude existante — sans clé API, uniquement quand c'est activé.", .summarizeAll: "Résumer toutes les sessions",
        .groupByTopic: "Grouper par thème…",
        .aiAssist: "Assistance IA", .aiAssistOn: "IA : activée", .aiAssistOff: "IA : désactivée",
        .aiAssistOnHelp: "Assistance IA active : les sessions sont résumées et peuvent être groupées par thème",
        .aiAssistOffHelp: "Assistance IA désactivée — activez-la pour résumer les sessions et les grouper par thème",
        .inbox: "Boîte", .inboxHelp: "Boîte d'attention : sessions qui demandent ou ont fini, les plus urgentes d'abord",
        .mergeIntoMain: "Fusionner dans la fenêtre principale",
        .mergeIntoMainHelp: "Déplacer tous les groupes de cette fenêtre dans la fenêtre principale",
        .newTerminalHelp: "Ouvrir un nouveau terminal dans cette fenêtre (⌘T)",
        .newWindowHelp: "Ouvrir une nouvelle fenêtre vide (⌘N)",
        .quickSwitcherHelp: "Rechercher et aller vers n'importe quel terminal (⌘K)",
        .jumpToWaitingHelp: "Aller à la session en attente la plus urgente (⌘⇧K)",
        .moveToNewWindowHelp: "Extraire ce groupe dans sa propre fenêtre",
        .favoriteHelp: "Les projets principaux sont prioritaires dans la boîte, les notifications et le sélecteur",
        .tagsHelp: "Étiqueter ce terminal (to test, review, …) — recherchable dans le sélecteur",
        .startupCommandHelp: "Commande relancée automatiquement après une restauration (ex. npm run dev)",
        .renameHelp: "Définir un nom personnalisé",
        .colorHelp: "Choisir une couleur", .closeHelp: "Fermer ce terminal",
        .summarizeAllHelp: "Résumer chaque session maintenant avec claude -p",
        .groupByTopicHelp: "Proposer de grouper les sessions par thème commun (appliqué après confirmation)",
        .languageHelp: "Langue de l'interface de Planchette",
        .tagline: "vous mène à la session qui parle",
        .openFirstTerminal: "Ouvrir votre premier terminal (⌘T)",
        .restoreTitle: "Restaurer la dernière session ?",
        .restoreBody: "%d terminal(s) dans %d groupe(s). Les sessions Claude reprennent, les commandes de démarrage se relancent.",
        .restore: "Restaurer", .startFresh: "Recommencer",
        .noGroupingTitle: "Aucune suggestion de groupe",
        .noGroupingBody: "Pas encore assez de sessions partageant un thème. Résumez d'abord.",
        .groupByTopicTitle: "Grouper par thème ?",
        .group: "Grouper",
        .allQuietShort: "Tout est calme", .openPlanchette: "Ouvrir Planchette", .asks: "demande",
        .chooseFolder: "Choisir le dossier du projet pour le nouveau terminal",
        .windowMerged: "La fenêtre a été fusionnée",
        .importMenu: "Importer", .importFromITerm: "Importer depuis iTerm2", .importFromTerminal: "Importer depuis Terminal.app",
        .importNothing: "aucun terminal ouvert trouvé", .importNotRunning: "n'est pas en cours d'exécution", .importNotAuthorized: "Automatisation non autorisée", .importAuthHint: "Autorisez Planchette à contrôler l'app de terminal dans Réglages Système → Confidentialité et sécurité → Automatisation, puis réessayez.", .importFailed: "Échec de l'import", .importMenuHelp: "Ouvrir les répertoires de travail d'une autre app de terminal comme terminaux Planchette", .dropHint: "Déposez un dossier ici pour ouvrir un terminal",
        .updates: "Mises à jour", .checkForUpdates: "Rechercher des mises à jour…", .autoUpdateCheck: "Rechercher automatiquement les mises à jour", .autoUpdateHelp: "Vérifier sur GitHub une nouvelle version stable au lancement",
        .updateAvailable: "La version %@ est disponible", .updateAvailableBody: "Téléchargez la nouvelle version et glissez-la dans Applications.", .updateDownload: "Télécharger",
        .updateUpToDate: "Vous êtes à jour", .updateCurrentVersion: "Version actuelle : %@", .updateFailed: "Échec de la recherche de mises à jour",
        .updateInstallRelaunch: "Installer et relancer", .updateInstallBody: "Planchette va télécharger la nouvelle version, l'installer et se relancer.", .updateInstalling: "Installation de la mise à jour…", .updateLater: "Plus tard", .updateNoReleases: "Aucune version trouvée pour l'instant.", .updateDownloading: "Téléchargement… %d%%",
        .whatsNew: "Nouveautés", .andMoreChanges: "…et %d autres",
        .stateReady: "Terminé", .stateFree: "Libre", .stateRunning: "En cours", .stateWaiting: "En attente d'entrée", .stateError: "Erreur", .errorOccurred: "Une erreur s'est produite", .free: "libre",
        .generalTab: "Général", .infoTab: "Informations", .colorLegendTitle: "Couleurs d'état", .colorLegendIntro: "Chaque terminal affiche une pastille d'état colorée :",
        .readyDesc: "le tour ou la commande est terminé — un résultat attend votre regard", .freeDesc: "prompt vide, rien à relire — ce terminal est disponible", .needsYou: "Besoin de vous", .waitingSince: "en attente depuis %d min", .runningDesc: "un agent ou une commande s'exécute", .waitingDesc: "l'agent attend votre réponse ou approbation", .errorDesc: "la dernière commande ou l'agent s'est terminé avec une erreur",
        .newProject: "Nouveau projet…", .newProjectHelp: "Ajouter un projet depuis un dossier", .addTerminalHelp: "Ajouter un terminal dans le dossier de ce projet",
        .fontSmaller: "Police plus petite (⌘-)", .fontLarger: "Police plus grande (⌘+)", .fontReset: "Réinitialiser la police (⌘0)",
        .minifySidebar: "Réduire la barre latérale", .expandSidebar: "Développer la barre latérale", .markReady: "Marquer comme prêt", .notificationsPanel: "Notifications", .notificationsPanelHelp: "Afficher le panneau de notifications à droite", .onlyActive: "Actifs seulement", .clearReady: "Masquer les inactifs", .noProjectsYet: "Aucun projet — cliquez sur + pour en ajouter un.", .menuCopy: "Copier", .menuPaste: "Coller", .menuSelectAll: "Tout sélectionner",
        .onlyUnread: "Non lus seulement", .onlyUnreadHelp: "N'afficher que les terminaux dont le dernier rapport n'a pas été vu", .markAllRead: "Tout marquer comme lu", .markRead: "Marquer comme lu", .markUnread: "Marquer comme non lu",
        .newWorktree: "Nouveau worktree…", .newWorktreeHelp: "Créer un worktree git et l'ouvrir comme projet", .worktreeBranchPrompt: "Branche du nouveau worktree", .worktreeBasePrompt: "Base (vide = HEAD actuel)", .worktreeFailed: "Impossible de créer le worktree", .removeWorktreeTitle: "Supprimer la copie de travail ?", .removeWorktreeBody: "Supprimer le worktree dans « %@ » ? Git refuse tant qu'il reste des modifications non validées.", .removeWorktree: "Supprimer", .keepWorktree: "Conserver",
        .quitWhileRunningTitle: "Quitter pendant que les agents travaillent ?", .quitWhileRunningBody: "%d terminal(aux) sont encore en cours. Quitter les interrompt — une restauration récupère la conversation, pas le travail en cours.", .quitAnyway: "Quitter quand même",
        .durableSection: "Terminaux durables", .durableActive: "Les nouveaux terminaux survivent à un redémarrage", .durableHelp: "Exécute chaque nouveau terminal dans tmux, pour que son agent continue de travailler quand Planchette quitte, plante ou installe une mise à jour.", .durableExplanation: "Les nouveaux terminaux tournent dans tmux. Quitter, installer une mise à jour ou même un plantage laissent l'agent en marche — à la réouverture, on se rattache à la session vivante au lieu de reprendre une conversation. Un redémarrage de la machine met quand même fin à tout. Les terminaux existants gardent ce qu'ils étaient à leur création. Le prix : tmux ne transmet pas le protocole clavier du terminal, donc Shift+Entrée arrive à l'agent comme une simple Entrée (il envoie au lieu d'ajouter une ligne). Laissez ceci désactivé sauf si un agent doit survivre à l'application.", .durableMissingTmux: "Nécessite tmux, introuvable. Installez-le (p. ex. brew install tmux) puis rouvrez les Réglages.",
        .updateInstallOnQuit: "Installer en quittant", .updateStagedTitle: "La version %@ est prête", .updateStagedBody: "Elle est téléchargée et vérifiée. Rien ne change avant que vous quittiez Planchette — le prochain lancement utilisera la nouvelle version, et vos agents en cours ne sont pas touchés.", .updatePendingQuit: "Une mise à jour sera installée en quittant.",
        .newFolder: "Nouveau dossier…", .newFolderTitle: "Nom du dossier", .newFolderHelp: "Regrouper des projets dans un dossier nommé", .renameFolder: "Renommer le dossier", .moveToFolder: "Déplacer vers un dossier", .noFolder: "Aucun dossier", .dissolveFolder: "Dissoudre le dossier", .dissolveFolderHelp: "Supprime le dossier ; les projets restent",
        .folderOverviewHelp: "Afficher le contenu de ce dossier", .newProjectInFolder: "Ajouter un projet dans \"%@\"", .folderEmpty: "Aucun projet dans ce dossier — glissez-en un depuis la barre latérale.", .openProjectHelp: "Ouvrir ce projet", .terminalsCount: "%d terminaux", .terminalCountOne: "1 terminal", .latestNotifications: "Dernières notifications", .nothingReported: "Rien à signaler pour l'instant",
        .helpTab: "Aide", .helpBranchTitle: "Branche courante", .helpBranchDetail: "Chaque projet affiche la branche de son dépôt, actualisée pendant que vous travaillez", .helpSearch: "Rechercher fonctions et raccourcis", .helpNoResults: "Aucun résultat.", .helpMissing: "Il manque quelque chose ?", .requestFeature: "Proposer une fonction…", .requestFeatureHelp: "Ouvre une demande de fonctionnalité pré-remplie sur GitHub", .helpSectionTerminals: "Terminaux", .helpSectionWindows: "Fenêtres et navigation", .helpWhereSidebar: "Barre latérale", .helpWhereTabBar: "Barre d'onglets", .helpWhereContextMenu: "Menu contextuel", .helpWhereSettings: "Réglages", .helpWhereMenuBar: "Barre des menus", .helpWhereToolbar: "Barre d'outils", .newProjectInFolderShort: "Nouveau projet dans un dossier", .newProjectInFolderHelp: "Le + d'un dossier ajoute un projet à l'intérieur", .folderOverviewTitle: "Vue d'ensemble du dossier", .dropIntoFolderHelp: "Glissez un projet sur un dossier, ou entre deux lignes pour le placer exactement", .selectedProjectsShort: "Plusieurs projets à la fois", .helpMultiSelectDetail: "⌘/⇧-clic sélectionne un lot ; glissez-le ou agissez sur tout", .helpClusterTitle: "Vue en grille", .helpClusterDetail: "Afficher tous les terminaux d'un projet ; glissez un volet sur le bord d'un autre pour diviser", .helpDropTitle: "Ouvrir un dossier depuis le Finder", .helpCLITitle: "Piloter Planchette depuis un agent", .helpCLIDetail: "Une API socket et la CLI planchette dans chaque terminal : lister, ouvrir, envoyer, attendre, lire", .helpInstallOnQuitDetail: "Télécharge la mise à jour et l'installe à la prochaine fermeture, sans interrompre un tour en cours",
        .remindMe: "Me rappeler…", .remindMeHelp: "Silencieux jusque-là, puis un rappel", .remindIn1h: "Dans 1 heure", .remindIn2h: "Dans 2 heures", .remindTomorrow: "Demain 9:00", .remindCancel: "Annuler le rappel", .quietUntil: "silencieux jusqu’à %@", .reminder: "Rappel", .reminderBody: "Vous vouliez un rappel à ce sujet.", .markGroupReady: "Marquer le projet comme libre",
        .arrangements: "Agencements", .arrangementsHelp: "Agencements enregistrés de projets et de terminaux", .saveArrangement: "Enregistrer l’agencement…", .saveArrangementTitle: "Nom de l’agencement", .saveArrangementHelp: "Enregistrer les projets et terminaux de cette fenêtre comme agencement réutilisable", .openArrangement: "Ouvrir", .renameArrangement: "Renommer l’agencement", .deleteArrangement: "Supprimer l’agencement", .noArrangements: "Aucun agencement enregistré", .arrangementSummary: "%d projets · %d terminaux", .savedArrangements: "Agencements enregistrés",
        .selectedProjects: "%d projets sélectionnés", .markProjectsFree: "Marquer %d projets comme libres", .closeProjects: "Fermer %d projets", .closeProjectsBody: "Fermer %d projets et leurs %d terminaux ? Les sessions en cours seront terminées.", .dropIntoFolder: "Déplacer dans \"%@\"",
    ]

    // MARK: Spanish
    private static let es: [LKey: String] = [
        .langSystem: "Sistema", .settingsTitle: "Ajustes", .language: "Idioma",
        .appearance: "Apariencia", .aiSection: "IA",
        .appearanceLight: "Claro", .appearanceDark: "Oscuro", .appearanceHelp: "Claro, oscuro o seguir el sistema", .settingsHelp: "Abrir ajustes (⌘,)",
        .mainProjects: "Proyectos principales", .projects: "Proyectos", .sideProjects: "Proyectos secundarios",
        .makeFavorite: "Marcar como proyecto principal", .unmakeFavorite: "Quitar de principales",
        .color: "Color", .colorNone: "Ninguno", .rename: "Renombrar…",
        .moveToNewWindow: "Mover a una nueva ventana",
        .tags: "Etiquetas", .newTag: "Nueva etiqueta…", .removeAllTags: "Quitar todas",
        .startupCommand: "Comando de inicio…", .close: "Cerrar",
        .closeProject: "Cerrar proyecto", .closeProjectBody: "¿Cerrar «%@» y sus %d terminal(es)? Se finalizarán las sesiones en curso.",
        .renameGroup: "Renombrar grupo", .renameTerminal: "Renombrar terminal",
        .startupCommandPrompt: "Comando de inicio (se ejecuta de nuevo tras restaurar)",
        .newTagTitle: "Nueva etiqueta", .ok: "OK", .cancel: "Cancelar",
        .now: "ahora", .minutesShort: "%d min", .hoursShort: "%d h %d min",
        .noTerminalsInGroup: "No hay terminales en este grupo",
        .newTerminalHint: "⌘T abre un nuevo terminal",
        .attention: "Atención", .allQuiet: "Todo tranquilo — nada te espera.",
        .waitingForAnswer: "Esperando una respuesta", .doneSeeResult: "Listo — ver el resultado",
        .switcherPlaceholder: "Título, ruta, rama, grupo…",
        .newWindow: "Nueva ventana", .sessionMenu: "Sesión", .newTerminal: "Nuevo terminal…",
        .quickSwitcher: "Selector rápido", .jumpToWaiting: "Ir a la sesión en espera",
        .aiMenu: "IA", .aiActive: "Asistencia IA activa", .aiExplanation: "Muestra un resumen de una línea de en qué trabaja cada terminal (y un tema para agruparlos). Lee el transcript local de Claude de cada sesión y lo condensa con tu sesión de Claude existente — sin clave API, solo cuando está activo.", .summarizeAll: "Resumir todas las sesiones",
        .groupByTopic: "Agrupar por tema…",
        .aiAssist: "Asistencia IA", .aiAssistOn: "IA: activada", .aiAssistOff: "IA: desactivada",
        .aiAssistOnHelp: "Asistencia IA activa: las sesiones se resumen y pueden agruparse por tema",
        .aiAssistOffHelp: "Asistencia IA desactivada — actívala para resumir sesiones y agruparlas por tema",
        .inbox: "Bandeja", .inboxHelp: "Bandeja de atención: sesiones que preguntan o terminaron, las más urgentes primero",
        .mergeIntoMain: "Combinar en la ventana principal",
        .mergeIntoMainHelp: "Mover todos los grupos de esta ventana a la principal",
        .newTerminalHelp: "Abrir un nuevo terminal en esta ventana (⌘T)",
        .newWindowHelp: "Abrir una nueva ventana vacía (⌘N)",
        .quickSwitcherHelp: "Buscar y saltar a cualquier terminal (⌘K)",
        .jumpToWaitingHelp: "Ir a la sesión en espera más urgente (⌘⇧K)",
        .moveToNewWindowHelp: "Extraer este grupo a su propia ventana",
        .favoriteHelp: "Los proyectos principales tienen prioridad en la bandeja, notificaciones y selector",
        .tagsHelp: "Etiquetar este terminal (to test, review, …) — se busca en el selector",
        .startupCommandHelp: "Comando que se relanza tras restaurar (p. ej. npm run dev)",
        .renameHelp: "Poner un nombre personalizado",
        .colorHelp: "Elegir un color", .closeHelp: "Cerrar este terminal",
        .summarizeAllHelp: "Resumir cada sesión ahora con claude -p",
        .groupByTopicHelp: "Proponer agrupar sesiones por tema común (se aplica tras confirmar)",
        .languageHelp: "Idioma de la interfaz de Planchette",
        .tagline: "te lleva a la sesión que habla",
        .openFirstTerminal: "Abre tu primer terminal (⌘T)",
        .restoreTitle: "¿Restaurar la última sesión?",
        .restoreBody: "%d terminal(es) en %d grupo(s). Las sesiones de Claude se reanudan, los comandos de inicio se relanzan.",
        .restore: "Restaurar", .startFresh: "Empezar de nuevo",
        .noGroupingTitle: "Sin sugerencia de agrupación",
        .noGroupingBody: "Aún no hay suficientes sesiones con el mismo tema. Resume primero.",
        .groupByTopicTitle: "¿Agrupar por tema?",
        .group: "Agrupar",
        .allQuietShort: "Todo tranquilo", .openPlanchette: "Abrir Planchette", .asks: "pregunta",
        .chooseFolder: "Elige la carpeta del proyecto para el nuevo terminal",
        .windowMerged: "La ventana se combinó",
        .importMenu: "Importar", .importFromITerm: "Importar desde iTerm2", .importFromTerminal: "Importar desde Terminal.app",
        .importNothing: "no se encontraron terminales abiertos", .importNotRunning: "no se está ejecutando", .importNotAuthorized: "Automatización no permitida", .importAuthHint: "Permite que Planchette controle la app de terminal en Ajustes del Sistema → Privacidad y seguridad → Automatización, y vuelve a intentarlo.", .importFailed: "Error al importar", .importMenuHelp: "Abrir los directorios de trabajo de otra app de terminal como terminales de Planchette", .dropHint: "Suelta una carpeta aquí para abrir un terminal",
        .updates: "Actualizaciones", .checkForUpdates: "Buscar actualizaciones…", .autoUpdateCheck: "Buscar actualizaciones automáticamente", .autoUpdateHelp: "Comprobar en GitHub una nueva versión estable al iniciar",
        .updateAvailable: "La versión %@ está disponible", .updateAvailableBody: "Descarga la nueva versión y arrástrala a Aplicaciones.", .updateDownload: "Descargar",
        .updateUpToDate: "Estás al día", .updateCurrentVersion: "Versión actual: %@", .updateFailed: "Error al buscar actualizaciones",
        .updateInstallRelaunch: "Instalar y reiniciar", .updateInstallBody: "Planchette descargará la nueva versión, la instalará y se reiniciará.", .updateInstalling: "Instalando actualización…", .updateLater: "Más tarde", .updateNoReleases: "Aún no se encontraron versiones.", .updateDownloading: "Descargando… %d%%",
        .whatsNew: "Novedades", .andMoreChanges: "…y %d más",
        .stateReady: "Hecho", .stateFree: "Libre", .stateRunning: "En ejecución", .stateWaiting: "Esperando entrada", .stateError: "Error", .errorOccurred: "Ocurrió un error", .free: "libre",
        .generalTab: "General", .infoTab: "Información", .colorLegendTitle: "Colores de estado", .colorLegendIntro: "Cada terminal muestra un punto de estado de color:",
        .readyDesc: "el turno o comando terminó — un resultado espera tu revisión", .freeDesc: "prompt vacío, nada que revisar — este terminal está disponible", .needsYou: "Te necesita", .waitingSince: "esperando desde hace %d min", .runningDesc: "un agente o comando se está ejecutando", .waitingDesc: "el agente espera tu respuesta o aprobación", .errorDesc: "el último comando o agente terminó con un error",
        .newProject: "Nuevo proyecto…", .newProjectHelp: "Añadir un proyecto desde una carpeta", .addTerminalHelp: "Añadir un terminal en la carpeta de este proyecto",
        .fontSmaller: "Fuente más pequeña (⌘-)", .fontLarger: "Fuente más grande (⌘+)", .fontReset: "Restablecer tamaño (⌘0)",
        .minifySidebar: "Contraer barra lateral", .expandSidebar: "Expandir barra lateral", .markReady: "Marcar como listo", .notificationsPanel: "Notificaciones", .notificationsPanelHelp: "Mostrar el panel de notificaciones a la derecha", .onlyActive: "Solo activos", .clearReady: "Ocultar inactivos", .noProjectsYet: "Aún no hay proyectos — haz clic en + para añadir uno.", .menuCopy: "Copiar", .menuPaste: "Pegar", .menuSelectAll: "Seleccionar todo",
        .onlyUnread: "Solo no leídos", .onlyUnreadHelp: "Mostrar solo terminales cuyo último informe no has visto", .markAllRead: "Marcar todo como leído", .markRead: "Marcar como leído", .markUnread: "Marcar como no leído",
        .newWorktree: "Nuevo worktree…", .newWorktreeHelp: "Crear un worktree de git y abrirlo como proyecto", .worktreeBranchPrompt: "Rama para el nuevo worktree", .worktreeBasePrompt: "Base (vacío = HEAD actual)", .worktreeFailed: "No se pudo crear el worktree", .removeWorktreeTitle: "¿Eliminar la copia de trabajo?", .removeWorktreeBody: "¿Borrar el worktree en «%@»? Git se niega mientras haya cambios sin confirmar.", .removeWorktree: "Eliminar", .keepWorktree: "Conservar",
        .quitWhileRunningTitle: "¿Salir mientras los agentes trabajan?", .quitWhileRunningBody: "%d terminal(es) siguen en marcha. Al salir se interrumpen — una restauración recupera la conversación, pero no el trabajo en curso.", .quitAnyway: "Salir de todos modos",
        .durableSection: "Terminales duraderas", .durableActive: "Las terminales nuevas sobreviven a un reinicio", .durableHelp: "Ejecuta cada terminal nueva dentro de tmux, para que su agente siga trabajando cuando Planchette se cierra, falla o instala una actualización.", .durableExplanation: "Las terminales nuevas se ejecutan en tmux. Salir, instalar una actualización o incluso un fallo dejan al agente en marcha — al reabrir se vuelve a conectar con la sesión viva en lugar de reanudar una conversación. Reiniciar el equipo sí lo termina todo. Las terminales existentes mantienen cómo fueron creadas. El coste: tmux no transmite el protocolo de teclado del terminal, así que Shift+Enter le llega al agente como un Enter normal (envía en lugar de añadir una línea). Déjalo desactivado salvo que un agente deba sobrevivir a la app.", .durableMissingTmux: "Necesita tmux, que no se encontró. Instálalo (p. ej. brew install tmux) y vuelve a abrir los Ajustes.",
        .updateInstallOnQuit: "Instalar al salir", .updateStagedTitle: "La versión %@ está lista", .updateStagedBody: "Está descargada y verificada. Nada cambia hasta que salgas de Planchette — el próximo inicio usará la nueva versión y tus agentes en marcha no se tocan.", .updatePendingQuit: "Se instalará una actualización al salir.",
        .newFolder: "Nueva carpeta…", .newFolderTitle: "Nombre de la carpeta", .newFolderHelp: "Agrupa proyectos en una carpeta con nombre", .renameFolder: "Renombrar carpeta", .moveToFolder: "Mover a carpeta", .noFolder: "Sin carpeta", .dissolveFolder: "Deshacer carpeta", .dissolveFolderHelp: "Elimina la carpeta; los proyectos se quedan",
        .folderOverviewHelp: "Muestra lo que hay en esta carpeta", .newProjectInFolder: "Añadir un proyecto en \"%@\"", .folderEmpty: "Aún no hay proyectos en esta carpeta — arrastra uno desde la barra lateral.", .openProjectHelp: "Abrir este proyecto", .terminalsCount: "%d terminales", .terminalCountOne: "1 terminal", .latestNotifications: "Últimas notificaciones", .nothingReported: "Nada que informar todavía",
        .helpTab: "Ayuda", .helpBranchTitle: "Rama activa", .helpBranchDetail: "Cada proyecto muestra la rama de su copia, actualizada mientras trabajas", .helpSearch: "Buscar funciones y atajos", .helpNoResults: "No hay coincidencias.", .helpMissing: "¿Falta algo?", .requestFeature: "Proponer una función…", .requestFeatureHelp: "Abre una solicitud de función ya rellenada en GitHub", .helpSectionTerminals: "Terminales", .helpSectionWindows: "Ventanas y navegación", .helpWhereSidebar: "Barra lateral", .helpWhereTabBar: "Barra de pestañas", .helpWhereContextMenu: "Menú contextual", .helpWhereSettings: "Ajustes", .helpWhereMenuBar: "Barra de menús", .helpWhereToolbar: "Barra de herramientas", .newProjectInFolderShort: "Nuevo proyecto en una carpeta", .newProjectInFolderHelp: "El + de una carpeta añade un proyecto dentro", .folderOverviewTitle: "Vista de la carpeta", .dropIntoFolderHelp: "Arrastra un proyecto a una carpeta, o entre dos filas para colocarlo exactamente", .selectedProjectsShort: "Varios proyectos a la vez", .helpMultiSelectDetail: "⌘/⇧-clic selecciona un grupo; arrástralo o actúa sobre todos", .helpClusterTitle: "Vista en cuadrícula", .helpClusterDetail: "Mostrar todos los terminales de un proyecto; arrastra un panel al borde de otro para dividir", .helpDropTitle: "Abrir una carpeta desde el Finder", .helpCLITitle: "Controlar Planchette desde un agente", .helpCLIDetail: "Una API por socket y la CLI planchette en cada terminal: listar, abrir, enviar, esperar, leer", .helpInstallOnQuitDetail: "Descarga la actualización y la instala al salir, sin interrumpir ningún turno en marcha",
        .remindMe: "Recordármelo…", .remindMeHelp: "En silencio hasta entonces, luego un recordatorio", .remindIn1h: "En 1 hora", .remindIn2h: "En 2 horas", .remindTomorrow: "Mañana 9:00", .remindCancel: "Cancelar recordatorio", .quietUntil: "en silencio hasta %@", .reminder: "Recordatorio", .reminderBody: "Pediste que te lo recordara.", .markGroupReady: "Marcar proyecto como libre",
        .arrangements: "Disposiciones", .arrangementsHelp: "Disposiciones guardadas de proyectos y terminales", .saveArrangement: "Guardar disposición…", .saveArrangementTitle: "Nombre de la disposición", .saveArrangementHelp: "Guarda los proyectos y terminales de esta ventana como disposición reutilizable", .openArrangement: "Abrir", .renameArrangement: "Renombrar disposición", .deleteArrangement: "Eliminar disposición", .noArrangements: "Aún no hay disposiciones guardadas", .arrangementSummary: "%d proyectos · %d terminales", .savedArrangements: "Disposiciones guardadas",
        .selectedProjects: "%d proyectos seleccionados", .markProjectsFree: "Marcar %d proyectos como libres", .closeProjects: "Cerrar %d proyectos", .closeProjectsBody: "¿Cerrar %d proyectos y sus %d terminales? Esto termina las sesiones en marcha.", .dropIntoFolder: "Mover a \"%@\"",
    ]

    // MARK: Italian
    private static let it: [LKey: String] = [
        .langSystem: "Sistema", .settingsTitle: "Impostazioni", .language: "Lingua",
        .appearance: "Aspetto", .aiSection: "IA",
        .appearanceLight: "Chiaro", .appearanceDark: "Scuro", .appearanceHelp: "Chiaro, scuro o segui il sistema", .settingsHelp: "Apri impostazioni (⌘,)",
        .mainProjects: "Progetti principali", .projects: "Progetti", .sideProjects: "Progetti secondari",
        .makeFavorite: "Segna come progetto principale", .unmakeFavorite: "Rimuovi da principali",
        .color: "Colore", .colorNone: "Nessuno", .rename: "Rinomina…",
        .moveToNewWindow: "Sposta in una nuova finestra",
        .tags: "Tag", .newTag: "Nuovo tag…", .removeAllTags: "Rimuovi tutti",
        .startupCommand: "Comando di avvio…", .close: "Chiudi",
        .closeProject: "Chiudi progetto", .closeProjectBody: "Chiudere «%@» e i suoi %d terminale/i? Le sessioni in corso verranno terminate.",
        .renameGroup: "Rinomina gruppo", .renameTerminal: "Rinomina terminale",
        .startupCommandPrompt: "Comando di avvio (rieseguito dopo un ripristino)",
        .newTagTitle: "Nuovo tag", .ok: "OK", .cancel: "Annulla",
        .now: "adesso", .minutesShort: "%d min", .hoursShort: "%d h %d min",
        .noTerminalsInGroup: "Nessun terminale in questo gruppo",
        .newTerminalHint: "⌘T apre un nuovo terminale",
        .attention: "Attenzione", .allQuiet: "Tutto tranquillo — niente ti aspetta.",
        .waitingForAnswer: "In attesa di una risposta", .doneSeeResult: "Fatto — vedi il risultato",
        .switcherPlaceholder: "Titolo, percorso, branch, gruppo…",
        .newWindow: "Nuova finestra", .sessionMenu: "Sessione", .newTerminal: "Nuovo terminale…",
        .quickSwitcher: "Selettore rapido", .jumpToWaiting: "Vai alla sessione in attesa",
        .aiMenu: "IA", .aiActive: "Assistenza IA attiva", .aiExplanation: "Mostra un riassunto di una riga di cosa sta facendo ogni terminale (e un tema per raggrupparli). Legge il transcript locale di Claude di ogni sessione e lo condensa con il tuo accesso Claude esistente — nessuna chiave API, solo quando è attivo.", .summarizeAll: "Riassumi tutte le sessioni",
        .groupByTopic: "Raggruppa per tema…",
        .aiAssist: "Assistenza IA", .aiAssistOn: "IA: attiva", .aiAssistOff: "IA: disattivata",
        .aiAssistOnHelp: "Assistenza IA attiva: le sessioni vengono riassunte e possono essere raggruppate per tema",
        .aiAssistOffHelp: "Assistenza IA disattivata — attivala per riassumere le sessioni e raggrupparle per tema",
        .inbox: "In arrivo", .inboxHelp: "Casella attenzione: sessioni che chiedono o hanno finito, le più urgenti prima",
        .mergeIntoMain: "Unisci alla finestra principale",
        .mergeIntoMainHelp: "Sposta tutti i gruppi di questa finestra in quella principale",
        .newTerminalHelp: "Apri un nuovo terminale in questa finestra (⌘T)",
        .newWindowHelp: "Apri una nuova finestra vuota (⌘N)",
        .quickSwitcherHelp: "Cerca e salta a qualsiasi terminale (⌘K)",
        .jumpToWaitingHelp: "Vai alla sessione in attesa più urgente (⌘⇧K)",
        .moveToNewWindowHelp: "Estrai questo gruppo in una finestra propria",
        .favoriteHelp: "I progetti principali hanno priorità in casella, notifiche e selettore",
        .tagsHelp: "Tagga questo terminale (to test, review, …) — ricercabile nel selettore",
        .startupCommandHelp: "Comando rieseguito automaticamente dopo un ripristino (es. npm run dev)",
        .renameHelp: "Imposta un nome personalizzato",
        .colorHelp: "Scegli un colore", .closeHelp: "Chiudi questo terminale",
        .summarizeAllHelp: "Riassumi ogni sessione ora con claude -p",
        .groupByTopicHelp: "Proponi di raggruppare le sessioni per tema comune (applicato dopo conferma)",
        .languageHelp: "Lingua dell'interfaccia di Planchette",
        .tagline: "ti porta alla sessione che parla",
        .openFirstTerminal: "Apri il tuo primo terminale (⌘T)",
        .restoreTitle: "Ripristinare l'ultima sessione?",
        .restoreBody: "%d terminale/i in %d gruppo/i. Le sessioni Claude riprendono, i comandi di avvio si rieseguono.",
        .restore: "Ripristina", .startFresh: "Ricomincia",
        .noGroupingTitle: "Nessun suggerimento di raggruppamento",
        .noGroupingBody: "Non ci sono ancora abbastanza sessioni con lo stesso tema. Riassumi prima.",
        .groupByTopicTitle: "Raggruppare per tema?",
        .group: "Raggruppa",
        .allQuietShort: "Tutto tranquillo", .openPlanchette: "Apri Planchette", .asks: "chiede",
        .chooseFolder: "Scegli la cartella del progetto per il nuovo terminale",
        .windowMerged: "La finestra è stata unita",
        .importMenu: "Importa", .importFromITerm: "Importa da iTerm2", .importFromTerminal: "Importa da Terminal.app",
        .importNothing: "nessun terminale aperto trovato", .importNotRunning: "non è in esecuzione", .importNotAuthorized: "Automazione non consentita", .importAuthHint: "Consenti a Planchette di controllare l'app Terminale in Impostazioni di Sistema → Privacy e sicurezza → Automazione, poi riprova.", .importFailed: "Importazione non riuscita", .importMenuHelp: "Apri le directory di lavoro di un'altra app terminale come terminali Planchette", .dropHint: "Trascina qui una cartella per aprire un terminale",
        .updates: "Aggiornamenti", .checkForUpdates: "Cerca aggiornamenti…", .autoUpdateCheck: "Cerca aggiornamenti automaticamente", .autoUpdateHelp: "Controlla su GitHub una nuova versione stabile all'avvio",
        .updateAvailable: "La versione %@ è disponibile", .updateAvailableBody: "Scarica la nuova versione e trascinala in Applicazioni.", .updateDownload: "Scarica",
        .updateUpToDate: "Sei aggiornato", .updateCurrentVersion: "Versione attuale: %@", .updateFailed: "Ricerca aggiornamenti non riuscita",
        .updateInstallRelaunch: "Installa e riavvia", .updateInstallBody: "Planchette scaricherà la nuova versione, la installerà e si riavvierà.", .updateInstalling: "Installazione dell'aggiornamento…", .updateLater: "Più tardi", .updateNoReleases: "Nessuna versione trovata per ora.", .updateDownloading: "Download… %d%%",
        .whatsNew: "Novità", .andMoreChanges: "…e altre %d",
        .stateReady: "Fatto", .stateFree: "Libero", .stateRunning: "In esecuzione", .stateWaiting: "In attesa di input", .stateError: "Errore", .errorOccurred: "Si è verificato un errore", .free: "libero",
        .generalTab: "Generale", .infoTab: "Informazioni", .colorLegendTitle: "Colori di stato", .colorLegendIntro: "Ogni terminale mostra un pallino di stato colorato:",
        .readyDesc: "il turno o comando è terminato — un risultato attende la tua revisione", .freeDesc: "prompt vuoto, niente da rivedere — questo terminale è disponibile", .needsYou: "Ha bisogno di te", .waitingSince: "in attesa da %d min", .runningDesc: "un agente o comando è in esecuzione", .waitingDesc: "l'agente attende la tua risposta o approvazione", .errorDesc: "l'ultimo comando o agente è terminato con un errore",
        .newProject: "Nuovo progetto…", .newProjectHelp: "Aggiungi un progetto da una cartella", .addTerminalHelp: "Aggiungi un terminale nella cartella di questo progetto",
        .fontSmaller: "Carattere più piccolo (⌘-)", .fontLarger: "Carattere più grande (⌘+)", .fontReset: "Reimposta dimensione (⌘0)",
        .minifySidebar: "Comprimi barra laterale", .expandSidebar: "Espandi barra laterale", .markReady: "Segna come pronto", .notificationsPanel: "Notifiche", .notificationsPanelHelp: "Mostra il pannello notifiche a destra", .onlyActive: "Solo attivi", .clearReady: "Nascondi inattivi", .noProjectsYet: "Nessun progetto — fai clic su + per aggiungerne uno.", .menuCopy: "Copia", .menuPaste: "Incolla", .menuSelectAll: "Seleziona tutto",
        .onlyUnread: "Solo non letti", .onlyUnreadHelp: "Mostra solo i terminali il cui ultimo messaggio non è stato visto", .markAllRead: "Segna tutto come letto", .markRead: "Segna come letto", .markUnread: "Segna come non letto",
        .newWorktree: "Nuovo worktree…", .newWorktreeHelp: "Crea un worktree git e aprilo come progetto", .worktreeBranchPrompt: "Branch per il nuovo worktree", .worktreeBasePrompt: "Base (vuoto = HEAD attuale)", .worktreeFailed: "Impossibile creare il worktree", .removeWorktreeTitle: "Rimuovere la copia di lavoro?", .removeWorktreeBody: "Eliminare il worktree in «%@»? Git rifiuta finché contiene modifiche non committate.", .removeWorktree: "Rimuovi", .keepWorktree: "Mantieni",
        .quitWhileRunningTitle: "Uscire mentre gli agent lavorano?", .quitWhileRunningBody: "%d terminale/i sono ancora in esecuzione. Uscendo vengono interrotti — un ripristino recupera la conversazione, non il lavoro in corso.", .quitAnyway: "Esci comunque",
        .durableSection: "Terminali durevoli", .durableActive: "I nuovi terminali sopravvivono a un riavvio", .durableHelp: "Esegue ogni nuovo terminale dentro tmux, così il suo agent continua a lavorare quando Planchette esce, va in crash o installa un aggiornamento.", .durableExplanation: "I nuovi terminali girano in tmux. Uscire, installare un aggiornamento o persino un crash lasciano l'agent in esecuzione — riaprendo ci si ricollega alla sessione viva invece di riprendere una conversazione. Un riavvio del Mac termina comunque tutto. I terminali esistenti restano come sono stati creati. Il prezzo: tmux non inoltra il protocollo di tastiera del terminale, quindi Shift+Invio arriva all'agent come un Invio normale (invia invece di aggiungere una riga). Lascialo disattivato a meno che un agent debba sopravvivere all'app.", .durableMissingTmux: "Richiede tmux, che non è stato trovato. Installalo (es. brew install tmux) e riapri le Impostazioni.",
        .updateInstallOnQuit: "Installa all'uscita", .updateStagedTitle: "La versione %@ è pronta", .updateStagedBody: "È scaricata e verificata. Nulla cambia finché non esci da Planchette — al prossimo avvio parte la nuova versione e gli agent in esecuzione restano intatti.", .updatePendingQuit: "Un aggiornamento verrà installato all'uscita.",
        .newFolder: "Nuova cartella…", .newFolderTitle: "Nome della cartella", .newFolderHelp: "Raggruppa i progetti in una cartella con nome", .renameFolder: "Rinomina cartella", .moveToFolder: "Sposta nella cartella", .noFolder: "Nessuna cartella", .dissolveFolder: "Sciogli cartella", .dissolveFolderHelp: "Rimuove la cartella; i progetti restano",
        .folderOverviewHelp: "Mostra cosa c'è in questa cartella", .newProjectInFolder: "Aggiungi un progetto in \"%@\"", .folderEmpty: "Nessun progetto in questa cartella — trascinane uno dalla barra laterale.", .openProjectHelp: "Apri questo progetto", .terminalsCount: "%d terminali", .terminalCountOne: "1 terminale", .latestNotifications: "Ultime notifiche", .nothingReported: "Ancora nessuna segnalazione",
        .helpTab: "Aiuto", .helpBranchTitle: "Ramo attivo", .helpBranchDetail: "Ogni progetto mostra il ramo del suo checkout, aggiornato mentre lavori", .helpSearch: "Cerca funzioni e scorciatoie", .helpNoResults: "Nessun risultato.", .helpMissing: "Manca qualcosa?", .requestFeature: "Proponi una funzione…", .requestFeatureHelp: "Apre una richiesta di funzionalità precompilata su GitHub", .helpSectionTerminals: "Terminali", .helpSectionWindows: "Finestre e navigazione", .helpWhereSidebar: "Barra laterale", .helpWhereTabBar: "Barra dei tab", .helpWhereContextMenu: "Menu contestuale", .helpWhereSettings: "Impostazioni", .helpWhereMenuBar: "Barra dei menu", .helpWhereToolbar: "Barra strumenti", .newProjectInFolderShort: "Nuovo progetto in una cartella", .newProjectInFolderHelp: "Il + su una cartella aggiunge un progetto al suo interno", .folderOverviewTitle: "Panoramica della cartella", .dropIntoFolderHelp: "Trascina un progetto su una cartella, o tra due righe per collocarlo esattamente", .selectedProjectsShort: "Più progetti insieme", .helpMultiSelectDetail: "⌘/⇧-clic seleziona un gruppo; trascinalo o agisci su tutti", .helpClusterTitle: "Vista a griglia", .helpClusterDetail: "Mostra tutti i terminali di un progetto; trascina un riquadro sul bordo di un altro per dividere", .helpDropTitle: "Aprire una cartella dal Finder", .helpCLITitle: "Pilotare Planchette da un agente", .helpCLIDetail: "Un'API su socket e la CLI planchette in ogni terminale: elencare, aprire, inviare, attendere, leggere", .helpInstallOnQuitDetail: "Scarica l'aggiornamento e lo installa alla prossima chiusura, senza interrompere un turno in corso",
        .remindMe: "Ricordamelo…", .remindMeHelp: "In silenzio fino ad allora, poi un promemoria", .remindIn1h: "Tra 1 ora", .remindIn2h: "Tra 2 ore", .remindTomorrow: "Domani 9:00", .remindCancel: "Annulla promemoria", .quietUntil: "in silenzio fino alle %@", .reminder: "Promemoria", .reminderBody: "Volevi un promemoria su questo.", .markGroupReady: "Segna il progetto come libero",
        .arrangements: "Disposizioni", .arrangementsHelp: "Disposizioni salvate di progetti e terminali", .saveArrangement: "Salva disposizione…", .saveArrangementTitle: "Nome della disposizione", .saveArrangementHelp: "Salva i progetti e i terminali di questa finestra come disposizione riutilizzabile", .openArrangement: "Apri", .renameArrangement: "Rinomina disposizione", .deleteArrangement: "Elimina disposizione", .noArrangements: "Nessuna disposizione salvata", .arrangementSummary: "%d progetti · %d terminali", .savedArrangements: "Disposizioni salvate",
        .selectedProjects: "%d progetti selezionati", .markProjectsFree: "Segna %d progetti come liberi", .closeProjects: "Chiudi %d progetti", .closeProjectsBody: "Chiudere %d progetti e i loro %d terminali? Le sessioni in esecuzione verranno terminate.", .dropIntoFolder: "Sposta in \"%@\"",
    ]

    // MARK: Dutch
    private static let nl: [LKey: String] = [
        .langSystem: "Systeem", .settingsTitle: "Instellingen", .language: "Taal",
        .appearance: "Weergave", .aiSection: "AI",
        .appearanceLight: "Licht", .appearanceDark: "Donker", .appearanceHelp: "Licht, donker of het systeem volgen", .settingsHelp: "Instellingen openen (⌘,)",
        .mainProjects: "Hoofdprojecten", .projects: "Projecten", .sideProjects: "Nevenprojecten",
        .makeFavorite: "Als hoofdproject markeren", .unmakeFavorite: "Hoofdproject verwijderen",
        .color: "Kleur", .colorNone: "Geen", .rename: "Hernoemen…",
        .moveToNewWindow: "Naar nieuw venster verplaatsen",
        .tags: "Tags", .newTag: "Nieuwe tag…", .removeAllTags: "Alle verwijderen",
        .startupCommand: "Opstartcommando…", .close: "Sluiten",
        .closeProject: "Project sluiten", .closeProjectBody: "\"%@\" en de %d terminal(s) sluiten? Actieve sessies worden beëindigd.",
        .renameGroup: "Groep hernoemen", .renameTerminal: "Terminal hernoemen",
        .startupCommandPrompt: "Opstartcommando (draait opnieuw na een herstel)",
        .newTagTitle: "Nieuwe tag", .ok: "OK", .cancel: "Annuleren",
        .now: "nu", .minutesShort: "%d min", .hoursShort: "%d u %d min",
        .noTerminalsInGroup: "Geen terminals in deze groep",
        .newTerminalHint: "⌘T opent een nieuwe terminal",
        .attention: "Aandacht", .allQuiet: "Alles rustig — niets wacht op je.",
        .waitingForAnswer: "Wacht op een antwoord", .doneSeeResult: "Klaar — bekijk het resultaat",
        .switcherPlaceholder: "Titel, pad, branch, groep…",
        .newWindow: "Nieuw venster", .sessionMenu: "Sessie", .newTerminal: "Nieuwe terminal…",
        .quickSwitcher: "Snelkiezer", .jumpToWaiting: "Ga naar wachtende sessie",
        .aiMenu: "AI", .aiActive: "AI-assistentie actief", .aiExplanation: "Toont een samenvatting van één regel van waar elke terminal aan werkt (en een onderwerp om ze te groeperen). Leest het lokale Claude-transcript van elke sessie en condenseert het met je bestaande Claude-login — geen API-sleutel, alleen actief wanneer ingeschakeld.", .summarizeAll: "Alle sessies nu samenvatten",
        .groupByTopic: "Groeperen op thema…",
        .aiAssist: "AI-assistentie", .aiAssistOn: "AI: aan", .aiAssistOff: "AI: uit",
        .aiAssistOnHelp: "AI-assistentie aan: sessies worden samengevat en kunnen op thema worden gegroepeerd",
        .aiAssistOffHelp: "AI-assistentie uit — zet aan om sessies samen te vatten en op thema te groeperen",
        .inbox: "Postvak", .inboxHelp: "Aandachtspostvak: sessies die vragen of klaar zijn, meest dringende eerst",
        .mergeIntoMain: "Samenvoegen in hoofdvenster",
        .mergeIntoMainHelp: "Alle groepen van dit venster naar het hoofdvenster verplaatsen",
        .newTerminalHelp: "Open een nieuwe terminal in dit venster (⌘T)",
        .newWindowHelp: "Open een nieuw, leeg venster (⌘N)",
        .quickSwitcherHelp: "Zoek en spring naar een terminal (⌘K)",
        .jumpToWaitingHelp: "Ga naar de meest dringende wachtende sessie (⌘⇧K)",
        .moveToNewWindowHelp: "Trek deze groep in een eigen venster",
        .favoriteHelp: "Hoofdprojecten hebben voorrang in postvak, meldingen en snelkiezer",
        .tagsHelp: "Tag deze terminal (to test, review, …) — doorzoekbaar in de snelkiezer",
        .startupCommandHelp: "Commando dat automatisch opnieuw draait na een herstel (bijv. npm run dev)",
        .renameHelp: "Stel een eigen naam in",
        .colorHelp: "Kies een kleur", .closeHelp: "Deze terminal sluiten",
        .summarizeAllHelp: "Vat elke sessie nu samen met claude -p",
        .groupByTopicHelp: "Stel voor sessies met een gedeeld thema te groeperen (pas toe na bevestiging)",
        .languageHelp: "Taal van de Planchette-interface",
        .tagline: "brengt je naar de sessie die spreekt",
        .openFirstTerminal: "Open je eerste terminal (⌘T)",
        .restoreTitle: "Laatste sessie herstellen?",
        .restoreBody: "%d terminal(s) in %d groep(en). Claude-sessies hervatten, opstartcommando's draaien opnieuw.",
        .restore: "Herstellen", .startFresh: "Opnieuw beginnen",
        .noGroupingTitle: "Geen groeperingssuggestie",
        .noGroupingBody: "Nog niet genoeg sessies met hetzelfde thema. Vat eerst samen.",
        .groupByTopicTitle: "Op thema groeperen?",
        .group: "Groeperen",
        .allQuietShort: "Alles rustig", .openPlanchette: "Planchette openen", .asks: "vraagt",
        .chooseFolder: "Kies de projectmap voor de nieuwe terminal",
        .windowMerged: "Venster is samengevoegd",
        .importMenu: "Importeren", .importFromITerm: "Importeren uit iTerm2", .importFromTerminal: "Importeren uit Terminal.app",
        .importNothing: "geen open terminals gevonden", .importNotRunning: "is niet actief", .importNotAuthorized: "Automatisering niet toegestaan", .importAuthHint: "Sta Planchette toe de terminal-app te bedienen in Systeeminstellingen → Privacy en beveiliging → Automatisering en probeer opnieuw.", .importFailed: "Importeren mislukt", .importMenuHelp: "De werkmappen van een andere terminal-app als Planchette-terminals openen", .dropHint: "Sleep een map hierheen om een terminal te openen",
        .updates: "Updates", .checkForUpdates: "Zoeken naar updates…", .autoUpdateCheck: "Automatisch naar updates zoeken", .autoUpdateHelp: "Bij het starten op GitHub naar een nieuwere stabiele versie zoeken",
        .updateAvailable: "Versie %@ is beschikbaar", .updateAvailableBody: "Download de nieuwe versie en sleep die naar Programma's.", .updateDownload: "Downloaden",
        .updateUpToDate: "Je bent up-to-date", .updateCurrentVersion: "Huidige versie: %@", .updateFailed: "Zoeken naar updates mislukt",
        .updateInstallRelaunch: "Installeren en herstarten", .updateInstallBody: "Planchette downloadt de nieuwe versie, installeert die en start opnieuw op.", .updateInstalling: "Update installeren…", .updateLater: "Later", .updateNoReleases: "Nog geen releases gevonden.", .updateDownloading: "Update downloaden… %d%%",
        .whatsNew: "Wat is er nieuw", .andMoreChanges: "…en %d meer",
        .stateReady: "Klaar", .stateFree: "Vrij", .stateRunning: "Actief", .stateWaiting: "Wacht op invoer", .stateError: "Fout", .errorOccurred: "Er is een fout opgetreden", .free: "vrij",
        .generalTab: "Algemeen", .infoTab: "Informatie", .colorLegendTitle: "Statuskleuren", .colorLegendIntro: "Elk terminal toont een gekleurde statusstip:",
        .readyDesc: "de beurt of opdracht is klaar — een resultaat wacht op je blik", .freeDesc: "lege prompt, niets te reviewen — deze terminal is beschikbaar", .needsYou: "Heeft je nodig", .waitingSince: "wacht al %d min", .runningDesc: "een agent of opdracht is actief", .waitingDesc: "de agent wacht op je antwoord of goedkeuring", .errorDesc: "de laatste opdracht of agent eindigde met een fout",
        .newProject: "Nieuw project…", .newProjectHelp: "Een project vanuit een map toevoegen", .addTerminalHelp: "Een terminal in de map van dit project toevoegen",
        .fontSmaller: "Kleiner lettertype (⌘-)", .fontLarger: "Groter lettertype (⌘+)", .fontReset: "Lettergrootte herstellen (⌘0)",
        .minifySidebar: "Zijbalk inklappen", .expandSidebar: "Zijbalk uitklappen", .markReady: "Als gereed markeren", .notificationsPanel: "Meldingen", .notificationsPanelHelp: "Toon het meldingenpaneel rechts", .onlyActive: "Alleen actief", .clearReady: "Rustige verbergen", .noProjectsYet: "Nog geen projecten — klik op + om er een toe te voegen.", .menuCopy: "Kopieer", .menuPaste: "Plak", .menuSelectAll: "Alles selecteren",
        .onlyUnread: "Alleen ongelezen", .onlyUnreadHelp: "Alleen terminals tonen waarvan je de laatste melding niet hebt gezien", .markAllRead: "Alles als gelezen markeren", .markRead: "Als gelezen markeren", .markUnread: "Als ongelezen markeren",
        .newWorktree: "Nieuwe worktree…", .newWorktreeHelp: "Een git-worktree maken en als project openen", .worktreeBranchPrompt: "Branch voor de nieuwe worktree", .worktreeBasePrompt: "Basis (leeg = huidige HEAD)", .worktreeFailed: "Kon de worktree niet aanmaken", .removeWorktreeTitle: "Werkkopie verwijderen?", .removeWorktreeBody: "De worktree in \"%@\" verwijderen? Git weigert zolang er niet-vastgelegde wijzigingen zijn.", .removeWorktree: "Verwijderen", .keepWorktree: "Bewaren",
        .quitWhileRunningTitle: "Afsluiten terwijl agents werken?", .quitWhileRunningBody: "%d terminal(s) zijn nog bezig. Afsluiten breekt ze af — een herstel brengt het gesprek terug, maar niet het lopende werk.", .quitAnyway: "Toch afsluiten",
        .durableSection: "Duurzame terminals", .durableActive: "Nieuwe terminals overleven een herstart", .durableHelp: "Draait elke nieuwe terminal in tmux, zodat de agent doorwerkt wanneer Planchette afsluit, crasht of een update installeert.", .durableExplanation: "Nieuwe terminals draaien in tmux. Afsluiten, een update installeren of zelfs een crash laten de agent doorlopen — bij het heropenen wordt opnieuw verbonden met de levende sessie in plaats van een gesprek te hervatten. Een herstart van de Mac beëindigt alsnog alles. Bestaande terminals blijven zoals ze zijn aangemaakt. De prijs: tmux geeft het toetsenbordprotocol van de terminal niet door, dus Shift+Enter komt bij de agent aan als een gewone Enter (het verstuurt in plaats van een regel toe te voegen). Laat dit uit tenzij een agent de app moet overleven.", .durableMissingTmux: "Vereist tmux, dat niet gevonden is. Installeer het (bijv. brew install tmux) en open Instellingen opnieuw.",
        .updateInstallOnQuit: "Installeren bij afsluiten", .updateStagedTitle: "Versie %@ is klaar", .updateStagedBody: "Hij is gedownload en gecontroleerd. Er verandert niets tot je Planchette afsluit — de volgende start gebruikt de nieuwe versie en je lopende agents blijven ongemoeid.", .updatePendingQuit: "Een update wordt geïnstalleerd bij afsluiten.",
        .newFolder: "Nieuwe map…", .newFolderTitle: "Naam van de map", .newFolderHelp: "Projecten in een map met naam groeperen", .renameFolder: "Map hernoemen", .moveToFolder: "Naar map verplaatsen", .noFolder: "Geen map", .dissolveFolder: "Map opheffen", .dissolveFolderHelp: "Verwijdert de map; de projecten blijven",
        .folderOverviewHelp: "Laat zien wat er in deze map zit", .newProjectInFolder: "Een project in \"%@\" toevoegen", .folderEmpty: "Nog geen projecten in deze map — sleep er een vanuit de zijbalk in.", .openProjectHelp: "Dit project openen", .terminalsCount: "%d terminals", .terminalCountOne: "1 terminal", .latestNotifications: "Nieuwste meldingen", .nothingReported: "Nog niets gemeld",
        .helpTab: "Help", .helpBranchTitle: "Uitgecheckte branch", .helpBranchDetail: "Elk project toont de branch van zijn checkout, terwijl je werkt bijgewerkt", .helpSearch: "Zoek functies en sneltoetsen", .helpNoResults: "Niets gevonden.", .helpMissing: "Mis je iets?", .requestFeature: "Functie voorstellen…", .requestFeatureHelp: "Opent een vooringevuld feature request op GitHub", .helpSectionTerminals: "Terminals", .helpSectionWindows: "Vensters & navigatie", .helpWhereSidebar: "Zijbalk", .helpWhereTabBar: "Tabbalk", .helpWhereContextMenu: "Rechtsklikmenu", .helpWhereSettings: "Instellingen", .helpWhereMenuBar: "Menubalk", .helpWhereToolbar: "Werkbalk", .newProjectInFolderShort: "Nieuw project in een map", .newProjectInFolderHelp: "De + op een map maakt daarin een project aan", .folderOverviewTitle: "Mapoverzicht", .dropIntoFolderHelp: "Sleep een project op een map, of tussen twee rijen om het precies te plaatsen", .selectedProjectsShort: "Meerdere projecten tegelijk", .helpMultiSelectDetail: "⌘/⇧-klik kiest een groep; sleep die of pas alles in één keer toe", .helpClusterTitle: "Rasterweergave", .helpClusterDetail: "Alle terminals van een project tegelijk tonen; sleep een paneel naar de rand van een ander om te splitsen", .helpDropTitle: "Een map openen vanuit Finder", .helpCLITitle: "Planchette aansturen vanuit een agent", .helpCLIDetail: "Een socket-API en de planchette-CLI in elke terminal: lijsten, openen, prompten, wachten, lezen", .helpInstallOnQuitDetail: "Downloadt de update en installeert die bij het afsluiten, zonder een lopende beurt te onderbreken",
        .remindMe: "Herinner me…", .remindMeHelp: "Tot dan stil, daarna een herinnering", .remindIn1h: "Over 1 uur", .remindIn2h: "Over 2 uur", .remindTomorrow: "Morgen 9:00", .remindCancel: "Herinnering annuleren", .quietUntil: "stil tot %@", .reminder: "Herinnering", .reminderBody: "Je wilde hieraan herinnerd worden.", .markGroupReady: "Project als vrij markeren",
        .arrangements: "Indelingen", .arrangementsHelp: "Opgeslagen indelingen van projecten en terminals", .saveArrangement: "Indeling opslaan…", .saveArrangementTitle: "Naam van de indeling", .saveArrangementHelp: "Sla de projecten en terminals van dit venster op als herbruikbare indeling", .openArrangement: "Openen", .renameArrangement: "Indeling hernoemen", .deleteArrangement: "Indeling verwijderen", .noArrangements: "Nog geen indelingen opgeslagen", .arrangementSummary: "%d projecten · %d terminals", .savedArrangements: "Opgeslagen indelingen",
        .selectedProjects: "%d projecten geselecteerd", .markProjectsFree: "%d projecten als vrij markeren", .closeProjects: "%d projecten sluiten", .closeProjectsBody: "%d projecten en hun %d terminals sluiten? Lopende sessies worden beëindigd.", .dropIntoFolder: "Naar \"%@\" verplaatsen",
    ]

    // MARK: Portuguese
    private static let pt: [LKey: String] = [
        .langSystem: "Sistema", .settingsTitle: "Definições", .language: "Idioma",
        .appearance: "Aparência", .aiSection: "IA",
        .appearanceLight: "Claro", .appearanceDark: "Escuro", .appearanceHelp: "Claro, escuro ou seguir o sistema", .settingsHelp: "Abrir definições (⌘,)",
        .mainProjects: "Projetos principais", .projects: "Projetos", .sideProjects: "Projetos secundários",
        .makeFavorite: "Marcar como projeto principal", .unmakeFavorite: "Remover dos principais",
        .color: "Cor", .colorNone: "Nenhuma", .rename: "Renomear…",
        .moveToNewWindow: "Mover para nova janela",
        .tags: "Etiquetas", .newTag: "Nova etiqueta…", .removeAllTags: "Remover todas",
        .startupCommand: "Comando de arranque…", .close: "Fechar",
        .closeProject: "Fechar projeto", .closeProjectBody: "Fechar \"%@\" e os seus %d terminal(is)? As sessões em curso serão terminadas.",
        .renameGroup: "Renomear grupo", .renameTerminal: "Renomear terminal",
        .startupCommandPrompt: "Comando de arranque (executado de novo após restauro)",
        .newTagTitle: "Nova etiqueta", .ok: "OK", .cancel: "Cancelar",
        .now: "agora", .minutesShort: "%d min", .hoursShort: "%d h %d min",
        .noTerminalsInGroup: "Sem terminais neste grupo",
        .newTerminalHint: "⌘T abre um novo terminal",
        .attention: "Atenção", .allQuiet: "Tudo calmo — nada espera por ti.",
        .waitingForAnswer: "À espera de uma resposta", .doneSeeResult: "Concluído — ver o resultado",
        .switcherPlaceholder: "Título, caminho, branch, grupo…",
        .newWindow: "Nova janela", .sessionMenu: "Sessão", .newTerminal: "Novo terminal…",
        .quickSwitcher: "Seletor rápido", .jumpToWaiting: "Ir para a sessão em espera",
        .aiMenu: "IA", .aiActive: "Assistência IA ativa", .aiExplanation: "Mostra um resumo de uma linha do que cada terminal está a fazer (e um tema para os agrupar). Lê o transcript local do Claude de cada sessão e condensa-o com o teu login existente do Claude — sem chave de API, só corre quando está ativo.", .summarizeAll: "Resumir todas as sessões",
        .groupByTopic: "Agrupar por tema…",
        .aiAssist: "Assistência IA", .aiAssistOn: "IA: ligada", .aiAssistOff: "IA: desligada",
        .aiAssistOnHelp: "Assistência IA ativa: as sessões são resumidas e podem ser agrupadas por tema",
        .aiAssistOffHelp: "Assistência IA desativada — ativa para resumir sessões e agrupá-las por tema",
        .inbox: "Caixa", .inboxHelp: "Caixa de atenção: sessões que perguntam ou terminaram, as mais urgentes primeiro",
        .mergeIntoMain: "Fundir na janela principal",
        .mergeIntoMainHelp: "Mover todos os grupos desta janela para a principal",
        .newTerminalHelp: "Abrir um novo terminal nesta janela (⌘T)",
        .newWindowHelp: "Abrir uma nova janela vazia (⌘N)",
        .quickSwitcherHelp: "Procurar e saltar para qualquer terminal (⌘K)",
        .jumpToWaitingHelp: "Ir para a sessão em espera mais urgente (⌘⇧K)",
        .moveToNewWindowHelp: "Extrair este grupo para a sua própria janela",
        .favoriteHelp: "Os projetos principais têm prioridade na caixa, notificações e seletor",
        .tagsHelp: "Etiquetar este terminal (to test, review, …) — pesquisável no seletor",
        .startupCommandHelp: "Comando reexecutado automaticamente após um restauro (ex. npm run dev)",
        .renameHelp: "Definir um nome personalizado",
        .colorHelp: "Escolher uma cor", .closeHelp: "Fechar este terminal",
        .summarizeAllHelp: "Resumir cada sessão agora com claude -p",
        .groupByTopicHelp: "Propor agrupar sessões por tema comum (aplicado após confirmação)",
        .languageHelp: "Idioma da interface do Planchette",
        .tagline: "leva-te à sessão que fala",
        .openFirstTerminal: "Abre o teu primeiro terminal (⌘T)",
        .restoreTitle: "Restaurar a última sessão?",
        .restoreBody: "%d terminal(is) em %d grupo(s). As sessões Claude retomam, os comandos de arranque executam de novo.",
        .restore: "Restaurar", .startFresh: "Começar de novo",
        .noGroupingTitle: "Sem sugestão de agrupamento",
        .noGroupingBody: "Ainda não há sessões suficientes com o mesmo tema. Resume primeiro.",
        .groupByTopicTitle: "Agrupar por tema?",
        .group: "Agrupar",
        .allQuietShort: "Tudo calmo", .openPlanchette: "Abrir Planchette", .asks: "pergunta",
        .chooseFolder: "Escolhe a pasta do projeto para o novo terminal",
        .windowMerged: "A janela foi fundida",
        .importMenu: "Importar", .importFromITerm: "Importar do iTerm2", .importFromTerminal: "Importar do Terminal.app",
        .importNothing: "nenhum terminal aberto encontrado", .importNotRunning: "não está em execução", .importNotAuthorized: "Automação não permitida", .importAuthHint: "Permite que o Planchette controle a app de terminal em Definições do Sistema → Privacidade e segurança → Automação e tenta de novo.", .importFailed: "Falha na importação", .importMenuHelp: "Abrir os diretórios de trabalho de outra app de terminal como terminais do Planchette", .dropHint: "Arrasta uma pasta para aqui para abrir um terminal",
        .updates: "Atualizações", .checkForUpdates: "Procurar atualizações…", .autoUpdateCheck: "Procurar atualizações automaticamente", .autoUpdateHelp: "Verificar no GitHub uma nova versão estável ao iniciar",
        .updateAvailable: "A versão %@ está disponível", .updateAvailableBody: "Descarrega a nova versão e arrasta-a para Aplicações.", .updateDownload: "Descarregar",
        .updateUpToDate: "Estás atualizado", .updateCurrentVersion: "Versão atual: %@", .updateFailed: "Falha ao procurar atualizações",
        .updateInstallRelaunch: "Instalar e reiniciar", .updateInstallBody: "O Planchette vai descarregar a nova versão, instalá-la e reiniciar.", .updateInstalling: "A instalar atualização…", .updateLater: "Mais tarde", .updateNoReleases: "Ainda não foram encontradas versões.", .updateDownloading: "A descarregar… %d%%",
        .whatsNew: "Novidades", .andMoreChanges: "…e %d mais",
        .stateReady: "Concluído", .stateFree: "Livre", .stateRunning: "Em execução", .stateWaiting: "À espera de entrada", .stateError: "Erro", .errorOccurred: "Ocorreu um erro", .free: "livre",
        .generalTab: "Geral", .infoTab: "Informação", .colorLegendTitle: "Cores de estado", .colorLegendIntro: "Cada terminal mostra um ponto de estado colorido:",
        .readyDesc: "o turno ou comando terminou — um resultado aguarda a tua revisão", .freeDesc: "prompt vazio, nada para rever — este terminal está disponível", .needsYou: "Precisa de ti", .waitingSince: "à espera há %d min", .runningDesc: "um agente ou comando está em execução", .waitingDesc: "o agente aguarda a tua resposta ou aprovação", .errorDesc: "o último comando ou agente terminou com um erro",
        .newProject: "Novo projeto…", .newProjectHelp: "Adicionar um projeto a partir de uma pasta", .addTerminalHelp: "Adicionar um terminal na pasta deste projeto",
        .fontSmaller: "Fonte menor (⌘-)", .fontLarger: "Fonte maior (⌘+)", .fontReset: "Repor tamanho da fonte (⌘0)",
        .minifySidebar: "Recolher barra lateral", .expandSidebar: "Expandir barra lateral", .markReady: "Marcar como pronto", .notificationsPanel: "Notificações", .notificationsPanelHelp: "Mostrar o painel de notificações à direita", .onlyActive: "Apenas ativos", .clearReady: "Ocultar inativos", .noProjectsYet: "Ainda sem projetos — clica em + para adicionar um.", .menuCopy: "Copiar", .menuPaste: "Colar", .menuSelectAll: "Selecionar tudo",
        .onlyUnread: "Apenas não lidos", .onlyUnreadHelp: "Mostrar só terminais cujo último relatório não viste", .markAllRead: "Marcar tudo como lido", .markRead: "Marcar como lido", .markUnread: "Marcar como não lido",
        .newWorktree: "Novo worktree…", .newWorktreeHelp: "Criar um worktree do git e abri-lo como projeto", .worktreeBranchPrompt: "Branch para o novo worktree", .worktreeBasePrompt: "Base (vazio = HEAD atual)", .worktreeFailed: "Não foi possível criar o worktree", .removeWorktreeTitle: "Remover a cópia de trabalho?", .removeWorktreeBody: "Apagar o worktree em \"%@\"? O git recusa enquanto houver alterações não submetidas.", .removeWorktree: "Remover", .keepWorktree: "Manter",
        .quitWhileRunningTitle: "Sair enquanto os agentes trabalham?", .quitWhileRunningBody: "%d terminal(is) ainda estão a correr. Sair interrompe-os — um restauro traz a conversa de volta, mas não o trabalho em curso.", .quitAnyway: "Sair mesmo assim",
        .durableSection: "Terminais duráveis", .durableActive: "Os novos terminais sobrevivem a um reinício", .durableHelp: "Executa cada novo terminal dentro do tmux, para que o seu agente continue a trabalhar quando o Planchette sai, falha ou instala uma atualização.", .durableExplanation: "Os novos terminais correm em tmux. Sair, instalar uma atualização ou até uma falha deixam o agente a correr — ao reabrir, liga-se de novo à sessão viva em vez de retomar uma conversa. Reiniciar o computador termina tudo à mesma. Os terminais existentes mantêm-se como foram criados. O custo: o tmux não encaminha o protocolo de teclado do terminal, por isso Shift+Enter chega ao agente como um Enter normal (envia em vez de acrescentar uma linha). Deixe isto desligado a menos que um agente deva sobreviver à app.", .durableMissingTmux: "Precisa do tmux, que não foi encontrado. Instale-o (p. ex. brew install tmux) e reabra as Definições.",
        .updateInstallOnQuit: "Instalar ao sair", .updateStagedTitle: "A versão %@ está pronta", .updateStagedBody: "Está descarregada e verificada. Nada muda até sair do Planchette — o próximo arranque usa a nova versão e os agentes em execução ficam intactos.", .updatePendingQuit: "Uma atualização será instalada ao sair.",
        .newFolder: "Nova pasta…", .newFolderTitle: "Nome da pasta", .newFolderHelp: "Agrupar projetos numa pasta com nome", .renameFolder: "Renomear pasta", .moveToFolder: "Mover para pasta", .noFolder: "Sem pasta", .dissolveFolder: "Dissolver pasta", .dissolveFolderHelp: "Remove a pasta; os projetos ficam",
        .folderOverviewHelp: "Mostrar o que está nesta pasta", .newProjectInFolder: "Adicionar um projeto em \"%@\"", .folderEmpty: "Ainda não há projetos nesta pasta — arrasta um da barra lateral.", .openProjectHelp: "Abrir este projeto", .terminalsCount: "%d terminais", .terminalCountOne: "1 terminal", .latestNotifications: "Notificações mais recentes", .nothingReported: "Ainda nada reportado",
        .helpTab: "Ajuda", .helpBranchTitle: "Ramo em uso", .helpBranchDetail: "Cada projeto mostra o ramo do seu checkout, atualizado enquanto trabalhas", .helpSearch: "Procurar funções e atalhos", .helpNoResults: "Nada corresponde.", .helpMissing: "Falta alguma coisa?", .requestFeature: "Sugerir uma função…", .requestFeatureHelp: "Abre um pedido de funcionalidade pré-preenchido no GitHub", .helpSectionTerminals: "Terminais", .helpSectionWindows: "Janelas e navegação", .helpWhereSidebar: "Barra lateral", .helpWhereTabBar: "Barra de separadores", .helpWhereContextMenu: "Menu de contexto", .helpWhereSettings: "Definições", .helpWhereMenuBar: "Barra de menus", .helpWhereToolbar: "Barra de ferramentas", .newProjectInFolderShort: "Novo projeto numa pasta", .newProjectInFolderHelp: "O + numa pasta acrescenta um projeto lá dentro", .folderOverviewTitle: "Vista da pasta", .dropIntoFolderHelp: "Arrasta um projeto para uma pasta, ou entre duas linhas para o colocar exatamente", .selectedProjectsShort: "Vários projetos de uma vez", .helpMultiSelectDetail: "⌘/⇧-clique escolhe um conjunto; arrasta-o ou aplica a todos", .helpClusterTitle: "Vista em grelha", .helpClusterDetail: "Mostrar todos os terminais de um projeto; arrasta um painel para o limite de outro para dividir", .helpDropTitle: "Abrir uma pasta a partir do Finder", .helpCLITitle: "Controlar o Planchette a partir de um agente", .helpCLIDetail: "Uma API por socket e a CLI planchette em cada terminal: listar, abrir, enviar, esperar, ler", .helpInstallOnQuitDetail: "Transfere a atualização e instala-a ao sair, sem interromper um turno em curso",
        .remindMe: "Lembrar-me…", .remindMeHelp: "Em silêncio até lá, depois um lembrete", .remindIn1h: "Daqui a 1 hora", .remindIn2h: "Daqui a 2 horas", .remindTomorrow: "Amanhã às 9:00", .remindCancel: "Cancelar lembrete", .quietUntil: "em silêncio até %@", .reminder: "Lembrete", .reminderBody: "Pediste para seres lembrado disto.", .markGroupReady: "Marcar projeto como livre",
        .arrangements: "Disposições", .arrangementsHelp: "Disposições guardadas de projetos e terminais", .saveArrangement: "Guardar disposição…", .saveArrangementTitle: "Nome da disposição", .saveArrangementHelp: "Guarda os projetos e terminais desta janela como disposição reutilizável", .openArrangement: "Abrir", .renameArrangement: "Renomear disposição", .deleteArrangement: "Eliminar disposição", .noArrangements: "Ainda sem disposições guardadas", .arrangementSummary: "%d projetos · %d terminais", .savedArrangements: "Disposições guardadas",
        .selectedProjects: "%d projetos selecionados", .markProjectsFree: "Marcar %d projetos como livres", .closeProjects: "Fechar %d projetos", .closeProjectsBody: "Fechar %d projetos e os seus %d terminais? Isto termina as sessões em execução.", .dropIntoFolder: "Mover para \"%@\"",
    ]
}

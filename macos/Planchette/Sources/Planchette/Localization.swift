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
    case renameGroup, renameTerminal, startupCommandPrompt, newTagTitle
    case ok, cancel

    // Waiting time
    case now, minutesShort, hoursShort

    // Terminal area
    case noTerminalsInGroup, newTerminalHint

    // Inbox
    case attention, allQuiet, waitingForAnswer, doneSeeResult

    // Quick switcher
    case switcherPlaceholder

    // Menus / commands
    case newWindow, sessionMenu, newTerminal, quickSwitcher, jumpToWaiting
    case aiMenu, aiActive, summarizeAll, groupByTopic

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

    // Status colors / states
    case stateReady, stateRunning, stateWaiting, stateError, errorOccurred
    case generalTab, infoTab, colorLegendTitle, colorLegendIntro
    case readyDesc, runningDesc, waitingDesc, errorDesc

    // Projects / terminals / sidebar
    case newProject, newProjectHelp, addTerminalHelp
    case minifySidebar, expandSidebar, markReady

    // Notifications panel (right sidebar)
    case notificationsPanel, notificationsPanelHelp, onlyActive, clearReady
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
        .aiMenu: "AI", .aiActive: "AI assist active", .summarizeAll: "Summarize all sessions now",
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
        .stateReady: "Ready", .stateRunning: "Running", .stateWaiting: "Waiting for input", .stateError: "Error", .errorOccurred: "An error occurred",
        .generalTab: "General", .infoTab: "Information", .colorLegendTitle: "Status colors", .colorLegendIntro: "Each terminal shows a colored status dot:",
        .readyDesc: "idle at the prompt or finished — ready for your input", .runningDesc: "an agent or command is running", .waitingDesc: "the agent is waiting for you to answer or approve", .errorDesc: "the last command or agent exited with an error",
        .newProject: "New project…", .newProjectHelp: "Add a project from a folder", .addTerminalHelp: "Add a terminal in this project's folder",
        .minifySidebar: "Collapse sidebar", .expandSidebar: "Expand sidebar", .markReady: "Mark as ready", .notificationsPanel: "Notifications", .notificationsPanelHelp: "Show the notifications panel on the right", .onlyActive: "Only active", .clearReady: "Hide idle",
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
        .aiMenu: "KI", .aiActive: "KI-Assistenz aktiv", .summarizeAll: "Alle Sessions jetzt zusammenfassen",
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
        .stateReady: "Bereit", .stateRunning: "Läuft", .stateWaiting: "Wartet auf Eingabe", .stateError: "Fehler", .errorOccurred: "Ein Fehler ist aufgetreten",
        .generalTab: "Allgemein", .infoTab: "Information", .colorLegendTitle: "Status-Farben", .colorLegendIntro: "Jedes Terminal zeigt einen farbigen Statuspunkt:",
        .readyDesc: "am Prompt oder fertig — bereit für deine Eingabe", .runningDesc: "ein Agent oder Befehl läuft", .waitingDesc: "der Agent wartet auf deine Antwort oder Freigabe", .errorDesc: "der letzte Befehl oder Agent endete mit einem Fehler",
        .newProject: "Neues Projekt…", .newProjectHelp: "Projekt aus einem Ordner hinzufügen", .addTerminalHelp: "Terminal im Ordner dieses Projekts hinzufügen",
        .minifySidebar: "Seitenleiste einklappen", .expandSidebar: "Seitenleiste ausklappen", .markReady: "Als frei markieren", .notificationsPanel: "Benachrichtigungen", .notificationsPanelHelp: "Benachrichtigungs-Sidebar rechts anzeigen", .onlyActive: "Nur aktive", .clearReady: "Ruhige ausblenden",
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
        .aiMenu: "IA", .aiActive: "Assistance IA active", .summarizeAll: "Résumer toutes les sessions",
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
        .stateReady: "Prêt", .stateRunning: "En cours", .stateWaiting: "En attente d'entrée", .stateError: "Erreur", .errorOccurred: "Une erreur s'est produite",
        .generalTab: "Général", .infoTab: "Informations", .colorLegendTitle: "Couleurs d'état", .colorLegendIntro: "Chaque terminal affiche une pastille d'état colorée :",
        .readyDesc: "au prompt ou terminé — prêt pour votre saisie", .runningDesc: "un agent ou une commande s'exécute", .waitingDesc: "l'agent attend votre réponse ou approbation", .errorDesc: "la dernière commande ou l'agent s'est terminé avec une erreur",
        .newProject: "Nouveau projet…", .newProjectHelp: "Ajouter un projet depuis un dossier", .addTerminalHelp: "Ajouter un terminal dans le dossier de ce projet",
        .minifySidebar: "Réduire la barre latérale", .expandSidebar: "Développer la barre latérale", .markReady: "Marquer comme prêt", .notificationsPanel: "Notifications", .notificationsPanelHelp: "Afficher le panneau de notifications à droite", .onlyActive: "Actifs seulement", .clearReady: "Masquer les inactifs",
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
        .aiMenu: "IA", .aiActive: "Asistencia IA activa", .summarizeAll: "Resumir todas las sesiones",
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
        .stateReady: "Listo", .stateRunning: "En ejecución", .stateWaiting: "Esperando entrada", .stateError: "Error", .errorOccurred: "Ocurrió un error",
        .generalTab: "General", .infoTab: "Información", .colorLegendTitle: "Colores de estado", .colorLegendIntro: "Cada terminal muestra un punto de estado de color:",
        .readyDesc: "en el prompt o terminado — listo para tu entrada", .runningDesc: "un agente o comando se está ejecutando", .waitingDesc: "el agente espera tu respuesta o aprobación", .errorDesc: "el último comando o agente terminó con un error",
        .newProject: "Nuevo proyecto…", .newProjectHelp: "Añadir un proyecto desde una carpeta", .addTerminalHelp: "Añadir un terminal en la carpeta de este proyecto",
        .minifySidebar: "Contraer barra lateral", .expandSidebar: "Expandir barra lateral", .markReady: "Marcar como listo", .notificationsPanel: "Notificaciones", .notificationsPanelHelp: "Mostrar el panel de notificaciones a la derecha", .onlyActive: "Solo activos", .clearReady: "Ocultar inactivos",
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
        .aiMenu: "IA", .aiActive: "Assistenza IA attiva", .summarizeAll: "Riassumi tutte le sessioni",
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
        .stateReady: "Pronto", .stateRunning: "In esecuzione", .stateWaiting: "In attesa di input", .stateError: "Errore", .errorOccurred: "Si è verificato un errore",
        .generalTab: "Generale", .infoTab: "Informazioni", .colorLegendTitle: "Colori di stato", .colorLegendIntro: "Ogni terminale mostra un pallino di stato colorato:",
        .readyDesc: "al prompt o terminato — pronto per il tuo input", .runningDesc: "un agente o comando è in esecuzione", .waitingDesc: "l'agente attende la tua risposta o approvazione", .errorDesc: "l'ultimo comando o agente è terminato con un errore",
        .newProject: "Nuovo progetto…", .newProjectHelp: "Aggiungi un progetto da una cartella", .addTerminalHelp: "Aggiungi un terminale nella cartella di questo progetto",
        .minifySidebar: "Comprimi barra laterale", .expandSidebar: "Espandi barra laterale", .markReady: "Segna come pronto", .notificationsPanel: "Notifiche", .notificationsPanelHelp: "Mostra il pannello notifiche a destra", .onlyActive: "Solo attivi", .clearReady: "Nascondi inattivi",
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
        .aiMenu: "AI", .aiActive: "AI-assistentie actief", .summarizeAll: "Alle sessies nu samenvatten",
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
        .stateReady: "Gereed", .stateRunning: "Actief", .stateWaiting: "Wacht op invoer", .stateError: "Fout", .errorOccurred: "Er is een fout opgetreden",
        .generalTab: "Algemeen", .infoTab: "Informatie", .colorLegendTitle: "Statuskleuren", .colorLegendIntro: "Elk terminal toont een gekleurde statusstip:",
        .readyDesc: "bij de prompt of klaar — gereed voor je invoer", .runningDesc: "een agent of opdracht is actief", .waitingDesc: "de agent wacht op je antwoord of goedkeuring", .errorDesc: "de laatste opdracht of agent eindigde met een fout",
        .newProject: "Nieuw project…", .newProjectHelp: "Een project vanuit een map toevoegen", .addTerminalHelp: "Een terminal in de map van dit project toevoegen",
        .minifySidebar: "Zijbalk inklappen", .expandSidebar: "Zijbalk uitklappen", .markReady: "Als gereed markeren", .notificationsPanel: "Meldingen", .notificationsPanelHelp: "Toon het meldingenpaneel rechts", .onlyActive: "Alleen actief", .clearReady: "Rustige verbergen",
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
        .aiMenu: "IA", .aiActive: "Assistência IA ativa", .summarizeAll: "Resumir todas as sessões",
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
        .stateReady: "Pronto", .stateRunning: "Em execução", .stateWaiting: "À espera de entrada", .stateError: "Erro", .errorOccurred: "Ocorreu um erro",
        .generalTab: "Geral", .infoTab: "Informação", .colorLegendTitle: "Cores de estado", .colorLegendIntro: "Cada terminal mostra um ponto de estado colorido:",
        .readyDesc: "no prompt ou terminado — pronto para a tua entrada", .runningDesc: "um agente ou comando está em execução", .waitingDesc: "o agente aguarda a tua resposta ou aprovação", .errorDesc: "o último comando ou agente terminou com um erro",
        .newProject: "Novo projeto…", .newProjectHelp: "Adicionar um projeto a partir de uma pasta", .addTerminalHelp: "Adicionar um terminal na pasta deste projeto",
        .minifySidebar: "Recolher barra lateral", .expandSidebar: "Expandir barra lateral", .markReady: "Marcar como pronto", .notificationsPanel: "Notificações", .notificationsPanelHelp: "Mostrar o painel de notificações à direita", .onlyActive: "Apenas ativos", .clearReady: "Ocultar inativos",
    ]
}

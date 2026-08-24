import Foundation

/// The catalogue behind the Help tab: every feature the app has, in one list you
/// can search.
///
/// It is built from the **same** localized strings the controls themselves use —
/// a feature's name is its menu item's name, its description is the tooltip that
/// control already carries. That is deliberate: help written separately from the
/// UI drifts from it within two releases, and nobody notices until a user does.
/// Adding a feature therefore means adding one line here, next to the `LKey` you
/// already had to add for the control (see AGENTS.md, ground rule 7).
enum Help {
    struct Entry: Identifiable {
        let titleKey: LKey
        /// The tooltip the control carries; nil when the title says it all.
        let detailKey: LKey?
        /// Keyboard shortcut, written as it appears in the menus.
        let shortcut: String?
        /// Where the feature lives, for a user who cannot find it.
        let whereKey: LKey?

        var id: String { "\(titleKey.rawValue)-\(shortcut ?? "")" }

        init(_ titleKey: LKey, _ detailKey: LKey? = nil,
             shortcut: String? = nil, where whereKey: LKey? = nil) {
            self.titleKey = titleKey
            self.detailKey = detailKey
            self.shortcut = shortcut
            self.whereKey = whereKey
        }

        /// Everything a search should match against, localized.
        var haystack: String {
            [L10n.t(titleKey), detailKey.map { L10n.t($0) } ?? "", shortcut ?? "",
             whereKey.map { L10n.t($0) } ?? ""]
                .joined(separator: " ")
                .lowercased()
        }
    }

    struct Section: Identifiable {
        let titleKey: LKey
        let entries: [Entry]
        var id: String { titleKey.rawValue }
    }

    static let sections: [Section] = [
        Section(titleKey: .projects, entries: [
            Entry(.newProject, .newProjectHelp, shortcut: nil, where: .helpWhereSidebar),
            Entry(.newFolder, .newFolderHelp, where: .helpWhereSidebar),
            Entry(.newProjectInFolderShort, .newProjectInFolderHelp, where: .helpWhereSidebar),
            Entry(.folderOverviewTitle, .folderOverviewHelp, where: .helpWhereSidebar),
            Entry(.moveToFolder, .dropIntoFolderHelp, where: .helpWhereSidebar),
            Entry(.dissolveFolder, .dissolveFolderHelp, where: .helpWhereSidebar),
            Entry(.makeFavorite, .favoriteHelp, where: .helpWhereSidebar),
            Entry(.selectedProjectsShort, .helpMultiSelectDetail, where: .helpWhereSidebar),
            Entry(.markProjectInactive, .markProjectActiveHelp, where: .helpWhereContextMenu),
            Entry(.arrangements, .arrangementsHelp, where: .helpWhereSidebar),
            Entry(.saveArrangement, .saveArrangementHelp, where: .helpWhereSidebar),
            Entry(.deleteArrangement, .deleteArrangementBody, where: .helpWhereMenuBar),
            Entry(.collapseAllProjects, nil, where: .helpWhereSidebar),
            Entry(.peekCollapsedTitle, .peekCollapsedHelp, where: .helpWhereSettings),
            Entry(.minifySidebar, nil, where: .helpWhereSidebar),
            Entry(.helpBranchTitle, .helpBranchDetail, where: .helpWhereSidebar),
        ]),
        Section(titleKey: .helpSectionTerminals, entries: [
            Entry(.newTerminal, .newTerminalHelp, shortcut: "⌘T"),
            Entry(.addTerminalHelp, nil, where: .helpWhereTabBar),
            Entry(.newWorktree, .newWorktreeHelp, shortcut: "⌘⇧T"),
            Entry(.helpClusterTitle, .helpClusterDetail, where: .helpWhereTabBar),
            Entry(.menuOpenLink, .menuOpenLinkHelp, where: .helpWhereContextMenu),
            Entry(.tags, .tagsHelp, where: .helpWhereContextMenu),
            Entry(.startupCommand, .startupCommandHelp, where: .helpWhereContextMenu),
            Entry(.rename, .renameHelp, where: .helpWhereContextMenu),
            Entry(.color, .colorHelp, where: .helpWhereContextMenu),
            Entry(.close, .closeHelp, shortcut: "⌘W", where: .helpWhereContextMenu),
            Entry(.fontLarger, nil, shortcut: "⌘+", where: .helpWhereTabBar),
            Entry(.fontSmaller, nil, shortcut: "⌘-", where: .helpWhereTabBar),
            Entry(.fontReset, nil, shortcut: "⌘0", where: .helpWhereTabBar),
            Entry(.durableSection, .durableHelp, where: .helpWhereSettings),
            Entry(.importMenu, .importMenuHelp, where: .helpWhereMenuBar),
            Entry(.helpTerminalRowTitle, .helpTerminalRowDetail, where: .helpWhereSidebar),
            Entry(.helpActiveMarkTitle, .helpActiveMarkDetail, where: .helpWhereSidebar),
            Entry(.helpDropTitle, .dropHint, where: .helpWhereSidebar),
        ]),
        Section(titleKey: .notificationsPanel, entries: [
            Entry(.notificationsPanel, .notificationsPanelHelp),
            Entry(.onlyUnread, .onlyUnreadHelp),
            Entry(.onlyActive, nil),
            Entry(.markAllRead, nil),
            Entry(.markRead, nil, where: .helpWhereContextMenu),
            Entry(.markUnread, nil, where: .helpWhereContextMenu),
            Entry(.remindMe, .remindMeHelp, where: .helpWhereContextMenu),
            Entry(.markGroupReady, nil, where: .helpWhereContextMenu),
            Entry(.jumpToWaiting, .jumpToWaitingHelp, shortcut: "⌘⇧K"),
        ]),
        Section(titleKey: .helpSectionWindows, entries: [
            Entry(.quickSwitcher, .quickSwitcherHelp, shortcut: "⌘K"),
            Entry(.newWindow, .newWindowHelp, shortcut: "⌘N"),
            Entry(.moveToNewWindow, .moveToNewWindowHelp, where: .helpWhereContextMenu),
            Entry(.mergeIntoMain, .mergeIntoMainHelp, where: .helpWhereToolbar),
            Entry(.settingsTitle, .settingsHelp, shortcut: "⌘,"),
            Entry(.language, .languageHelp, where: .helpWhereSettings),
            Entry(.appearance, .appearanceHelp, where: .helpWhereSettings),
        ]),
        Section(titleKey: .aiSection, entries: [
            Entry(.aiAssist, .aiExplanation, where: .helpWhereSettings),
            Entry(.summarizeAll, .summarizeAllHelp, where: .helpWhereMenuBar),
            Entry(.groupByTopic, .groupByTopicHelp, where: .helpWhereMenuBar),
            Entry(.helpCLITitle, .helpCLIDetail),
        ]),
        Section(titleKey: .updates, entries: [
            Entry(.checkForUpdates, nil, where: .helpWhereMenuBar),
            Entry(.autoUpdateCheck, .autoUpdateHelp, where: .helpWhereSettings),
            Entry(.updateInstallOnQuit, .helpInstallOnQuitDetail),
        ]),
    ]

    /// Sections with only the entries matching `query` (empty query = all).
    static func sections(matching query: String) -> [Section] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sections }
        // Every word has to appear somewhere in the entry, so "new folder" finds
        // the folder entry and not everything that says "new".
        let words = needle.split(separator: " ").map(String.init)
        return sections.compactMap { section in
            let hits = section.entries.filter { entry in
                let hay = entry.haystack + " " + L10n.t(section.titleKey).lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            return hits.isEmpty ? nil : Section(titleKey: section.titleKey, entries: hits)
        }
    }

    /// A pre-filled GitHub "feature request" issue. The version goes in the body
    /// because the first question on any request is "which build?".
    static func featureRequestURL(version: String) -> URL? {
        var components = URLComponents(string: "https://github.com/marcello-a/Planchette/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "labels", value: "enhancement"),
            URLQueryItem(name: "title", value: "Feature request: "),
            URLQueryItem(name: "body", value: """
                ## What would you like Planchette to do?


                ## What are you doing today instead?


                ---
                Planchette \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
                """),
        ]
        return components?.url
    }
}

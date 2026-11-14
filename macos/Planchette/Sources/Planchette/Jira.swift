import AppKit
import Foundation

/// The Jira panel's side effects: the five-minute poll of every saved query, the connection check,
/// and a terminal for a ticket. The rules (requests, parse, errors) are in `JiraTickets`; the state
/// is declared with the rest of `AppState`'s.
extension AppState {
    // MARK: Poll

    /// Poll while the panel is switched on in Settings, stop while it is off.
    func updateJiraPolling() {
        jiraTimer?.invalidate()
        jiraTimer = nil
        guard jiraEnabled, !SupportPaths.isIsolated else { return }
        let timer = Timer(timeInterval: JiraTickets.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshJira() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        jiraTimer = timer
        // Not in the launch, but not five minutes later either.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated { self?.refreshJira() }
        }
    }

    /// Ask Jira now, for every query. `manual` is the panel's refresh button: it may not repeat
    /// faster than `JiraTickets.minimumManualInterval`.
    func refreshJira(manual: Bool = false) {
        if SupportPaths.isIsolated { return showJiraFixture() }
        guard jiraEnabled,
              let site = JiraTickets.normalizedSite(jira.site), !jira.queries.isEmpty else { return }
        if manual {
            let now = Date()
            if let last = jiraLastManualRefresh, now.timeIntervalSince(last) < JiraTickets.minimumManualInterval { return }
            jiraLastManualRefresh = now
        }
        guard jiraFlight.begin() else { return }
        jiraRefreshing = true
        let email = jira.email.trimmingCharacters(in: .whitespaces)
        let queries = jira.queries
        Task.detached {
            let token = Keychain.read(service: Keychain.jiraService, account: email) ?? ""
            var results: [UUID: JiraResult] = [:]
            for query in queries {
                results[query.id] = await Self.search(site: site, email: email, token: token, jql: query.jql)
            }
            let answers = results
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A query added or removed meanwhile keeps its own answer, or none.
                var merged = self.jiraResults.filter { id, _ in self.jira.queries.contains { $0.id == id } }
                for (id, result) in answers where self.jira.queries.contains(where: { $0.id == id }) {
                    merged[id] = result
                }
                if merged != self.jiraResults { self.jiraResults = merged }
                self.jiraRefreshing = false
                if self.jiraFlight.end() { self.refreshJira() }
            }
        }
    }

    /// An isolated instance asks Jira for nothing. Given `-jiraFixture <file>` (a search answer as
    /// Jira sends it), every query shows that file's tickets — how `scripts/perf/jira_panel.py`
    /// pictures the panel for its hint.
    private func showJiraFixture() {
        guard jiraEnabled, let path = UserDefaults.standard.string(forKey: "jiraFixture"),
              let data = FileManager.default.contents(atPath: path),
              let issues = JiraTickets.parse(data) else { return }
        let results = Dictionary(uniqueKeysWithValues: jira.queries.map {
            ($0.id, JiraResult(issues: issues, checkedAt: Date()))
        })
        if results != jiraResults { jiraResults = results }
    }

    /// One query's answer, off the main thread.
    nonisolated static func search(site: URL, email: String, token: String, jql: String) async -> JiraResult {
        guard !token.isEmpty else { return JiraResult(error: .unauthorized, checkedAt: Date()) }
        let request = JiraTickets.searchRequest(site: site, email: email, token: token, jql: jql)
        guard let (data, response) = try? await jiraSession.data(for: request),
              let http = response as? HTTPURLResponse else {
            return JiraResult(error: .unreachable, checkedAt: Date())
        }
        guard http.statusCode == 200 else {
            return JiraResult(error: JiraTickets.error(status: http.statusCode, data: data), checkedAt: Date())
        }
        guard let issues = JiraTickets.parse(data) else { return JiraResult(error: .unreadable, checkedAt: Date()) }
        return JiraResult(issues: issues, checkedAt: Date())
    }

    /// Try a query before it is saved: the query editor's "Test" button.
    func testJiraQuery(_ jql: String) async -> JiraResult {
        guard let site = JiraTickets.normalizedSite(jira.site) else { return JiraResult(error: .unreachable) }
        let email = jira.email.trimmingCharacters(in: .whitespaces)
        return await Task.detached {
            let token = Keychain.read(service: Keychain.jiraService, account: email) ?? ""
            return await Self.search(site: site, email: email, token: token, jql: jql)
        }.value
    }

    /// Settings' "Check connection": the account's display name, or why there is none.
    func checkJiraConnection() async -> Result<String, JiraError> {
        guard let site = JiraTickets.normalizedSite(jira.site) else { return .failure(.unreachable) }
        let email = jira.email.trimmingCharacters(in: .whitespaces)
        return await Task.detached {
            let token = Keychain.read(service: Keychain.jiraService, account: email) ?? ""
            guard !token.isEmpty else { return .failure(.unauthorized) }
            let request = JiraTickets.myselfRequest(site: site, email: email, token: token)
            guard let (data, response) = try? await jiraSession.data(for: request),
                  let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            guard http.statusCode == 200 else {
                return .failure(JiraTickets.error(status: http.statusCode, data: data))
            }
            let me = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return .success((me?["displayName"] as? String) ?? email)
        }.value
    }

    // MARK: Queries

    /// Every change to the queries, the account or the panel goes through here: saved (`jira`'s
    /// `didSet`), and a new or changed query is asked for at once.
    func updateJira(_ change: (inout JiraLook) -> Void) {
        var look = jira
        change(&look)
        guard look != jira else { return }
        let asked = Dictionary(uniqueKeysWithValues: jira.queries.map { ($0.id, $0.jql) })
        // Not for the site or the e-mail: they change a letter at a time while typed. Saving the
        // token asks again.
        let refetch = look.queries.contains { asked[$0.id] != $0.jql }
        jira = look
        jiraResults = jiraResults.filter { id, _ in look.queries.contains { $0.id == id } }
        if refetch { refreshJira() }
    }

    /// Open or close the panel (the tab bar's button). Opening asks Jira for what is new.
    func toggleJiraPanel() {
        updateJira { $0.open.toggle() }
        if jira.open {
            completeHint(.jira)     // used: it needs no introduction any more
            refreshJira(manual: true)
        }
    }

    // MARK: Tickets

    func openInBrowser(_ issue: JiraIssue) {
        guard let site = JiraTickets.normalizedSite(jira.site) else { return }
        NSWorkspace.shared.open(JiraTickets.browseURL(site: site, key: issue.key))
    }

    /// A new terminal for a ticket in a project the user picked, in that project's folder.
    func openTerminal(for issue: JiraIssue, inGroup groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let near = group.activeSessionID.flatMap { sessions[$0] } ?? sessions(in: group).first
        let dir = near?.currentDirectory ?? group.worktreePath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let session = addSession(directory: dir, groupID: groupID)
        select(session: session)
    }
}

/// Jira's own session: a redirect may only stay on the host that was asked, or the token in the
/// `Authorization` header would go along to wherever the answer pointed.
private let jiraSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
}()

private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let same = request.url?.host == task.originalRequest?.url?.host && request.url?.scheme == "https"
        completionHandler(same ? request : nil)
    }
}

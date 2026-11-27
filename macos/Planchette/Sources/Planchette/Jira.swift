import AppKit
import Foundation

/// The Jira panel's side effects: the five-minute poll of every saved query, the connection check,
/// and a terminal for a ticket. The rules (requests, parse, errors) are in `JiraTickets`; the state
/// is declared with the rest of `AppState`'s.
extension AppState {
    // MARK: Poll

    /// Poll while the panel is switched on in Settings, stop while it is off. Called from `init`
    /// too: Swift runs no `didSet` there, and a relaunch must start the poll (and show the cache).
    func updateJiraPolling() {
        jiraTimer?.invalidate()
        jiraTimer = nil
        guard jiraEnabled else { return forgetJiraTickets() }
        if jiraResults.isEmpty { loadJiraCache() }
        // Not in the launch, but not five minutes later either.
        DispatchQueue.main.asyncAfter(deadline: .now() + (SupportPaths.isIsolated ? 1 : 6)) { [weak self] in
            MainActor.assumeIsolated { self?.refreshJira() }
        }
        guard !SupportPaths.isIsolated else { return }
        let timer = Timer(timeInterval: JiraTickets.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshJira() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        jiraTimer = timer
    }

    /// Ask Jira now, for every query at once. `manual` is the panel's refresh button: it may not
    /// repeat faster than `JiraTickets.minimumManualInterval`.
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
        let account = (jira.site, jira.email)
        let queries = jira.queries
        Task.detached {
            let token = Keychain.read(service: Keychain.jiraService, account: email) ?? ""
            let answers = await withTaskGroup(of: (id: UUID, jql: String, result: JiraResult).self) { group in
                for query in queries {
                    group.addTask { (query.id, query.jql, await Self.search(site: site, email: email, token: token, jql: query.jql)) }
                }
                var all: [(id: UUID, jql: String, result: JiraResult)] = []
                for await answer in group { all.append(answer) }
                return all
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Switched off, or another site or account meanwhile: the answers are not for this panel.
                if self.jiraEnabled, self.jira.site == account.0, self.jira.email == account.1 {
                    self.takeJiraAnswers(answers)
                }
                self.jiraRefreshing = false
                if self.jiraFlight.end() { self.refreshJira() }
            }
        }
    }

    /// Answers into the panel: only for queries that still ask the same JQL, merged over the last
    /// answer (out of reach keeps it, as offline data), published only when something changed.
    private func takeJiraAnswers(_ answers: [(id: UUID, jql: String, result: JiraResult)]) {
        var merged = jiraResults.filter { id, _ in jira.queries.contains { $0.id == id } }
        for answer in answers where jira.queries.contains(where: { $0.id == answer.id && $0.jql == answer.jql }) {
            if answer.result.error == nil { jiraAnsweredAt[answer.id] = answer.result.checkedAt ?? Date() }
            merged[answer.id] = JiraTickets.merge(old: merged[answer.id], new: answer.result,
                                                  lastAnswer: jiraAnsweredAt[answer.id])
        }
        let changed = merged.count != jiraResults.count
            || merged.contains { id, result in !result.sameContent(as: jiraResults[id]) }
        if changed { jiraResults = merged }
        saveJiraCache()
    }

    /// An isolated instance asks Jira for nothing. Given `-jiraFixture <file>` (a search answer as
    /// Jira sends it), every query shows that file's tickets — how `scripts/perf/jira_panel.py`
    /// pictures the panel for its hint. A fixture path with no file behind it is Jira out of reach:
    /// the way to see the offline marking without pulling the cable.
    private func showJiraFixture() {
        guard jiraEnabled, let path = UserDefaults.standard.string(forKey: "jiraFixture") else { return }
        let answer: JiraResult
        if let data = FileManager.default.contents(atPath: path) {
            guard let issues = JiraTickets.parse(data) else { return }
            answer = JiraResult(issues: issues, checkedAt: Date(), more: JiraTickets.hasMore(data))
        } else {
            answer = JiraResult(error: .unreachable, checkedAt: Date())
        }
        takeJiraAnswers(jira.queries.map { (id: $0.id, jql: $0.jql, result: answer) })
    }

    // MARK: The cache (`jira-cache.json`)

    static var jiraCacheURL: URL { SupportPaths.dir.appendingPathComponent("jira-cache.json") }

    /// The last tickets, shown as offline data until Jira answers.
    private func loadJiraCache() {
        guard let data = try? Data(contentsOf: Self.jiraCacheURL),
              let cache = try? JSONDecoder().decode(JiraCache.self, from: data) else { return }
        let results = cache.results(for: jira)
        guard !results.isEmpty else { return }
        for (id, result) in results { jiraAnsweredAt[id] = result.checkedAt }
        jiraResults = results
    }

    /// Written off the main thread, one write after the other.
    func saveJiraCache() {
        let cache = JiraCache(look: jira, results: jiraResults, answeredAt: jiraAnsweredAt)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let url = Self.jiraCacheURL
        jiraCacheQueue.async { try? data.write(to: url, options: .atomic) }
    }

    /// Switched off, or another site or account: no tickets in memory and none on disk.
    func forgetJiraTickets() {
        jiraTypingTask?.cancel()
        if !jiraResults.isEmpty { jiraResults = [:] }
        jiraAnsweredAt = [:]
        let url = Self.jiraCacheURL
        jiraCacheQueue.async { try? FileManager.default.removeItem(at: url) }
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
        return JiraResult(issues: issues, checkedAt: Date(), more: JiraTickets.hasMore(data))
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
        let accountChanged = look.site != jira.site || look.email != jira.email
        let refetch = look.queries.contains { asked[$0.id] != $0.jql }
        jira = look
        if accountChanged {
            // Another site's tickets must not stay: a click would open the new site with an old key.
            forgetJiraTickets()
            // Typed a letter at a time: ask once the typing stops.
            jiraTypingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.refreshJira()
            }
            return
        }
        // A changed JQL shows the spinner until its own answer comes, not the old query's cards.
        let kept = jiraResults.filter { id, _ in look.queries.contains { $0.id == id && asked[id] == $0.jql } }
        if kept.count != jiraResults.count { jiraResults = kept }
        if refetch { refreshJira() } else { saveJiraCache() }
    }

    /// Open or close the panel (the tab bar's button). Opening asks Jira for what is new.
    func toggleJiraPanel() {
        updateJira { $0.open.toggle() }
        if jira.open {
            Telemetry.count(.jiraOpened)
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
    func openTerminal(inGroup groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        Telemetry.count(.jiraTerminal)
        select(session: newTerminal(in: group))
    }
}

/// Jira's own session: a redirect may only stay on the host that was asked, or the token in the
/// `Authorization` header would go along to wherever the answer pointed.
private let jiraCacheQueue = DispatchQueue(label: "planchette.jira-cache")

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

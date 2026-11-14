import XCTest
@testable import Planchette

final class JiraTicketsTests: XCTestCase {
    private let site = URL(string: "https://example.atlassian.net")!

    // MARK: Site

    func testASiteIsReducedToItsRootOverHTTPS() {
        XCTAssertEqual(JiraTickets.normalizedSite("example.atlassian.net"), site)
        XCTAssertEqual(JiraTickets.normalizedSite("  https://Example.atlassian.net/jira/your-work  "), site)
        XCTAssertEqual(JiraTickets.normalizedSite("https://example.atlassian.net/"), site)
    }

    // The token goes out in a header: never in the clear, never to something that is not a host.
    func testPlainHTTPAndNonsenseAreRefused() {
        XCTAssertNil(JiraTickets.normalizedSite("http://example.atlassian.net"))
        XCTAssertNil(JiraTickets.normalizedSite(""))
        XCTAssertNil(JiraTickets.normalizedSite("localhost"))
        XCTAssertNil(JiraTickets.normalizedSite("ftp://example.atlassian.net"))
    }

    func testABrowseLinkNamesTheTicket() {
        XCTAssertEqual(JiraTickets.browseURL(site: site, key: "SHOP-12").absoluteString,
                       "https://example.atlassian.net/browse/SHOP-12")
    }

    // MARK: Request

    func testTheSearchCarriesTheJQLIntactAndTheToken() throws {
        let jql = #"project = "SHOP" AND (priority = High OR labels in (a+b)) ORDER BY created DESC"#
        let request = JiraTickets.searchRequest(site: site, email: "me@example.com", token: "t0k", jql: jql)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/rest/api/3/search/jql")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "jql" }?.value, jql)
        XCTAssertEqual(items.first { $0.name == "maxResults" }?.value, "50")
        XCTAssertFalse(url.absoluteString.contains("+"), "a + would reach Jira as a space")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("me@example.com:t0k".utf8).base64EncodedString())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: Answer

    func testAnAnswerBecomesCards() throws {
        let json: [String: Any] = ["issues": [
            ["key": "SHOP-1", "fields": [
                "summary": "Checkout button moves on iOS",
                "status": ["name": "In Progress", "statusCategory": ["key": "indeterminate"]],
                "issuetype": ["name": "Bug"],
                "priority": ["name": "High"],
                "assignee": ["displayName": "Tim"],
            ]],
            ["key": "SHOP-2", "fields": [
                "summary": "Discount codes",
                "status": ["name": "Done", "statusCategory": ["key": "done"]],
                "assignee": NSNull(), "priority": NSNull(),
            ]],
            ["fields": ["summary": "no key: not a ticket"]],
        ], "isLast": true]
        let issues = try XCTUnwrap(JiraTickets.parse(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(issues.map(\.key), ["SHOP-1", "SHOP-2"])
        XCTAssertEqual(issues[0], JiraIssue(key: "SHOP-1", summary: "Checkout button moves on iOS", type: "Bug",
                                           priority: "High", status: "In Progress", statusCategory: .inProgress,
                                           assignee: "Tim"))
        XCTAssertNil(issues[1].assignee)
        XCTAssertNil(issues[1].priority)
        XCTAssertEqual(issues[1].statusCategory, .done)
    }

    // MARK: Days in column

    private func issue(changelog: [[String: Any]], fields: [String: Any]) throws -> JiraIssue {
        var all = fields
        all["status"] = ["name": "Review", "statusCategory": ["key": "indeterminate"]]
        let json: [String: Any] = ["issues": [["key": "A-1", "fields": all, "changelog": ["histories": changelog]]]]
        return try XCTUnwrap(JiraTickets.parse(JSONSerialization.data(withJSONObject: json))?.first)
    }

    func testDaysCountFromTheLastStatusChange() throws {
        let ticket = try issue(changelog: [
            ["created": "2026-11-01T10:00:00.000+0000", "items": [["field": "status"]]],
            ["created": "2026-11-05T10:00:00.000+0000", "items": [["field": "status"]]],
            // A later edit that is not a move: it does not reset the count.
            ["created": "2026-11-08T10:00:00.000+0000", "items": [["field": "summary"]]],
        ], fields: ["created": "2026-10-01T10:00:00.000+0000"])
        XCTAssertEqual(ticket.statusSince, JiraTickets.date("2026-11-05T10:00:00.000+0000"))
        let now = try XCTUnwrap(JiraTickets.date("2026-11-08T11:00:00.000+0000"))
        XCTAssertEqual(ticket.daysInStatus(at: now), 3)
    }

    func testATicketThatNeverMovedCountsFromItsCreation() throws {
        let ticket = try issue(changelog: [], fields: ["created": "2026-11-10T09:12:33.123+0100"])
        XCTAssertEqual(ticket.statusSince, JiraTickets.date("2026-11-10T09:12:33.123+0100"))
        XCTAssertNotNil(ticket.statusSince)
        XCTAssertNil(try issue(changelog: [], fields: [:]).daysInStatus())
    }

    func testTheSearchAsksForTheHistory() throws {
        let request = JiraTickets.searchRequest(site: site, email: "e", token: "t", jql: "x")
        let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "expand" }?.value, "changelog")
        XCTAssertTrue(items.first { $0.name == "fields" }?.value?.contains("created") == true)
    }

    func testAnEmptySearchIsNoTicketsAndGarbageIsNoAnswer() {
        XCTAssertEqual(JiraTickets.parse(Data(#"{"issues":[]}"#.utf8)), [])
        XCTAssertNil(JiraTickets.parse(Data("<html>login</html>".utf8)))
        XCTAssertNil(JiraTickets.parse(Data(#"{"values":[]}"#.utf8)))
    }

    func testStatusCategories() {
        XCTAssertEqual(JiraStatusCategory(key: "new"), .todo)
        XCTAssertEqual(JiraStatusCategory(key: "indeterminate"), .inProgress)
        XCTAssertEqual(JiraStatusCategory(key: "done"), .done)
        XCTAssertEqual(JiraStatusCategory(key: nil), .todo)
    }

    // MARK: Errors

    func testABadQuerySaysWhatJiraSaid() {
        let data = Data(#"{"errorMessages":["The value 'XYZ' does not exist for the field 'project'."],"errors":{}}"#.utf8)
        XCTAssertEqual(JiraTickets.error(status: 400, data: data),
                       .rejected("The value 'XYZ' does not exist for the field 'project'."))
    }

    func testAWrongTokenIsUnauthorizedWhateverTheBody() {
        XCTAssertEqual(JiraTickets.error(status: 401, data: Data()), .unauthorized)
        XCTAssertEqual(JiraTickets.error(status: 403, data: Data(#"{"errorMessages":["x"]}"#.utf8)), .unauthorized)
        XCTAssertEqual(JiraTickets.error(status: 503, data: Data()), .unreachable)
    }

    // MARK: State

    func testAWorkspaceFromBeforeHasBothPanelsOff() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[]}"#
        let saved = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertFalse(saved.todosEnabled)
        XCTAssertFalse(saved.jiraEnabled)
        XCTAssertEqual(saved.jira, JiraLook())
    }

    func testTheQueriesSurviveASaveAndALoadWithoutTheToken() throws {
        let look = JiraLook(site: "example.atlassian.net", email: "me@example.com",
                            queries: [JiraQuery(name: "Mine", jql: "assignee = currentUser()", collapsed: true)],
                            open: true, width: 310)
        let saved = PersistedState(
            groups: [], sessions: [], windows: [], aiEnabled: false, language: .en,
            appearance: .system, autoUpdateCheck: true, durableTerminals: true,
            todosEnabled: true, jiraEnabled: true, jira: look)
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(back.jira, look)
        XCTAssertTrue(back.todosEnabled)
        XCTAssertTrue(back.jiraEnabled)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("token"))
    }

    func testAnUnreadableJiraBlockCostsOnlyThePanel() throws {
        let json = #"{"groups":[],"sessions":[],"windows":[],"jira":{"queries":42,"site":"x.atlassian.net","width":"wide"}}"#
        let jira = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8)).jira
        XCTAssertEqual(jira.site, "x.atlassian.net")
        XCTAssertEqual(jira.queries, [])
        XCTAssertEqual(jira.width, JiraLook.defaultWidth)
    }

    func testTheWidthLeavesTheTerminalItsRoom() {
        XCTAssertEqual(JiraLook.clamped(width: 2000, in: 1000), 1000 - NotepadLook.terminalMinimumWidth)
        XCTAssertEqual(JiraLook.clamped(width: 50, in: 1000), JiraLook.minimumWidth)
        XCTAssertEqual(JiraLook.clamped(width: 300, in: 300), JiraLook.minimumWidth)
    }

    func testMovingAQueryStopsAtTheEnds() {
        let a = JiraQuery(name: "a", jql: "a"), b = JiraQuery(name: "b", jql: "b")
        var look = JiraLook(queries: [a, b])
        look.moveQuery(a.id, by: -1)
        XCTAssertEqual(look.queries.map(\.name), ["a", "b"])
        look.moveQuery(a.id, by: 1)
        XCTAssertEqual(look.queries.map(\.name), ["b", "a"])
    }
}

import XCTest
@testable import Planchette

final class TelemetryTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600

    private func decode(_ json: String) throws -> TelemetryRecord {
        try JSONDecoder().decode(TelemetryRecord.self, from: Data(json.utf8))
    }

    private func context(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> TelemetryPayload.Context {
        .init(apiKey: "phc_test", appVersion: "0.2.55", osVersion: "Version 26.2", now: now)
    }

    private func events(_ body: [String: Any]) -> [[String: Any]] {
        body["batch"] as? [[String: Any]] ?? []
    }

    // MARK: The question

    func testTheQuestionIsDueOnlyWhenNeverAnswered() {
        var record = TelemetryRecord()
        XCTAssertTrue(Telemetry.promptDue(record, runningVersion: "0.2.55", welcomeSeen: true,
                                          isolated: false, keyConfigured: true))
        record.consent = false
        XCTAssertFalse(Telemetry.promptDue(record, runningVersion: "0.2.55", welcomeSeen: true,
                                           isolated: false, keyConfigured: true))
        record.consent = true
        XCTAssertFalse(Telemetry.promptDue(record, runningVersion: "0.2.55", welcomeSeen: true,
                                           isolated: false, keyConfigured: true))
    }

    // Closed without an answer: not again in this version, once more after the next update.
    func testAClosedQuestionComesBackAfterTheNextUpdateOnly() {
        var record = TelemetryRecord()
        record.askedVersion = "0.2.55"
        XCTAssertFalse(Telemetry.promptDue(record, runningVersion: "0.2.55", welcomeSeen: true,
                                           isolated: false, keyConfigured: true))
        XCTAssertTrue(Telemetry.promptDue(record, runningVersion: "0.2.56", welcomeSeen: true,
                                          isolated: false, keyConfigured: true))
    }

    func testNoQuestionOverTheWelcomeInATestOrWithoutAKey() {
        let record = TelemetryRecord()
        XCTAssertFalse(Telemetry.promptDue(record, runningVersion: "1", welcomeSeen: false,
                                           isolated: false, keyConfigured: true))
        XCTAssertFalse(Telemetry.promptDue(record, runningVersion: "1", welcomeSeen: true,
                                           isolated: true, keyConfigured: true))
        XCTAssertFalse(Telemetry.promptDue(record, runningVersion: "1", welcomeSeen: true,
                                           isolated: false, keyConfigured: false))
    }

    // MARK: When a report is due

    private func used(_ seconds: Int = 600) -> TelemetryRecord {
        var record = TelemetryRecord()
        record.consent = true
        record.activeSeconds = seconds
        return record
    }

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int) -> Date {
        berlin.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testNoReportWithoutConsent() {
        var record = used()
        record.consent = nil
        XCTAssertFalse(Telemetry.reportDue(record, now: Date()))
        record.consent = false
        XCTAssertFalse(Telemetry.reportDue(record, now: Date()))
        record.consent = true
        XCTAssertTrue(Telemetry.reportDue(record, now: Date()))
    }

    // Not twice on a calendar day, and not within 20 hours — even across midnight.
    func testAtMostOneReportADayAndTwentyHoursApart() {
        var record = used()
        record.lastSent = at(26, 8)
        XCTAssertFalse(Telemetry.reportDue(record, now: at(26, 22), calendar: berlin))
        XCTAssertFalse(Telemetry.reportDue(record, now: at(27, 1), calendar: berlin))
        XCTAssertTrue(Telemetry.reportDue(record, now: at(27, 5), calendar: berlin))
    }

    // A day without use sends nothing; the counts wait for a day with use.
    func testNoReportWithoutAMinuteOfUse() {
        var record = used(59)
        record.lastSent = at(20, 8)
        record.features = ["split": 1]
        record.errors = ["update.check_failed": 4]
        XCTAssertFalse(Telemetry.reportDue(record, now: at(22, 9), calendar: berlin))
        record.activeSeconds = 60
        XCTAssertTrue(Telemetry.reportDue(record, now: at(22, 9), calendar: berlin))
    }

    func testAnUnusedInstallReportsOnceAWeek() {
        var record = used(0)
        XCTAssertFalse(Telemetry.reportDue(record, now: at(26, 8), calendar: berlin))
        record.lastSent = at(19, 9)
        XCTAssertFalse(Telemetry.reportDue(record, now: at(26, 8), calendar: berlin))
        XCTAssertTrue(Telemetry.reportDue(record, now: at(26, 10), calendar: berlin))
    }

    func testACrashIsWorthAReportWithoutUse() {
        var record = used(0)
        record.crashes = [crash()]
        XCTAssertTrue(Telemetry.reportDue(record, now: at(26, 8), calendar: berlin))
    }

    // A failed request is not retried at once; after three, not before the next day.
    func testAFailedRequestWaitsBeforeTheNextTry() {
        var record = used()
        record.failed(at: at(26, 8))
        XCTAssertFalse(Telemetry.reportDue(record, now: at(26, 8).addingTimeInterval(10 * 60), calendar: berlin))
        XCTAssertTrue(Telemetry.reportDue(record, now: at(26, 9), calendar: berlin))
        record.failed(at: at(26, 9))
        record.failed(at: at(26, 10))
        XCTAssertFalse(Telemetry.reportDue(record, now: at(26, 23), calendar: berlin))
        XCTAssertTrue(Telemetry.reportDue(record, now: at(27, 0), calendar: berlin))
        record.failed(at: at(27, 0))
        XCTAssertFalse(Telemetry.reportDue(record, now: at(27, 12), calendar: berlin))
    }

    func testAReportThatArrivedEndsTheFailures() {
        var record = used()
        record.failed(at: at(26, 8))
        record.pendingReportTime = at(26, 8)
        record.sent(record.report, at: at(26, 9), text: "{}")
        XCTAssertEqual(record.failedSends, 0)
        XCTAssertNil(record.pendingReportTime)
        XCTAssertEqual(record.activeSeconds, 0)
    }

    // A minute with an agent at work counts; a night with the Mac asleep counts as two minutes.
    func testAgentTimeCountsOnlyWhileAnAgentWorks() {
        XCTAssertEqual(Telemetry.agentSeconds(sinceLastSample: 60, running: 2, interval: 60), 60)
        XCTAssertEqual(Telemetry.agentSeconds(sinceLastSample: 60, running: 0, interval: 60), 0)
        XCTAssertEqual(Telemetry.agentSeconds(sinceLastSample: 8 * 3600, running: 1, interval: 60), 120)
        XCTAssertEqual(Telemetry.agentSeconds(sinceLastSample: -30, running: 1, interval: 60), 0)
    }

    // A clock that was a year ahead and is right again must not hold reports back for a year.
    func testAReportFromAWrongClockDoesNotBlockTheNext() {
        var record = used()
        record.lastSent = at(26, 8).addingTimeInterval(365 * 24 * 3600)
        XCTAssertTrue(Telemetry.reportDue(record, now: at(26, 8), calendar: berlin))
        // A few minutes ahead is a clock being set, not a wrong one: still today's report.
        record.lastSent = at(26, 8).addingTimeInterval(5 * 60)
        XCTAssertFalse(Telemetry.reportDue(record, now: at(26, 8), calendar: berlin))
    }

    // MARK: The record

    func testAnEmptyFileIsANewUnansweredRecord() throws {
        let record = try decode("{}")
        XCTAssertNil(record.consent)
        XCTAssertTrue(record.features.isEmpty)
        XCTAssertFalse(record.running)
    }

    // A field of the wrong type costs that field, never the answer.
    func testABrokenFieldKeepsTheAnswer() throws {
        let record = try decode(#"{"consent":true,"features":"nonsense","uncleanExits":"x"}"#)
        XCTAssertEqual(record.consent, true)
        XCTAssertTrue(record.features.isEmpty)
        XCTAssertEqual(record.uncleanExits, 0)
    }

    func testARecordSurvivesASaveAndALoad() throws {
        var record = TelemetryRecord()
        record.consent = true
        record.features = ["split": 3]
        record.errors = ["hook-server.bind_failed": 1]
        record.activeSeconds = 125
        record.agentSeconds = 3600
        record.failedSends = 2
        record.lastAttempt = Date(timeIntervalSince1970: 1_800_000_100)
        record.pendingReportTime = Date(timeIntervalSince1970: 1_800_000_200)
        record.crashes = [CrashReport(time: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "0.2.55",
                                      exceptionType: "EXC_BAD_ACCESS", signal: "SIGSEGV", frames: ["Planchette main"])]
        let back = try JSONDecoder().decode(TelemetryRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(back, record)
    }

    func testNothingIsCollectedAfterANo() {
        var record = TelemetryRecord()
        record.consent = false
        record.absorb(features: ["split": 2], errors: ["x.y": 1], activeSeconds: 60, agentSeconds: 60)
        XCTAssertTrue(record.features.isEmpty)
        XCTAssertTrue(record.errors.isEmpty)
        XCTAssertEqual(record.activeSeconds, 0)
        XCTAssertEqual(record.agentSeconds, 0)
    }

    // Nothing is counted before the yes: a report never carries what happened before it.
    func testCountingStartsWithTheYes() {
        var record = TelemetryRecord()
        record.absorb(features: ["split": 2], errors: ["a.b": 1], activeSeconds: 60)
        record.add(crashes: [crash()])
        XCTAssertTrue(record.features.isEmpty)
        XCTAssertTrue(record.crashes.isEmpty)
        XCTAssertEqual(record.activeSeconds, 0)
        record.consent = true
        record.absorb(features: ["split": 1, "quick_switcher": 1], errors: [:])
        record.absorb(features: ["split": 1], errors: [:])
        XCTAssertEqual(record.features, ["split": 2, "quick_switcher": 1])
    }

    // What was counted while the request was on its way belongs to the next report.
    func testASentReportTakesOffOnlyWhatItCarried() {
        var record = TelemetryRecord()
        record.consent = true
        record.features = ["split": 3]
        record.errors = ["a.b": 1]
        record.uncleanExits = 1
        record.activeSeconds = 300
        record.agentSeconds = 600
        let report = record.report
        record.absorb(features: ["split": 2, "find_in_terminal": 1], errors: ["a.b": 1],
                      activeSeconds: 40, agentSeconds: 120)
        record.sent(report, at: Date(timeIntervalSince1970: 1), text: "{}")
        XCTAssertEqual(record.features, ["split": 2, "find_in_terminal": 1])
        XCTAssertEqual(record.errors, ["a.b": 1])
        XCTAssertEqual(record.uncleanExits, 0)
        XCTAssertEqual(record.activeSeconds, 40)
        XCTAssertEqual(record.agentSeconds, 120)
        XCTAssertEqual(record.lastSent, Date(timeIntervalSince1970: 1))
    }

    // Retention counts days of use, and one report can cover two of them.
    func testAReportCountsTheDaysOfUse() {
        var record = TelemetryRecord()
        record.consent = true
        record.absorb(features: [:], errors: [:], activeSeconds: 600, day: "2026-11-26")
        record.absorb(features: [:], errors: [:], activeSeconds: 0, day: "2026-11-27")
        record.absorb(features: [:], errors: [:], activeSeconds: 60, day: "2026-11-27")
        record.absorb(features: [:], errors: [:], activeSeconds: 60, day: "2026-11-27")
        XCTAssertEqual(record.activeDays, ["2026-11-26", "2026-11-27"])
        let body = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        XCTAssertEqual((events(body)[0]["properties"] as? [String: Any])?["active_days"] as? Int, 2)
        let report = record.report
        record.sent(report, at: Date(), text: "{}")
        XCTAssertTrue(record.activeDays.isEmpty)
        XCTAssertEqual(TelemetryPayload.day(Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian)).count, 10)
    }

    // The answer time is a bucket, never the exact seconds.
    func testAnAnswerTimeIsABucket() {
        XCTAssertEqual(Telemetry.waitAnswered(after: 5), .waitAnsweredUnder30s)
        XCTAssertEqual(Telemetry.waitAnswered(after: 30), .waitAnsweredUnder5m)
        XCTAssertEqual(Telemetry.waitAnswered(after: 299), .waitAnsweredUnder5m)
        XCTAssertEqual(Telemetry.waitAnswered(after: 600), .waitAnsweredUnder30m)
        XCTAssertEqual(Telemetry.waitAnswered(after: 4 * 3600), .waitAnsweredOver30m)
    }

    func testMetricsAreCountedAndTakenOffLikeFeatures() {
        var record = TelemetryRecord()
        record.consent = true
        record.absorb(features: [:], errors: [:], metrics: ["hook_events": 40, "state_by_screen": 2])
        let report = record.report
        record.absorb(features: [:], errors: [:], metrics: ["hook_events": 3])
        record.sent(report, at: Date(), text: "{}")
        XCTAssertEqual(record.metrics, ["hook_events": 3])
    }

    // A high is kept until a report carried it; a higher one reached meanwhile waits for the next.
    func testAPeakKeepsTheHighestValue() {
        var record = TelemetryRecord()
        record.observe(.terminals, 9)
        XCTAssertTrue(record.peaks.isEmpty, "nothing before the yes")
        record.consent = true
        record.observe(.terminals, 4)
        record.observe(.terminals, 9)
        record.observe(.terminals, 6)
        record.observe(.agentsRunning, 3)
        XCTAssertEqual(record.peaks, ["peak_terminals": 9, "peak_agents_running": 3])
        let report = record.report
        record.observe(.agentsRunning, 5)
        record.sent(report, at: Date(), text: "{}")
        XCTAssertEqual(record.peaks, ["peak_agents_running": 5])
    }

    // Every metric and every peak is a column, 0 included, like the features.
    func testTheSnapshotCarriesEveryMetricAndPeak() {
        var record = TelemetryRecord()
        record.firstSeen = Date(timeIntervalSince1970: 1_800_000_000 - 10 * 86400)
        record.metrics = ["state_by_hook": 12]
        var snapshot = TelemetrySnapshot()
        snapshot.hookClaude = HookStatus.ok.rawValue
        snapshot.notifications = "denied"
        let body = TelemetryPayload.batch(record, snapshot: snapshot, context: context())
        let properties = events(body)[0]["properties"] as? [String: Any] ?? [:]
        for name in TelemetryMetric.allCases.map(\.rawValue) + TelemetryPeak.allCases.map(\.rawValue) {
            XCTAssertNotNil(properties[name], name)
        }
        XCTAssertEqual(properties["state_by_hook"] as? Int, 12)
        XCTAssertEqual(properties["wait_answered_lt30s"] as? Int, 0)
        XCTAssertEqual(properties["install_age_days"] as? Int, 10)
        XCTAssertEqual(properties["hook_claude"] as? String, "ok")
        XCTAssertEqual(properties["hook_codex"] as? String, "not_tried")
        XCTAssertEqual(properties["notifications"] as? String, "denied")
    }

    func testTheCounterKeepsMetricsApart() {
        let counter = TelemetryCounter()
        counter.add(metric: "hook_events")
        counter.add(feature: "split")
        let drained = counter.drain()
        XCTAssertEqual(drained.metrics, ["hook_events": 1])
        XCTAssertEqual(drained.features, ["split": 1])
    }

    func testTheCounterHandsOverAndStartsAgain() {
        let counter = TelemetryCounter()
        counter.add(feature: "split")
        counter.add(feature: "split")
        counter.add(error: "a.b")
        let first = counter.drain()
        XCTAssertEqual(first.features, ["split": 2])
        XCTAssertEqual(first.errors, ["a.b": 1])
        XCTAssertTrue(counter.drain().features.isEmpty)
    }

    func testTheCounterIsSafeFromManyThreads() {
        let counter = TelemetryCounter()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in counter.add(feature: "split") }
        XCTAssertEqual(counter.drain().features["split"], 1000)
    }

    // MARK: The report

    func testTheSnapshotCarriesEveryFeatureEvenTheUnusedOnes() {
        var record = TelemetryRecord()
        record.features = ["split": 4]
        let body = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        let snapshot = events(body).first { $0["event"] as? String == "daily_snapshot" }
        let properties = snapshot?["properties"] as? [String: Any] ?? [:]
        for feature in TelemetryFeature.allCases {
            XCTAssertNotNil(properties["f_\(feature.rawValue)"], feature.rawValue)
        }
        XCTAssertEqual(properties["f_split"] as? Int, 4)
        XCTAssertEqual(properties["f_quick_switcher"] as? Int, 0)
    }

    func testTheReportIsAnonymous() {
        let record = TelemetryRecord()
        let body = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        XCTAssertEqual(body["api_key"] as? String, "phc_test")
        for event in events(body) {
            let properties = event["properties"] as? [String: Any] ?? [:]
            XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
            XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
            XCTAssertEqual(event["distinct_id"] as? String, record.installID.uuidString.lowercased())
        }
    }

    // Errors are columns of the one snapshot, not events of their own: one event a report.
    func testErrorsAreColumnsOfTheSnapshot() {
        var record = TelemetryRecord()
        record.errors = ["hook-server.bind_failed": 2, "update.swap_failed": 1]
        let body = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        XCTAssertEqual(events(body).count, 1)
        let properties = events(body)[0]["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(properties["e_hook_server_bind_failed"] as? Int, 2)
        XCTAssertEqual(properties["e_update_swap_failed"] as? Int, 1)
        XCTAssertEqual(properties["errors"] as? Int, 3)
    }

    func testTheSnapshotCarriesTheMinutesOfUse() {
        var record = TelemetryRecord()
        record.activeSeconds = 3 * 60 + 59
        record.agentSeconds = 90 * 60
        let body = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        let properties = events(body)[0]["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(properties["active_minutes"] as? Int, 3)
        XCTAssertEqual(properties["agent_minutes"] as? Int, 90)
    }

    // A retry of a report that did arrive is the same event again, which PostHog keeps once.
    func testARetrySendsTheSameEventIDs() {
        var record = TelemetryRecord()
        record.crashes = [crash()]
        let first = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        record.features = ["split": 1]
        let retry = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        let ids = { (body: [String: Any]) in self.events(body).compactMap { $0["uuid"] as? String } }
        XCTAssertEqual(ids(first).count, 2)
        XCTAssertEqual(ids(first), ids(retry))
        XCTAssertNotNil(UUID(uuidString: ids(first)[0]))
        XCTAssertNotEqual(ids(first)[0], ids(first)[1])
        // The next period is a new event.
        record.lastSent = Date(timeIntervalSince1970: 1_800_000_000)
        let next = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        XCTAssertNotEqual(ids(next)[0], ids(first)[0])
    }

    func testARequestNeverCarriesMoreThanFiveEvents() {
        var record = TelemetryRecord()
        record.crashes = (0..<10).map { crash(frames: ["Planchette f\($0)()"]) }
        record.errors = Dictionary(uniqueKeysWithValues: (0..<40).map { ("area.e\($0)", 1) })
        let body = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        XCTAssertEqual(events(body).count, 1 + Telemetry.maxCrashesPerReport)
        XCTAssertLessThanOrEqual(events(body).count, Telemetry.maxEventsPerRequest)
    }

    // MARK: Crashes, grouped

    private func crash(frames: [String] = ["Planchette AppState.saveNow()", "libswiftCore.dylib swift_crash"],
                       version: String = "0.2.54") -> CrashReport {
        CrashReport(time: Date(timeIntervalSince1970: 1_800_000_000), appVersion: version,
                    exceptionType: "EXC_BREAKPOINT", signal: "SIGTRAP", frames: frames)
    }

    // A crash at every launch is one entry with a count — one exception in PostHog, not fifty.
    func testTheSameCrashAgainRaisesTheCount() {
        var record = TelemetryRecord()
        record.consent = true
        record.add(crashes: Array(repeating: crash(), count: 50))
        record.add(crashes: [crash(frames: ["Planchette Other.f()"]), crash(version: "0.2.55")])
        XCTAssertEqual(record.crashes.map(\.count), [50, 1, 1])
    }

    // The frames of system libraries below Planchette's own do not split a crash in two.
    func testTheSignatureReadsPlanchettesOwnFrames() {
        let a = crash(frames: ["libsystem_kernel.dylib +0x1", "Planchette A.f()", "Planchette B.g()"])
        let b = crash(frames: ["libsystem_kernel.dylib +0x2", "Planchette A.f()", "Planchette B.g()"])
        XCTAssertEqual(a.signature, b.signature)
    }

    func testFewCrashesAreKept() {
        var record = TelemetryRecord()
        record.consent = true
        record.add(crashes: (0..<30).map { crash(frames: ["Planchette f\($0)()"]) })
        XCTAssertEqual(record.crashes.count, Telemetry.maxCrashesKept)
    }

    func testNoCrashIsKeptAfterANo() {
        var record = TelemetryRecord()
        record.consent = false
        record.add(crashes: [crash()])
        XCTAssertTrue(record.crashes.isEmpty)
    }

    // A report carries three crashes; the rest, and a crash that came again meanwhile, wait.
    func testASentReportTakesOffOnlyTheCrashesItCarried() {
        var record = TelemetryRecord()
        record.consent = true
        record.add(crashes: (0..<5).map { crash(frames: ["Planchette f\($0)()"]) })
        let report = record.report
        XCTAssertEqual(report.crashes.count, Telemetry.maxCrashesPerReport)
        record.add(crashes: [crash(frames: ["Planchette f0()"])])
        record.sent(report, at: Date(), text: "{}")
        XCTAssertEqual(record.crashes.map(\.frames.first), ["Planchette f0()", "Planchette f3()", "Planchette f4()"])
        XCTAssertEqual(record.crashes.first?.count, 1)
    }

    // A record written before crashes had a count still loads its crashes.
    func testACrashWithoutACountIsOne() throws {
        let json = #"{"crashes":[{"time":0,"appVersion":"1","exceptionType":"EXC_CRASH","frames":[]}]}"#
        XCTAssertEqual(try decode(json).crashes.first?.count, 1)
    }

    func testACrashIsAnExceptionForPostHogsErrorTracking() {
        var record = TelemetryRecord()
        record.crashes = [CrashReport(time: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "0.2.54",
                                      exceptionType: "EXC_BREAKPOINT", signal: "SIGTRAP",
                                      frames: ["Planchette AppState.saveNow()", "libswiftCore.dylib swift_crash"])]
        let body = TelemetryPayload.batch(record, snapshot: TelemetrySnapshot(), context: context())
        let crash = events(body).first { $0["event"] as? String == "$exception" }
        let properties = crash?["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(properties["app_version"] as? String, "0.2.54")
        XCTAssertEqual(properties["count"] as? Int, 1)
        let list = properties["$exception_list"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.first?["type"] as? String, "EXC_BREAKPOINT")
        let frames = (list.first?["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? []
        XCTAssertEqual(frames.first?["function"] as? String, "AppState.saveNow()")
        XCTAssertEqual(frames.first?["in_app"] as? Bool, true)
        XCTAssertEqual(frames.last?["in_app"] as? Bool, false)
    }

    func testTheReportShownInSettingsHidesTheKey() {
        let body = TelemetryPayload.batch(TelemetryRecord(), snapshot: TelemetrySnapshot(), context: context())
        let text = TelemetryPayload.readable(body)
        XCTAssertFalse(text.contains("phc_test"))
        XCTAssertTrue(text.contains("daily_snapshot"))
    }

    // MARK: Crash reports

    private func ips(app: String = "Planchette", bugType: String = "309", simulated: Int = 0) -> String {
        let header = #"{"app_name":"\#(app)","timestamp":"2026-11-26 08:57:29.00 +0100","app_version":"0.2.54","bug_type":"\#(bugType)","is_simulated":\#(simulated)}"#
        let body = """
        {
          "procPath" : "/Users/someone/Applications/Planchette.app/Contents/MacOS/Planchette",
          "exception" : {"type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV"},
          "faultingThread" : 1,
          "threads" : [
            {"frames" : [{"imageOffset" : 1, "symbol" : "mach_msg", "imageIndex" : 1}]},
            {"triggered" : true, "frames" : [
              {"imageOffset" : 4096, "symbol" : "AppState.saveNow()", "imageIndex" : 0},
              {"imageOffset" : 255, "imageIndex" : 1}
            ]}
          ],
          "usedImages" : [
            {"name" : "Planchette", "path" : "/Users/someone/Applications/Planchette.app/Contents/MacOS/Planchette"},
            {"name" : "libsystem_kernel.dylib", "path" : "/usr/lib/system/libsystem_kernel.dylib"}
          ]
        }
        """
        return header + "\n" + body
    }

    func testACrashReportGivesTheCrashedThreadWithoutPaths() throws {
        let crash = try XCTUnwrap(CrashReport.parse(ips: ips()))
        XCTAssertEqual(crash.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(crash.signal, "SIGSEGV")
        XCTAssertEqual(crash.appVersion, "0.2.54")
        XCTAssertEqual(crash.frames, ["Planchette AppState.saveNow()", "libsystem_kernel.dylib +0xff"])
        let encoded = String(decoding: try JSONEncoder().encode(crash), as: UTF8.self)
        XCTAssertFalse(encoded.contains("someone"))
        XCTAssertEqual(crash.time, CrashReport.crashTime("2026-11-26 08:57:29.00 +0100"))
    }

    // A third-party library in the crashed thread says what else is installed: its name is "?".
    func testAThirdPartyLibraryIsNotNamed() throws {
        let text = ips().replacingOccurrences(
            of: #"{"name" : "libsystem_kernel.dylib", "path" : "/usr/lib/system/libsystem_kernel.dylib"}"#,
            with: #"{"name" : "SecretVPNAgent", "path" : "/Library/Application Support/SecretVPN/agent.dylib"}"#)
        let crash = try XCTUnwrap(CrashReport.parse(ips: text))
        XCTAssertEqual(crash.frames, ["Planchette AppState.saveNow()", "? +0xff"])
    }

    func testOnlyRealCrashesOfPlanchetteCount() {
        XCTAssertNil(CrashReport.parse(ips: ips(app: "Ghostty")))
        XCTAssertNil(CrashReport.parse(ips: ips(bugType: "288")))
        XCTAssertNil(CrashReport.parse(ips: ips(simulated: 1)))
        XCTAssertNil(CrashReport.parse(ips: "not a report"))
    }

    // MARK: The texts

    func testEveryTelemetryTextIsTranslated() {
        let keys = LKey.allCases.filter { $0.rawValue.hasPrefix("telemetry") } + [.privacyTab, .helpWhereSettingsPrivacy]
        XCTAssertGreaterThan(keys.count, 20)
        for language in AppLanguage.allCases where language != .system {
            let saved = L10n.current
            L10n.current = language
            defer { L10n.current = saved }
            for key in keys {
                XCTAssertNotEqual(L10n.t(key), key.rawValue, "\(language) \(key)")
            }
        }
    }
}

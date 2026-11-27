import AppKit
import Foundation
import UserNotifications

/// What is on screen at one moment, sampled once a minute: agent time and the highs.
struct TelemetryLive {
    var terminals = 0
    var agentsRunning = 0
    var waiting = 0
}

/// The side effects of telemetry: `telemetry.json`, the hourly tick, the crash-report scan and
/// the request to PostHog. What is decided and what is sent is `Telemetry.swift`.
///
/// Nothing leaves the Mac before the user said yes (`TelemetryRecord.consent`), and never from
/// a build that cannot send: an isolated instance (a demo or a test), an unbundled dev run, or
/// a build without a project key.
@MainActor
final class TelemetryService: ObservableObject {
    static let shared = TelemetryService()

    @Published private(set) var record: TelemetryRecord
    /// The question is on screen (`TelemetryPromptSheet`).
    @Published var promptShown = false
    @Published private(set) var sending = false

    private var snapshot: (() -> TelemetrySnapshot)?
    /// What is on screen right now (`AppState.telemetryLive`).
    private var live: (() -> TelemetryLive)?
    /// `UNAuthorizationStatus` as a word, read at each tick (the user can change it any time).
    private var notificationStatus = "unknown"
    private var timer: Timer?
    private var agentTimer: Timer?
    /// The last look at the agents, and the agent time not yet in the record.
    private var lastAgentSample: Date?
    private var agentSeconds = 0
    private var started = false
    /// Since when Planchette is the frontmost app, with the screens awake; nil while it is not.
    private var activeSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var scanning = false

    /// Whether this run owns `telemetry.json`: a packaged app, or an isolated instance with its
    /// own folder. A dev run from the build folder shares the real folder with the installed
    /// app, and writing its stale record over the app's would send a report twice.
    private var ownsFile: Bool {
        Bundle.main.bundleURL.pathExtension == "app" || SupportPaths.isIsolated
    }

    static var url: URL { SupportPaths.dir.appendingPathComponent("telemetry.json") }
    nonisolated static let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// This build can send at all: a key, a packaged app, not an isolated instance.
    var canSend: Bool {
        !Telemetry.projectKey.isEmpty && !SupportPaths.isIsolated
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    private init() {
        record = Self.load()
    }

    /// At launch, once: note whether the last run ended by a quit, start the hourly tick, and
    /// look for crashes and a due report a minute later — not during the restore.
    func start(snapshot: @escaping () -> TelemetrySnapshot, live: @escaping () -> TelemetryLive) {
        guard !started else { return }
        started = true
        self.snapshot = snapshot
        self.live = live
        if record.running, record.consent == true { record.uncleanExits += 1 }
        record.running = true
        save()
        watchActivity()

        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in TelemetryService.shared.tick() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let agentTimer = Timer(timeInterval: Self.agentSampleInterval, repeats: true) { _ in
            Task { @MainActor in TelemetryService.shared.sampleAgents() }
        }
        agentTimer.tolerance = 10
        RunLoop.main.add(agentTimer, forMode: .common)
        self.agentTimer = agentTimer
        lastAgentSample = Date()
        Task {
            try? await Task.sleep(for: .seconds(60))
            tick()
        }
    }

    /// The app quits: keep what was counted, and mark the run as ended cleanly.
    func stop() {
        flush()
        record.running = false
        save()
    }

    /// Move the counts, the foreground time and the agent time collected in memory into the
    /// record and write it.
    func flush(now: Date = Date()) {
        let collected = TelemetryCounter.shared.drain()
        var seconds = 0
        if let since = activeSince {
            seconds = max(0, Int(now.timeIntervalSince(since)))
            activeSince = since.addingTimeInterval(TimeInterval(seconds))
        }
        let agents = agentSeconds
        agentSeconds = 0
        guard !collected.features.isEmpty || !collected.errors.isEmpty || !collected.metrics.isEmpty
                || seconds > 0 || agents > 0 else { return }
        record.absorb(features: collected.features, errors: collected.errors, metrics: collected.metrics,
                      activeSeconds: seconds, agentSeconds: agents, day: TelemetryPayload.day(now))
        save()
    }

    static let agentSampleInterval: TimeInterval = 60

    /// Once a minute: if an agent's turn is running, the minute counts — in front or not, which
    /// is where an agent mostly works. A gap longer than two samples (the Mac slept) counts as
    /// two samples, not as the night. And the highs (`TelemetryPeak`): how many terminals, how
    /// many agents at work, how many questions open at one time. Agent time stays in memory
    /// until the next flush; a high is written only when it is new — no write a minute.
    private func sampleAgents(now: Date = Date()) {
        let gap = lastAgentSample.map { now.timeIntervalSince($0) } ?? Self.agentSampleInterval
        lastAgentSample = now
        guard record.consent == true, let screen = live?() else { return }
        agentSeconds += Telemetry.agentSeconds(sinceLastSample: gap, running: screen.agentsRunning,
                                               interval: Self.agentSampleInterval)
        let before = record.peaks
        record.observe(.terminals, screen.terminals)
        record.observe(.agentsRunning, screen.agentsRunning)
        record.observe(.waiting, screen.waiting)
        if record.peaks != before { save() }
    }

    /// The snapshot with what `AppState` does not know: the hook install and the notifications.
    private func currentSnapshot() -> TelemetrySnapshot {
        var snapshot = snapshot?() ?? TelemetrySnapshot()
        snapshot.hookClaude = HookInstallStatus.shared.claude.rawValue
        snapshot.hookCodex = HookInstallStatus.shared.codex.rawValue
        snapshot.notifications = notificationStatus
        return snapshot
    }

    private func readNotificationStatus() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = switch settings.authorizationStatus {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "not_determined"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }

    /// Foreground time is what makes a day worth a report (`Telemetry.minActiveSeconds`): the
    /// clock runs while Planchette is the frontmost app and the screens are awake — not over
    /// a night with the app left in front.
    private func watchActivity() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let on: (Notification) -> Void = { _ in
            MainActor.assumeIsolated { TelemetryService.shared.activity(NSApp.isActive) }
        }
        let off: (Notification) -> Void = { _ in
            MainActor.assumeIsolated { TelemetryService.shared.activity(false) }
        }
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: on),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: off),
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: on),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: off),
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: off),
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: off),
            workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: on),
            // A locked screen with the displays kept on (`caffeinate -d`, common beside agents).
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: off),
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: on),
        ]
        activity(NSApp.isActive)
    }

    private func activity(_ active: Bool) {
        if active {
            if activeSince == nil { activeSince = Date() }
        } else {
            flush()
            activeSince = nil
        }
    }

    private func tick() {
        flush()
        guard record.consent == true, canSend else { return }
        Task {
            await readNotificationStatus()
            await scanCrashes()
            sendIfDue()
        }
    }

    // MARK: The question

    /// Once the main window is up and the onboarding had its turn: ask, if it is due
    /// (`Telemetry.promptDue`) and no other sheet is open.
    func evaluatePrompt(welcomeSeen: Bool, otherSheetShown: Bool) {
        guard !otherSheetShown, !Telemetry.projectKey.isEmpty, Bundle.main.bundleURL.pathExtension == "app"
        else { return }
        if Telemetry.promptDue(record, runningVersion: OnboardingState.runningVersion,
                               welcomeSeen: welcomeSeen, isolated: SupportPaths.isIsolated,
                               keyConfigured: true) {
            promptShown = true
        }
    }

    /// The question was closed without an answer: ask again after the next update, not before.
    func promptClosed() {
        if record.consent == nil { record.askedVersion = OnboardingState.runningVersion }
        promptShown = false
        save()
    }

    /// Yes or no — from the question or from Settings. No forgets what was collected.
    func setConsent(_ share: Bool) {
        // Crash reports from before the yes — or from a time the answer was no — stay on the
        // Mac: the scan starts now.
        if share, record.consent != true || record.lastCrashScan == nil { record.lastCrashScan = Date() }
        record.consent = share
        record.askedVersion = OnboardingState.runningVersion
        if !share {
            record.clearCollected()
            _ = TelemetryCounter.shared.drain()
        }
        promptShown = false
        save()
        if share { tick() }
    }

    /// A new random id: from now on, reports cannot be linked to the ones before.
    func resetInstallID() {
        record.installID = UUID()
        save()
    }

    /// The report as it would go out now, for the question's "show the report": the same
    /// builder and the same view as Settings shows for a report that was sent.
    func previewReport(now: Date = Date()) -> String {
        flush(now: now)
        let body = TelemetryPayload.batch(record.report, snapshot: currentSnapshot(), context: .init(
            apiKey: "", appVersion: OnboardingState.runningVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, now: now))
        return TelemetryPayload.readable(body)
    }

    // MARK: Sending

    /// One request at most, and only when `Telemetry.reportDue` says so — which reads the
    /// record, so a restart, a second tick or a bug that calls this in a loop cannot send more.
    private func sendIfDue(now: Date = Date()) {
        flush(now: now)
        guard canSend, !sending, Telemetry.reportDue(record, now: now), snapshot != nil else { return }
        // A retry keeps the time of the first try: same timestamps, same event ids.
        if record.pendingReportTime == nil { record.pendingReportTime = now }
        let report = record.report
        let body = TelemetryPayload.batch(report, snapshot: currentSnapshot(), context: .init(
            apiKey: Telemetry.projectKey,
            appVersion: OnboardingState.runningVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            now: record.pendingReportTime ?? now))
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let text = TelemetryPayload.readable(body)
        save()  // the pending time is on disk before the request leaves
        sending = true
        Task {
            let delivered = await Self.post(data)
            sending = false
            if delivered {
                record.sent(report, at: now, text: text)
            } else {
                record.failed(at: now)
                Log.error("telemetry.send_failed", "the report did not reach PostHog (\(record.failedSends) in a row)")
            }
            save()
        }
    }

    nonisolated private static func post(_ data: Data) async -> Bool {
        var request = URLRequest(url: Telemetry.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Crashes

    /// Read the crash reports macOS wrote for Planchette since the last scan. Off the main
    /// thread: a report is a few hundred kilobytes of JSON.
    private func scanCrashes(now: Date = Date()) async {
        // One scan at a time, and the window moves before the read: two ticks close together
        // (a yes right at the launch tick) must not read the same files twice.
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let since = record.lastCrashScan ?? now
        record.lastCrashScan = now
        let found = await Task.detached(priority: .utility) { () -> [CrashReport] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: Self.crashDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            else { return [] }
            return files
                .filter { $0.lastPathComponent.hasPrefix("Planchette") && $0.pathExtension == "ips" }
                .filter { url in
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    return (date ?? .distantPast) > since
                }
                .compactMap { url in
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                    return CrashReport.parse(ips: text)
                }
        }.value
        record.add(crashes: found)
        record.lastCrashScan = now
        save()
    }

    // MARK: File

    private static func load() -> TelemetryRecord {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(TelemetryRecord.self, from: data)
        else { return TelemetryRecord() }
        return record
    }

    private func save() {
        guard ownsFile else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: Self.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        } catch {
            Log.error("telemetry.save_failed", "could not write \(Self.url.path): \(error)")
        }
    }
}

extension AppState {
    /// Agents whose turn is running: a Claude or Codex terminal working on a prompt — not a
    /// terminal kept `running` only by a dev server in its background (`turnState`).
    func agentsRunning() -> Int {
        sessions.values.filter { $0.agentKind != .none && turnState(of: $0.id) == .running }.count
    }

    /// What is on screen now, for the minute sample: terminals, agents at work, and open
    /// questions the user has not silenced (`isMuted`, the filter for everything that asks).
    func telemetryLive() -> TelemetryLive {
        TelemetryLive(
            terminals: sessions.count,
            agentsRunning: agentsRunning(),
            waiting: sessions.values.filter { $0.state == .waiting && !isMuted($0) }.count)
    }

    /// The workspace as numbers, for the daily report.
    func telemetrySnapshot() -> TelemetrySnapshot {
        let all = Array(sessions.values)
        var snapshot = TelemetrySnapshot()
        snapshot.windows = windows.count
        snapshot.folders = windows.reduce(0) { $0 + $1.folders.count }
        snapshot.projects = groups.count
        snapshot.parkedProjects = groups.filter { !$0.active }.count
        snapshot.worktreeProjects = groups.filter { $0.worktreePath != nil }.count
        let strips = groups.map { tabs(of: $0) }
        snapshot.tabs = strips.reduce(0) { $0 + $1.count }
        snapshot.splitTabs = strips.reduce(0) { $0 + $1.filter { $0.leaves.count > 1 }.count }
        snapshot.terminals = all.count
        snapshot.durableTerminals = all.filter(\.durable).count
        snapshot.claudeTerminals = all.filter { $0.agentKind == .claude }.count
        snapshot.codexTerminals = all.filter { $0.agentKind == .codex }.count
        snapshot.taggedTerminals = all.filter { !$0.tags.isEmpty }.count
        snapshot.tagsInList = tagList.count
        snapshot.presets = presets.count
        snapshot.todos = todos.items.count
        snapshot.openReviews = reviews.count
        snapshot.aiEnabled = aiEnabled
        snapshot.durableDefault = durableTerminals
        snapshot.tmuxAvailable = Durable.isAvailable
        snapshot.reviewsEnabled = reviewsEnabled
        snapshot.todosEnabled = todosEnabled
        snapshot.jiraEnabled = jiraEnabled
        snapshot.claudeSleep = claudeSleep.rawValue
        snapshot.language = language.rawValue
        snapshot.appearance = appearance.rawValue
        snapshot.autoUpdateCheck = autoUpdateCheck
        return snapshot
    }
}

import CryptoKit
import Foundation

/// Usage data and error reports under a random ID, sent to PostHog (EU) only after the user said yes.
///
/// Everything here is pure and unit-tested: what is recorded (`TelemetryRecord`), when the
/// question is due and when a report is (`Telemetry`), what a report holds
/// (`TelemetryPayload`), and what is read off a crash report (`CrashReport`). The side
/// effects — the file, the timer, the request — are `TelemetryService`.
///
/// **What leaves the Mac is numbers and fixed names, never content.** No path, title, prompt,
/// branch, ticket, tag name or terminal text: a feature is a `TelemetryFeature` case, an error
/// is the `StaticString` key its `Log.error` call was written with, a crash is its exception
/// type and the function names of the crashed thread. The id is a random UUID made on this
/// Mac, not derived from anything. PostHog is told to keep no person profile and to look up
/// no location from the IP address.
enum Telemetry {
    /// The PostHog project key. Public by design: it can only write events, not read them.
    /// Empty = telemetry is built in but switched off for this build (no question, no request).
    static let projectKey = "phc_sEs9ribNR8QVUocsGtXACajdSXW8EtwCHVrdvxFsv7bY"
    /// PostHog's EU cloud: the data stays in the EU.
    static let endpoint = URL(string: "https://eu.i.posthog.com/batch/")!
    /// What is sent, field by field — linked from the question.
    static let docsURL = URL(string: "https://github.com/marcello-a/Planchette/blob/main/docs/TELEMETRY.md")!

    /// Count one use of a feature. Any thread; costs a lock and a dictionary write.
    static func count(_ feature: TelemetryFeature) {
        TelemetryCounter.shared.add(feature: feature.rawValue)
    }

    /// Count one event of how the app does its job (`TelemetryMetric`). Any thread.
    static func count(_ metric: TelemetryMetric) {
        TelemetryCounter.shared.add(metric: metric.rawValue)
    }

    /// A question answered: the time from `waiting` to the user opening the terminal, as a
    /// bucket — never the exact seconds.
    static func waitAnswered(after seconds: TimeInterval) -> TelemetryMetric {
        switch seconds {
        case ..<30: .waitAnsweredUnder30s
        case ..<300: .waitAnsweredUnder5m
        case ..<1800: .waitAnsweredUnder30m
        default: .waitAnsweredOver30m
        }
    }

    /// Whether to ask the question now: never asked, or asked in an earlier version and
    /// closed without an answer. Not over the welcome of a first launch (that screen has
    /// enough to say), not in an isolated instance (a demo or a test), and not in a build
    /// without a key — a question about something that cannot happen is a lie.
    static func promptDue(_ record: TelemetryRecord, runningVersion: String, welcomeSeen: Bool,
                          isolated: Bool, keyConfigured: Bool) -> Bool {
        guard keyConfigured, !isolated, welcomeSeen, record.consent == nil else { return false }
        return record.askedVersion != runningVersion
    }

    /// The agent time one sample adds: the gap since the last sample if an agent's turn is
    /// running, but never more than two samples — a gap that long was the Mac asleep.
    static func agentSeconds(sinceLastSample gap: TimeInterval, running: Int, interval: TimeInterval) -> Int {
        guard running > 0 else { return 0 }
        return Int(min(max(0, gap), 2 * interval))
    }

    // MARK: The budget
    //
    // PostHog's free tier is 1 million analytics events and 100,000 exceptions a month, billed
    // per event. These limits keep an install at one analytics event on a day it is used and at
    // none on a day it is not — enough for about 30,000 daily users. They hold however the rest
    // of the code behaves: a bug that calls `sendIfDue` in a loop still sends one request a day.

    /// A report waits at least this long after the last one, across restarts, and never goes
    /// out twice on one calendar day.
    static let minHoursBetweenReports: TimeInterval = 20
    /// The foreground time that makes a day worth a report. Less, and the counts wait.
    static let minActiveSeconds = 60
    /// An install that is not used still reports this often, so it is known to be alive.
    static let heartbeatDays: TimeInterval = 7
    /// Distinct crashes in one report; the rest wait for the next one.
    static let maxCrashesPerReport = 3
    /// The hard cap on one request, whatever the record holds.
    static let maxEventsPerRequest = 5
    /// Failed requests before the next try waits for the next calendar day.
    static let maxFailuresPerDay = 3
    /// The gap after a failed request — no retry loop, at most one try an hour.
    static let retryAfter: TimeInterval = 50 * 60
    /// Distinct crashes kept on the Mac while they wait.
    static let maxCrashesKept = 20

    /// Whether a report is due. Only with consent, never within `minHoursBetweenReports` of the
    /// last one or on its calendar day, not right after a failure, and only when there is
    /// something to say: a minute of use or a crash — or a week of silence (`heartbeatDays`).
    static func reportDue(_ record: TelemetryRecord, now: Date, calendar: Calendar = .current) -> Bool {
        guard record.consent == true else { return false }
        // A time more than a day ahead was written by a clock that was wrong and is right again:
        // read as "long ago", or a corrected clock would hold every report back until it caught up.
        let past = { (date: Date?) in date.flatMap { $0.timeIntervalSince(now) > 24 * 3600 ? nil : $0 } }
        let lastSent = past(record.lastSent)
        if let last = lastSent {
            if calendar.isDate(last, inSameDayAs: now) { return false }
            if now.timeIntervalSince(last) < minHoursBetweenReports * 3600 { return false }
        }
        if record.failedSends > 0, let attempt = past(record.lastAttempt) {
            if record.failedSends >= maxFailuresPerDay {
                if calendar.isDate(attempt, inSameDayAs: now) { return false }
            } else if now.timeIntervalSince(attempt) < retryAfter {
                return false
            }
        }
        if record.activeSeconds >= minActiveSeconds || !record.crashes.isEmpty { return true }
        guard let last = lastSent else { return record.lastSent != nil }
        return now.timeIntervalSince(last) >= heartbeatDays * 24 * 3600
    }
}

/// Every feature that is counted, by a name that never changes: it is a column in PostHog.
/// A feature nobody uses shows as `f_<name> = 0` in every report, which is the point —
/// "which features are not used" needs the zeros.
enum TelemetryFeature: String, CaseIterable, Codable {
    // Projects, folders, windows
    case projectCreated = "project_created"
    case folderCreated = "folder_created"
    case worktreeCreated = "worktree_created"
    case newWindow = "new_window"
    case moveToNewWindow = "move_to_new_window"
    case mergeWindow = "merge_window"
    case favoriteSet = "favorite_set"
    case projectParked = "project_parked"
    case importedTerminals = "imported_terminals"
    // Terminals and tabs
    case terminalOpened = "terminal_opened"
    case terminalReopened = "terminal_reopened"
    case split = "split"
    case tabsCombined = "tabs_combined"
    case tabsSeparated = "tabs_separated"
    case tabDropped = "tab_dropped"
    case markedFree = "marked_free"
    case snoozed = "snoozed"
    case tagAdded = "tag_added"
    case claudeWoken = "claude_woken"
    case ideOpened = "ide_opened"
    // Navigation
    case quickSwitcher = "quick_switcher"
    case jumpToWaiting = "jump_to_waiting"
    case findInTerminal = "find_in_terminal"
    case folderOverview = "folder_overview"
    // Notepad
    case notepadOpened = "notepad_opened"
    case notepadPromptSent = "notepad_prompt_sent"
    case notepadPromptDrafted = "notepad_prompt_drafted"
    case notepadFormatAI = "notepad_format_ai"
    // Arrangements
    case presetSaved = "preset_saved"
    case presetOpened = "preset_opened"
    // AI
    case summarizeAll = "summarize_all"
    case groupByTopic = "group_by_topic"
    // Panels
    case todosOpened = "todos_opened"
    case todoTerminal = "todo_terminal"
    case jiraOpened = "jira_opened"
    case jiraTerminal = "jira_terminal"
    case reviewStarted = "review_started"
    case reviewSent = "review_sent"
    case notificationsOpened = "notifications_opened"
    case reviewsOpened = "reviews_opened"
    case todoAdded = "todo_added"
    // Terminals, more
    case paneToOwnTab = "pane_to_own_tab"
    case markedRead = "marked_read"
    case markedUnread = "marked_unread"
    case renamed = "renamed"
    case colorSet = "color_set"
    // Updates
    case updateInstalled = "update_installed"
}

/// How the app does its job, as opposed to what the user does (`TelemetryFeature`): summed since
/// the last report, every case a column, 0 included. A raw value is a PostHog column: never rename.
enum TelemetryMetric: String, CaseIterable {
    /// Hook events that arrived — an install with agents but none of these has broken hooks.
    case hookEvents = "hook_events"
    /// State changes the hooks made, and the ones the screen made (`AttentionState.fromScreen`).
    case stateByHook = "state_by_hook"
    case stateByScreen = "state_by_screen"
    /// A question (`waiting`) raised while the user looked elsewhere, by how long it took them to
    /// open the terminal — the core promise of the app, measured.
    case waitAnsweredUnder30s = "wait_answered_lt30s"
    case waitAnsweredUnder5m = "wait_answered_lt5m"
    case waitAnsweredUnder30m = "wait_answered_lt30m"
    case waitAnsweredOver30m = "wait_answered_gt30m"
}

/// The most of something at one time since the last report, sampled once a minute.
enum TelemetryPeak: String, CaseIterable {
    case terminals = "peak_terminals"
    case agentsRunning = "peak_agents_running"
    case waiting = "peak_waiting"
}

/// Whether the hooks were written into an agent's config at this launch.
enum HookStatus: String {
    /// Not tried: an isolated instance, or the run has not got that far.
    case notTried = "not_tried"
    case ok
    case failed
    /// The agent is not installed (no `~/.codex`).
    case absent
}

/// What `HookInstaller` found, for the report. Written once from a background queue.
final class HookInstallStatus: @unchecked Sendable {
    static let shared = HookInstallStatus()
    private let lock = NSLock()
    private var values: (claude: HookStatus, codex: HookStatus) = (.notTried, .notTried)

    var claude: HookStatus { lock.lock(); defer { lock.unlock() }; return values.claude }
    var codex: HookStatus { lock.lock(); defer { lock.unlock() }; return values.codex }

    func set(claude: HookStatus? = nil, codex: HookStatus? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let claude { values.claude = claude }
        if let codex { values.codex = codex }
    }
}

/// What a report says about the workspace: counts and switches, read at the moment it is sent.
struct TelemetrySnapshot: Equatable {
    var windows = 0
    var folders = 0
    var projects = 0
    var parkedProjects = 0
    var worktreeProjects = 0
    var tabs = 0
    var splitTabs = 0
    var terminals = 0
    var durableTerminals = 0
    var claudeTerminals = 0
    var codexTerminals = 0
    var taggedTerminals = 0
    var tagsInList = 0
    var presets = 0
    var todos = 0
    var openReviews = 0
    // Settings
    var aiEnabled = false
    var durableDefault = false
    var tmuxAvailable = false
    var reviewsEnabled = false
    var todosEnabled = false
    var jiraEnabled = false
    var claudeSleep = ""
    var language = ""
    var appearance = ""
    var autoUpdateCheck = false
    // Integration
    var hookClaude = HookStatus.notTried.rawValue
    var hookCodex = HookStatus.notTried.rawValue
    /// `UNAuthorizationStatus` as a word: without "authorized", no banner leaves the app.
    var notifications = "unknown"

    /// The snapshot as PostHog properties. Keys are fixed; values are numbers, booleans and
    /// the raw values of enums the app defines — never something the user typed.
    var properties: [String: Any] {
        [
            "windows": windows, "folders": folders, "projects": projects,
            "parked_projects": parkedProjects, "worktree_projects": worktreeProjects,
            "tabs": tabs, "split_tabs": splitTabs, "terminals": terminals,
            "durable_terminals": durableTerminals, "claude_terminals": claudeTerminals,
            "codex_terminals": codexTerminals, "tagged_terminals": taggedTerminals,
            "tags_in_list": tagsInList, "presets": presets, "todos": todos,
            "open_reviews": openReviews,
            "setting_ai": aiEnabled, "setting_durable": durableDefault,
            "tmux_available": tmuxAvailable, "setting_reviews": reviewsEnabled,
            "setting_todos": todosEnabled, "setting_jira": jiraEnabled,
            "setting_claude_sleep": claudeSleep, "setting_language": language,
            "setting_appearance": appearance, "setting_auto_update": autoUpdateCheck,
            "hook_claude": hookClaude, "hook_codex": hookCodex, "notifications": notifications,
        ]
    }
}

/// Everything telemetry keeps, in `telemetry.json` beside `state.json` — deliberately not in
/// it: the answer to the question belongs to the person, not to a workspace, so "Start fresh"
/// must not ask again, and counters that change on every click must not rewrite the workspace.
struct TelemetryRecord: Codable, Equatable {
    /// Random, made once on this Mac. "Reset" in Settings makes a new one.
    var installID = UUID()
    /// nil = not answered yet; true = share; false = do not share.
    var consent: Bool?
    /// The version that asked last, so a question closed without an answer comes back once
    /// after the next update and not on every launch.
    var askedVersion: String?
    /// Uses per `TelemetryFeature.rawValue` since the last report.
    var features: [String: Int] = [:]
    /// Errors per `Log.error` key since the last report.
    var errors: [String: Int] = [:]
    /// Launches that found the previous run had not ended by a quit (crash, force quit, kill).
    var uncleanExits = 0
    /// Set at launch, cleared at quit: still set at the next launch = an unclean exit.
    var running = false
    /// Crashes read from the system's reports, waiting for the next report — one entry per
    /// signature, with a count (`add(crashes:)`).
    var crashes: [CrashReport] = []
    /// The newest crash report already read, so none is sent twice.
    var lastCrashScan: Date?
    /// Seconds Planchette was the frontmost app since the last report.
    var activeSeconds = 0
    /// Seconds at least one agent's turn was running since the last report — in front or not.
    var agentSeconds = 0
    /// The calendar days ("2026-11-26") with time in front since the last report: a report can
    /// cover more than one day, and retention counts days, not reports.
    var activeDays: Set<String> = []
    /// `TelemetryMetric` counts since the last report.
    var metrics: [String: Int] = [:]
    /// `TelemetryPeak` highs since the last report.
    var peaks: [String: Int] = [:]
    /// When this record was made — the first launch of a version with telemetry. Only a date: the
    /// install's age, so a report can tell a new install from an old one.
    var firstSeen = Date()
    /// When the last report went out, and exactly what it was (Settings shows it).
    var lastSent: Date?
    var lastReport: String?
    /// The last request, and how many failed in a row since the last one that arrived.
    var lastAttempt: Date?
    var failedSends = 0
    /// The time of the report on its way, kept until it arrives: a retry sends the same
    /// timestamps and event ids, so PostHog keeps one copy, not two.
    var pendingReportTime: Date?

    init() {}

    // Tolerant on purpose: a file from another version costs a field, never the answer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installID = (try? c.decodeIfPresent(UUID.self, forKey: .installID)) ?? UUID()
        consent = try? c.decodeIfPresent(Bool.self, forKey: .consent)
        askedVersion = try? c.decodeIfPresent(String.self, forKey: .askedVersion)
        features = (try? c.decodeIfPresent([String: Int].self, forKey: .features)) ?? [:]
        errors = (try? c.decodeIfPresent([String: Int].self, forKey: .errors)) ?? [:]
        uncleanExits = (try? c.decodeIfPresent(Int.self, forKey: .uncleanExits)) ?? 0
        running = (try? c.decodeIfPresent(Bool.self, forKey: .running)) ?? false
        crashes = (try? c.decodeIfPresent([CrashReport].self, forKey: .crashes)) ?? []
        lastCrashScan = try? c.decodeIfPresent(Date.self, forKey: .lastCrashScan)
        activeSeconds = (try? c.decodeIfPresent(Int.self, forKey: .activeSeconds)) ?? 0
        agentSeconds = (try? c.decodeIfPresent(Int.self, forKey: .agentSeconds)) ?? 0
        activeDays = (try? c.decodeIfPresent(Set<String>.self, forKey: .activeDays)) ?? []
        metrics = (try? c.decodeIfPresent([String: Int].self, forKey: .metrics)) ?? [:]
        peaks = (try? c.decodeIfPresent([String: Int].self, forKey: .peaks)) ?? [:]
        firstSeen = (try? c.decodeIfPresent(Date.self, forKey: .firstSeen)) ?? Date()
        lastSent = try? c.decodeIfPresent(Date.self, forKey: .lastSent)
        lastReport = try? c.decodeIfPresent(String.self, forKey: .lastReport)
        lastAttempt = try? c.decodeIfPresent(Date.self, forKey: .lastAttempt)
        failedSends = (try? c.decodeIfPresent(Int.self, forKey: .failedSends)) ?? 0
        pendingReportTime = try? c.decodeIfPresent(Date.self, forKey: .pendingReportTime)
    }

    /// Fold in what the counter collected — only after a yes. Before the answer and after a no,
    /// nothing is kept: a report never carries what happened before the user agreed.
    mutating func absorb(features newFeatures: [String: Int], errors newErrors: [String: Int],
                         metrics newMetrics: [String: Int] = [:],
                         activeSeconds seconds: Int = 0, agentSeconds agents: Int = 0, day: String? = nil) {
        guard consent == true else { return }
        features.merge(newFeatures, uniquingKeysWith: +)
        metrics.merge(newMetrics, uniquingKeysWith: +)
        errors.merge(newErrors, uniquingKeysWith: +)
        activeSeconds += max(0, seconds)
        if seconds > 0, let day { activeDays.insert(day) }
        agentSeconds += max(0, agents)
    }

    /// Fold in crashes read from the system's reports. The same crash again — a crash at every
    /// launch, say — raises the count of the one entry instead of adding another, so it costs
    /// one exception in PostHog, not fifty. At most `Telemetry.maxCrashesKept` entries.
    mutating func add(crashes found: [CrashReport]) {
        guard consent == true else { return }
        for crash in found {
            if let index = crashes.firstIndex(where: { $0.signature == crash.signature }) {
                crashes[index].count += crash.count
            } else if crashes.count < Telemetry.maxCrashesKept {
                crashes.append(crash)
            }
        }
    }

    /// Note what is on screen now (`TelemetryPeak`); only a new high is kept.
    mutating func observe(_ peak: TelemetryPeak, _ value: Int) {
        guard consent == true, value > (peaks[peak.rawValue] ?? 0) else { return }
        peaks[peak.rawValue] = value
    }

    /// What one report carries: everything counted, and the first crashes up to the cap.
    var report: TelemetryRecord {
        var report = self
        report.crashes = Array(crashes.prefix(Telemetry.maxCrashesPerReport))
        return report
    }

    /// A report went out: take off what it carried. Subtracted, not cleared — the request
    /// takes a while, and what was counted meanwhile belongs to the next report.
    mutating func sent(_ report: TelemetryRecord, at date: Date, text: String) {
        features = Self.subtract(report.features, from: features)
        errors = Self.subtract(report.errors, from: errors)
        metrics = Self.subtract(report.metrics, from: metrics)
        // A high reached while the request was on its way belongs to the next report.
        peaks = peaks.filter { $0.value > (report.peaks[$0.key] ?? 0) }
        uncleanExits = max(0, uncleanExits - report.uncleanExits)
        activeSeconds = max(0, activeSeconds - report.activeSeconds)
        agentSeconds = max(0, agentSeconds - report.agentSeconds)
        // A day still running stays: what is used of it later counts it again in the next report.
        activeDays.subtract(report.activeDays)
        for crash in report.crashes {
            guard let index = crashes.firstIndex(where: { $0.signature == crash.signature }) else { continue }
            crashes[index].count -= crash.count
            if crashes[index].count <= 0 { crashes.remove(at: index) }
        }
        lastSent = date
        lastReport = text
        lastAttempt = date
        failedSends = 0
        pendingReportTime = nil
    }

    /// A request did not arrive: the counts stay, and the next try waits (`Telemetry.reportDue`).
    mutating func failed(at date: Date) {
        lastAttempt = date
        failedSends += 1
    }

    private static func subtract(_ sent: [String: Int], from counts: [String: Int]) -> [String: Int] {
        var left = counts
        for (key, value) in sent {
            let rest = (left[key] ?? 0) - value
            left[key] = rest > 0 ? rest : nil
        }
        return left
    }

    /// The user said no: forget what was collected.
    mutating func clearCollected() {
        features = [:]
        errors = [:]
        uncleanExits = 0
        crashes = []
        activeSeconds = 0
        agentSeconds = 0
        activeDays = []
        metrics = [:]
        peaks = [:]
        pendingReportTime = nil
    }
}

/// The counts collected between two flushes. Thread-safe: `Log.error` is called from the hook
/// server's threads and from detached tasks.
final class TelemetryCounter: @unchecked Sendable {
    static let shared = TelemetryCounter()

    private let lock = NSLock()
    private var features: [String: Int] = [:]
    private var errors: [String: Int] = [:]
    private var metrics: [String: Int] = [:]

    func add(metric: String) {
        lock.lock(); defer { lock.unlock() }
        metrics[metric, default: 0] += 1
    }

    func add(feature: String) {
        lock.lock(); defer { lock.unlock() }
        features[feature, default: 0] += 1
    }

    func add(error: String) {
        lock.lock(); defer { lock.unlock() }
        errors[error, default: 0] += 1
    }

    /// Hand over everything counted so far and start again.
    func drain() -> (features: [String: Int], errors: [String: Int], metrics: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        let result = (features, errors, metrics)
        features = [:]
        errors = [:]
        metrics = [:]
        return result
    }
}

/// A crash of Planchette, read from the report macOS writes to
/// `~/Library/Logs/DiagnosticReports`. Only what says *where* it crashed: the exception, the
/// signal, and the crashed thread's frames as binary + function name. Paths, the user name, the
/// machine's serial and the other threads stay in the file.
struct CrashReport: Codable, Equatable {
    /// The first crash of this signature; a crash that comes again only raises `count`.
    var time: Date
    var appVersion: String
    var exceptionType: String
    var signal: String?
    var frames: [String]
    /// How often this crash happened since the last report.
    var count = 1

    static let maxFrames = 30
    /// Frames that decide whether two crashes are the same one.
    static let signatureFrames = 5

    init(time: Date, appVersion: String, exceptionType: String, signal: String?, frames: [String], count: Int = 1) {
        self.time = time
        self.appVersion = appVersion
        self.exceptionType = exceptionType
        self.signal = signal
        self.frames = frames
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        exceptionType = try c.decode(String.self, forKey: .exceptionType)
        signal = try c.decodeIfPresent(String.self, forKey: .signal)
        frames = try c.decode([String].self, forKey: .frames)
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 1
    }

    /// Same version, same exception, same top frames of Planchette's own code (or of the
    /// thread, if none of it is Planchette's) = the same crash.
    var signature: String {
        let own = frames.filter { $0.hasPrefix("Planchette ") }
        let top = (own.isEmpty ? frames : own).prefix(Self.signatureFrames)
        return ([appVersion, exceptionType, signal ?? ""] + top).joined(separator: "|")
    }

    /// Parse a `.ips` file: a JSON header line, then the JSON report. Nil for anything that is
    /// not a real crash of Planchette — another app, a simulated fault, a hang report.
    static func parse(ips text: String, appName: String = "Planchette") -> CrashReport? {
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let headerText = text[..<newline]
        let bodyText = text[text.index(after: newline)...]
        guard let header = try? JSONSerialization.jsonObject(with: Data(headerText.utf8)) as? [String: Any],
              header["app_name"] as? String == appName,
              header["bug_type"] as? String == "309",
              (header["is_simulated"] as? Int ?? 0) == 0,
              let body = try? JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any],
              let exception = body["exception"] as? [String: Any],
              let type = exception["type"] as? String
        else { return nil }

        // Apple's libraries and Planchette's own code by name; any other library is "?" — the
        // name of a third-party tool loaded into the app says what else is installed.
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { image -> String in
            let name = image["name"] as? String ?? "?"
            let path = image["path"] as? String ?? ""
            let known = name == appName || path.contains("/\(appName).app/")
                || path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/")
            return known ? name : "?"
        }
        var frames: [String] = []
        if let threads = body["threads"] as? [[String: Any]] {
            let faulting = body["faultingThread"] as? Int
            let thread = faulting.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
                ?? threads.first { $0["triggered"] as? Bool == true }
            for frame in (thread?["frames"] as? [[String: Any]] ?? []).prefix(maxFrames) {
                let index = frame["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? images[index] : "?"
                if let symbol = frame["symbol"] as? String {
                    frames.append("\(image) \(symbol)")
                } else {
                    let offset = frame["imageOffset"] as? Int ?? 0
                    frames.append("\(image) +0x\(String(offset, radix: 16))")
                }
            }
        }
        return CrashReport(
            time: crashTime(header["timestamp"] as? String) ?? Date(),
            appVersion: header["app_version"] as? String ?? "?",
            exceptionType: type,
            signal: exception["signal"] as? String,
            frames: frames)
    }

    /// "2026-11-26 08:57:29.00 +0100"
    static func crashTime(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.date(from: text)
    }
}

/// The request body for PostHog's `/batch/` endpoint.
enum TelemetryPayload {
    struct Context {
        var apiKey: String
        var appVersion: String
        var osVersion: String
        var now: Date
    }

    /// One report: a `daily_snapshot` with the workspace, every feature count and every error
    /// count — one analytics event, however many errors there were — and one `$exception` per
    /// distinct crash (PostHog's error tracking groups those into issues). Never more than
    /// `Telemetry.maxEventsPerRequest` events. Every event has an id made from the install and
    /// the report's period, so a retry of a report that did arrive is the same event again.
    static func batch(_ record: TelemetryRecord, snapshot: TelemetrySnapshot, context: Context) -> [String: Any] {
        let id = record.installID.uuidString.lowercased()
        let stamp = iso(context.now)
        let period = record.lastSent.map(iso) ?? "first"
        // Anonymous events, no person profile; no location from the IP address.
        let base: [String: Any] = [
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$lib": "planchette-macos",
            "$lib_version": context.appVersion,
            "app_version": context.appVersion,
            "os_version": context.osVersion,
        ]

        var snapshotProperties = base.merging(snapshot.properties) { a, _ in a }
        for feature in TelemetryFeature.allCases {
            snapshotProperties["f_\(feature.rawValue)"] = record.features[feature.rawValue] ?? 0
        }
        for metric in TelemetryMetric.allCases {
            snapshotProperties[metric.rawValue] = record.metrics[metric.rawValue] ?? 0
        }
        for peak in TelemetryPeak.allCases {
            snapshotProperties[peak.rawValue] = record.peaks[peak.rawValue] ?? 0
        }
        snapshotProperties["install_age_days"] = max(0, Int(context.now.timeIntervalSince(record.firstSeen) / 86400))
        for (key, count) in record.errors {
            let name = errorProperty(key)
            snapshotProperties[name] = (snapshotProperties[name] as? Int ?? 0) + count
        }
        snapshotProperties["unclean_exits"] = record.uncleanExits
        snapshotProperties["crashes"] = record.crashes.reduce(0) { $0 + $1.count }
        snapshotProperties["errors"] = record.errors.values.reduce(0, +)
        snapshotProperties["active_minutes"] = record.activeSeconds / 60
        snapshotProperties["agent_minutes"] = record.agentSeconds / 60
        snapshotProperties["active_days"] = record.activeDays.count
        if let last = record.lastSent {
            snapshotProperties["hours_since_last_report"] = Int(context.now.timeIntervalSince(last) / 3600)
        }

        var events: [[String: Any]] = [[
            "event": "daily_snapshot", "distinct_id": id, "timestamp": stamp,
            "uuid": eventID(id, period, "daily_snapshot"),
            "properties": snapshotProperties,
        ]]
        for crash in record.crashes.prefix(Telemetry.maxCrashesPerReport) {
            let frames: [[String: Any]] = crash.frames.map { frame in
                let module = String(frame.prefix { $0 != " " })
                return [
                    "platform": "custom", "lang": "swift",
                    "function": String(frame.dropFirst(module.count + 1)),
                    "module": module, "resolved": true, "in_app": module == "Planchette",
                ]
            }
            let exception: [String: Any] = [
                "type": crash.exceptionType,
                "value": crash.signal ?? crash.exceptionType,
                "mechanism": ["handled": false, "synthetic": false],
                "stacktrace": ["type": "raw", "frames": frames],
            ]
            var properties = base
            properties["app_version"] = crash.appVersion
            properties["count"] = crash.count
            properties["$exception_list"] = [exception]
            events.append([
                "event": "$exception", "distinct_id": id, "timestamp": iso(crash.time),
                "uuid": eventID(id, period, "$exception", crash.signature),
                "properties": properties,
            ])
        }
        return ["api_key": context.apiKey, "batch": Array(events.prefix(Telemetry.maxEventsPerRequest))]
    }

    /// The snapshot column of an error key: "hook-server.bind_failed" → "e_hook_server_bind_failed".
    /// Letters, digits and `_` only, so a column reads as `properties.e_…` in PostHog's SQL.
    static func errorProperty(_ key: String) -> String {
        let cleaned = key.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "_"
        }
        return "e_" + String(cleaned)
    }

    /// A UUID made from its parts, the same every time: PostHog keeps one copy of events
    /// that share an id, event name, distinct id and day.
    static func eventID(_ parts: String...) -> String {
        var bytes = Array(SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80   // version 8: custom
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }

    /// "2026-11-26", in the Mac's own calendar: the day a person would say they used the app.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Pretty JSON for the "last report" view in Settings, with the key left out.
    static func readable(_ body: [String: Any]) -> String {
        var shown = body
        shown["api_key"] = nil
        guard let data = try? JSONSerialization.data(withJSONObject: shown, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

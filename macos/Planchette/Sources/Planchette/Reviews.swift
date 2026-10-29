import AppKit
import SwiftUI
import Foundation

/// The Reviews mode of the notifications panel: polling GitHub for review
/// requests, starting a `review-pr` run in a free checkout or a temporary
/// worktree, and carrying the user's decisions back to it.
///
/// The rules live in `ReviewRequests` (pure, tested); this is the part that
/// touches terminals, files and the network. The state it works on is declared
/// with the rest of `AppState`'s state.
extension AppState {
    // MARK: Poll

    func startReviewPolling() {
        applyLaunchReviewFocus()
        // An isolated instance (a demo, a screenshot, a test) shows its seeded
        // reviews and asks GitHub for nothing. It still watches the review files.
        startReviewFileWatch()
        guard !SupportPaths.isIsolated else { return }
        let timer = Timer(timeInterval: ReviewRequests.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshReviews() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        reviewTimer = timer
        // The first answer should not wait five minutes; a few seconds keep it
        // out of the launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.refreshReviews() }
        }
    }

    private func startReviewFileWatch() {
        let watch = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkReviewFiles() }
        }
        watch.tolerance = 1
        RunLoop.main.add(watch, forMode: .common)
        reviewWatchTimer = watch
    }

    /// `-reviewFocus <url>` at launch opens that row, as a banner click does —
    /// how `scripts/perf/screenshots.py` pictures an open row.
    func applyLaunchReviewFocus() {
        if let url = UserDefaults.standard.string(forKey: "reviewFocus"), reviews[url] != nil {
            reviewFocus = url
        }
    }

    /// Ask GitHub now. `manual` is the panel's refresh button: it may not repeat
    /// faster than `ReviewRequests.minimumManualInterval`.
    func refreshReviews(manual: Bool = false) {
        guard !SupportPaths.isIsolated else { return }
        if manual {
            let now = Date()
            if let last = reviewLastManualRefresh,
               now.timeIntervalSince(last) < ReviewRequests.minimumManualInterval { return }
            reviewLastManualRefresh = now
        }
        guard reviewFlight.begin() else { return }
        let tracked = ReviewRequests.trackedURLs(reviews)
        // The first answer of a run fills the list; only later ones are news.
        let announce = reviewsCheckedAt != nil
        Task.detached {
            let fetch = ReviewRequests.fetch(tracked: tracked)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let fetch {
                    self.apply(fetch, announce: announce)
                } else if self.reviewsCheckedAt == nil {
                    // Never answered: no `gh`, no login. A later failure is a
                    // network hiccup and keeps what the panel shows.
                    self.reviewsReachable = false
                }
                if self.reviewFlight.end() { self.refreshReviews() }
            }
        }
    }

    private func apply(_ fetch: ReviewRequests.Fetch, announce: Bool) {
        let now = Date()
        let before = reviews
        let after = ReviewRequests.merge(before, with: fetch, now: now)
        reviewsCheckedAt = now
        reviewsReachable = true
        guard after != before else { return }
        reviews = after
        for url in Set(before.keys).subtracting(after.keys) {
            reviewFindings[url] = nil
            reviewCheckouts[url] = nil
        }
        scheduleSave()
        guard announce else { return }
        let requestedNow = Set(fetch.requested.map(\.url))
        for (url, record) in after where isMine(record) && !record.isSnoozed(at: now) {
            let old = before[url]
            let isNew = old == nil
            let askedAgain = old?.stage == .sent && record.stage == .requested && requestedNow.contains(url)
            guard isNew || askedAgain else { continue }
            NotificationService.post(
                title: L10n.t(.reviewBannerRequested),
                body: "\(record.pr.title)\n\(record.pr.author) · \(record.pr.repoName) #\(record.pr.number)",
                reviewURL: url)
        }
    }

    // MARK: What the panel shows

    /// A row is the user's when they were asked by name, or once they worked on
    /// it: a team request only becomes theirs by starting its review.
    func isMine(_ record: ReviewRecord) -> Bool {
        record.pr.requestedFromMe || ReviewRequests.isTracked(record)
    }

    struct ReviewSections {
        var needsYou: [ReviewRecord] = []
        var reviewing: [ReviewRecord] = []
        var sent: [ReviewRecord] = []
        var isEmpty: Bool { needsYou.isEmpty && reviewing.isEmpty && sent.isEmpty }
    }

    /// The three sections, in the order the eye wants them: a result waiting
    /// before a fresh request, the oldest of each first, so nothing ages at the
    /// bottom. The control API answers from this list too.
    func reviewSections(onlyMine: Bool, showSent: Bool) -> ReviewSections {
        var sections = ReviewSections()
        let rows = reviews.values.filter { !onlyMine || isMine($0) }
        sections.needsYou = rows.filter { $0.stage.needsYou }.sorted { a, b in
            if a.stage != b.stage { return a.stage == .findings }
            return a.since < b.since
        }
        sections.reviewing = rows.filter { $0.stage == .reviewing }.sorted { $0.since < $1.since }
        if showSent {
            sections.sent = rows.filter { $0.stage == .sent }.sorted { $0.since > $1.since }
        }
        return sections
    }

    /// What the blue dot on the toolbar icon counts: rows in "Needs you" that
    /// are the user's, not looked at, and not snoozed.
    var unseenReviewCount: Int {
        let now = Date()
        return reviews.values.filter {
            $0.unread && $0.stage.needsYou && isMine($0) && !$0.isSnoozed(at: now)
        }.count
    }

    func reviewDirectory(for record: ReviewRecord) -> URL {
        ReviewRequests.reviewDirectory(for: record.pr, base: SupportPaths.dir)
    }

    /// The decision that counts for a finding of this review.
    func reviewDecision(_ finding: ReviewFindings.Finding, of url: String) -> ReviewDecision {
        ReviewFindings.decision(for: finding, in: reviews[url]?.decisions ?? [:])
    }

    /// The verdict the review will be sent with: the user's pick, else the one
    /// the decisions imply.
    func reviewVerdict(of url: String) -> ReviewVerdict {
        if let chosen = reviews[url]?.verdict { return chosen }
        guard let findings = reviewFindings[url] else { return .comment }
        return ReviewFindings.verdict(for: findings.findings, decisions: reviews[url]?.decisions ?? [:])
    }

    // MARK: Row actions

    private func updateReview(_ url: String, _ mutate: (inout ReviewRecord) -> Void) {
        guard var record = reviews[url] else { return }
        mutate(&record)
        guard record != reviews[url] else { return }
        reviews[url] = record
        scheduleSave()
    }

    func markReviewSeen(_ url: String) { updateReview(url) { $0.unread = false } }
    func markReviewUnread(_ url: String) { updateReview(url) { $0.unread = true } }

    func snoozeReview(_ url: String, until: Date) {
        updateReview(url) { $0.snoozedUntil = until; $0.unread = false }
    }

    func clearReviewSnooze(_ url: String) { updateReview(url) { $0.snoozedUntil = nil } }

    func openReviewOnGitHub(_ url: String) {
        guard let link = URL(string: url), link.scheme == "https" else { return }
        NSWorkspace.shared.open(link)
    }

    /// A banner was clicked: show the panel in its Reviews mode with that row open.
    func focusReview(_ url: String) {
        UserDefaults.standard.set(true, forKey: "inboxShown")
        UserDefaults.standard.set(InboxMode.reviews.rawValue, forKey: InboxMode.storageKey)
        reviewFocus = url
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Jump to the terminal a review runs in.
    func showReviewTerminal(_ url: String) {
        guard let id = reviews[url]?.sessionID, sessions[id] != nil else { return }
        focusSession(id)
    }

    // MARK: Decisions

    func setReviewDecision(_ url: String, finding id: String, to decision: ReviewDecision) {
        updateReview(url) {
            $0.decisions[id] = decision
            // A verdict picked by hand belonged to the old decisions.
            $0.verdict = nil
        }
    }

    func setAllReviewDecisions(_ url: String, to decision: ReviewDecision) {
        guard let findings = reviewFindings[url] else { return }
        updateReview(url) {
            for finding in findings.findings { $0.decisions[finding.id] = decision }
            $0.verdict = nil
        }
    }

    func resetReviewDecisions(_ url: String) {
        updateReview(url) {
            $0.decisions = [:]
            $0.verdict = nil
        }
    }

    func setReviewVerdict(_ url: String, to verdict: ReviewVerdict) {
        updateReview(url) { $0.verdict = verdict }
    }

    // MARK: Checkouts

    /// Gather where this PR's review could run: every checkout of its repo that
    /// a project in Planchette holds, plus that repo's worktrees, with the
    /// reasons each one is busy. Git runs off-main; the facts about terminals
    /// are read here, on main, where they live.
    func loadReviewCheckouts(for url: String) {
        guard let record = reviews[url] else { return }
        let slug = record.pr.repo.lowercased()
        let terminals = sessions.values.map { session in
            ReviewRequests.TerminalFact(
                path: session.currentDirectory,
                turnState: turnState(of: session.id) ?? session.state,
                backgroundWork: !(backgroundTasks[session.id] ?? []).isEmpty,
                agentLive: isAgentLive(session.id),
                unreadResult: session.isUnread)
        }
        let directories = Set(sessions.values.map(\.currentDirectory).filter { !$0.isEmpty }
            + groups.compactMap(\.worktreePath))
        let servers = devServers.values.flatMap { $0 }.map { (directory: $0.directory, port: $0.port) }
        let running = reviews.values.compactMap { other -> (String, Int)? in
            guard other.stage == .reviewing, let checkout = other.checkout else { return nil }
            return (checkout, other.pr.number)
        }
        Task.detached {
            let found = Self.scanCheckouts(
                repo: slug, directories: directories, terminals: terminals,
                servers: servers, running: running)
            await MainActor.run { [weak self] in
                guard let self, self.reviews[url] != nil else { return }
                if self.reviewCheckouts[url] != found { self.reviewCheckouts[url] = found }
            }
        }
    }

    /// Off-main: find the repo's checkouts and read each one with git.
    nonisolated private static func scanCheckouts(
        repo slug: String, directories: Set<String>, terminals: [ReviewRequests.TerminalFact],
        servers: [(directory: String, port: Int)], running: [(String, Int)]
    ) -> [ReviewRequests.Checkout] {
        var roots: Set<String> = []
        for directory in directories {
            if let root = Worktrees.repoRoot(of: directory) { roots.insert(root) }
        }
        // A worktree's toplevel is the worktree; its main checkout is the first
        // entry of `git worktree list`. Each checkout once, with the main one it
        // belongs to.
        var checkouts: [String: String] = [:]   // checkout → main checkout
        for root in roots {
            guard let remote = try? Worktrees.git(["remote", "get-url", "origin"], in: root),
                  ReviewRequests.repoSlug(fromRemote: remote) == slug else { continue }
            let all = Worktrees.list(repoRoot: root)
            let main = all.first ?? root
            for path in all where FileManager.default.fileExists(atPath: path) {
                checkouts[path] = main
            }
            if checkouts[root] == nil { checkouts[root] = main }
        }
        let found = checkouts.map { path, main -> ReviewRequests.Checkout in
            let status = (try? Worktrees.git(["status", "--porcelain"], in: path)) ?? ""
            let uncommitted = status.split(separator: "\n").count
            let branch = Worktrees.currentBranch(of: path)
            var merged = branch == nil || ["master", "main", "develop", "trunk"].contains(branch ?? "")
            if !merged,
               let base = (try? Worktrees.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: path))?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                merged = (try? Worktrees.git(["merge-base", "--is-ancestor", "HEAD", base], in: path)) != nil
            }
            let stamp = (try? Worktrees.git(["log", "-g", "-1", "--format=%ct", "HEAD"], in: path))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let last = stamp.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            let busy = ReviewRequests.busyReasons(
                checkout: path, terminals: terminals, uncommitted: uncommitted,
                devServerPorts: servers.filter { ReviewRequests.isInside($0.directory, path) }.map(\.port),
                reviewsRunningHere: running.filter { ReviewRequests.isInside($0.0, path) }.map(\.1),
                onTrunkOrMerged: merged)
            return ReviewRequests.Checkout(
                path: path, repoRoot: main, branch: branch, trunkOrMerged: merged,
                lastActivity: last, busy: busy)
        }
        return ReviewRequests.rank(found)
    }

    // MARK: Start

    /// Start the review: a new terminal in the chosen checkout — or in a new
    /// temporary worktree when `checkout` is nil — that runs the `review-pr`
    /// skill. The terminal opens in the background: the row says where it runs,
    /// and a click on the row goes there.
    func startReview(_ url: String, in checkout: ReviewRequests.Checkout?, repoRoot: String?, runChecks: Bool) {
        guard let record = reviews[url], record.stage == .requested else { return }
        let directory = reviewDirectory(for: record)
        // A new round starts clean: the files of an earlier one would read as its answers.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["findings.json", "decisions.json", "sent.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        reviewFindings[url] = nil
        reviewNotice = nil

        if let checkout {
            let session = openReviewTerminal(in: checkout.path, groupID: projectHolding(checkout.path))
            launch(record.pr, in: session, directory: directory, keepCheckout: false, runChecks: runChecks)
            updateReview(url) {
                $0.stage = .reviewing
                $0.since = Date()
                $0.unread = false
                $0.updated = false
                $0.checkout = checkout.path
                $0.temporary = false
                $0.repoRoot = checkout.repoRoot
                $0.sessionID = session.id
                $0.groupID = nil
                $0.lastError = nil
            }
            return
        }

        guard let repoRoot else { return }
        let pr = record.pr
        // Shown as reviewing at once: making the worktree takes a moment, and a
        // second click must not start a second review.
        updateReview(url) {
            $0.stage = .reviewing
            $0.since = Date()
            $0.unread = false
            $0.updated = false
            $0.temporary = true
            $0.repoRoot = repoRoot
            $0.lastError = nil
        }
        Task { [weak self] in
            let result: Result<String, Error> = await Task.detached {
                do {
                    return .success(try Worktrees.createDetached(
                        repoRoot: repoRoot, name: ReviewRequests.worktreeName(for: pr)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let path):
                let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
                let group = self.addGroup(name: "\(repoName) · #\(pr.number)", select: false)
                self.updateGroup(group.id) {
                    $0.worktreePath = path
                    $0.worktreeRepoRoot = repoRoot
                }
                let session = self.openReviewTerminal(in: path, groupID: group.id)
                self.launch(pr, in: session, directory: directory, keepCheckout: true, runChecks: runChecks)
                self.updateReview(url) {
                    $0.checkout = path
                    $0.sessionID = session.id
                    $0.groupID = group.id
                }
            case .failure(let error):
                self.updateReview(url) {
                    $0.stage = .requested
                    $0.temporary = false
                    $0.lastError = error.localizedDescription
                }
            }
        }
    }

    /// The project a review terminal joins: the one that already has a terminal
    /// in this checkout, so a review in `4th-designer-library` sits with it.
    private func projectHolding(_ path: String) -> UUID? {
        sessions.values.first { ReviewRequests.isInside($0.currentDirectory, path) }?.groupID
    }

    private func openReviewTerminal(in path: String, groupID: UUID?) -> TerminalSession {
        let group = groupID ?? addGroup(name: (path as NSString).lastPathComponent, select: false).id
        return addSession(directory: path, groupID: group, activate: false)
    }

    /// Type the command that starts Claude with the skill. The PTY keeps what
    /// is typed until the shell reads it, so a terminal that is still starting
    /// gets it at its first prompt (as `openTerminalTyping` relies on).
    private func launch(_ pr: ReviewPR, in session: TerminalSession, directory: URL,
                        keepCheckout: Bool, runChecks: Bool) {
        let command = ReviewRequests.startCommand(
            pr: pr, directory: directory.path, keepCheckout: keepCheckout, runChecks: runChecks)
        Task { @MainActor in
            // The skill has to be in place before Claude starts and reads its skills: the user's
            // own, or Planchette's default (`ReviewSkill`).
            let skill = await Task.detached { ReviewSkill.ensureInstalled() }.value
            if skill == .install { self.reviewNotice = L10n.t(.reviewSkillInstalled) }
            guard let view = ControlAPI.liveView(for: session, state: self) else { return }
            await ControlAPI.deliverPrompt(command, submit: true, to: view, session: session.id)
        }
    }

    // MARK: Send

    /// "Send review": write the decisions where the skill reads them, and ask the
    /// review terminal to post. Nothing reaches GitHub before this.
    func sendReview(_ url: String) {
        guard let record = reviews[url], record.stage == .findings, !record.sending,
              let findings = reviewFindings[url] else { return }
        let directory = reviewDirectory(for: record)
        let file = ReviewDecisionsFile(
            verdict: reviewVerdict(of: url),
            decisions: Dictionary(uniqueKeysWithValues: findings.findings.map {
                ($0.id, ReviewFindings.decision(for: $0, in: record.decisions))
            }))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("sent.json"))
            try encoder.encode(file).write(to: directory.appendingPathComponent("decisions.json"), options: .atomic)
        } catch {
            updateReview(url) { $0.lastError = error.localizedDescription }
            return
        }
        let prompt = ReviewRequests.submitPrompt(directory: directory.path)
        if let id = record.sessionID, let session = sessions[id] {
            Task { @MainActor in
                guard let view = ControlAPI.liveView(for: session, state: self) else { return }
                await ControlAPI.deliverPrompt(prompt, submit: true, to: view, session: id)
            }
        } else {
            // The review terminal is gone (closed, or a fresh start): a new one in
            // the checkout, if it is still there, takes over.
            let path = record.checkout.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            let session = openReviewTerminal(in: path, groupID: record.groupID ?? projectHolding(path))
            let command = "claude \(Shell.singleQuoted(prompt))"
            Task { @MainActor in
                guard let view = ControlAPI.liveView(for: session, state: self) else { return }
                await ControlAPI.deliverPrompt(command, submit: true, to: view, session: session.id)
            }
            updateReview(url) { $0.sessionID = session.id }
        }
        updateReview(url) {
            $0.sending = true
            $0.verdict = file.verdict
            $0.lastError = nil
        }
    }

    // MARK: Watch the review files

    /// Every two seconds, and only file lookups: has a running review written
    /// its findings, has a sent one written `sent.json`, is a temporary worktree
    /// ready to go.
    func checkReviewFiles() {
        guard !reviews.isEmpty else { return }
        let now = Date()
        for (url, record) in reviews {
            let directory = reviewDirectory(for: record)
            switch record.stage {
            case .requested:
                continue
            case .reviewing:
                if let findings = ReviewFindings.load(from: directory) {
                    reviewFindings[url] = findings
                    updateReview(url) {
                        $0.stage = .findings
                        $0.since = now
                        $0.unread = true
                    }
                    if NSApp?.isActive != true {
                        NotificationService.post(
                            title: L10n.t(.reviewBannerFindings),
                            body: "\(record.pr.title)\n\(L10n.t(.reviewFindingsCount, findings.findings.count))",
                            reviewURL: url)
                    }
                } else if let id = record.sessionID, sessions[id] == nil {
                    // The terminal closed before the findings came: back to the start.
                    updateReview(url) {
                        $0.stage = .requested
                        $0.since = now
                        $0.sessionID = nil
                        $0.lastError = L10n.t(.reviewTerminalClosed)
                    }
                }
            case .findings:
                if reviewFindings[url] == nil {
                    reviewFindings[url] = ReviewFindings.load(from: directory)
                }
                guard record.sending, let sent = ReviewSent.load(from: directory) else { continue }
                let reviewed = reviewFindings[url]?.pr.headSha ?? record.pr.headSha
                updateReview(url) {
                    $0.stage = .sent
                    $0.since = now
                    $0.unread = false
                    $0.sending = false
                    $0.verdict = sent.verdict ?? $0.verdict
                    $0.reviewedSha = reviewed
                    $0.lastError = sent.errors?.first
                }
                reviewNotice = L10n.t(.reviewSentNotice, record.pr.author)
            case .sent:
                cleanUpTemporaryCheckout(url)
            }
        }
    }

    /// A temporary worktree goes once its review is on GitHub and the terminal
    /// in it has finished its turn — closing it earlier would end Claude mid-line.
    private func cleanUpTemporaryCheckout(_ url: String) {
        guard let record = reviews[url], record.temporary, let groupID = record.groupID else { return }
        if let id = record.sessionID, sessions[id] != nil, turnState(of: id) == .running { return }
        if groups.contains(where: { $0.id == groupID }) {
            closeGroup(groupID, worktree: .remove(deletingBranch: "review/pr-\(record.pr.number)"))
        }
        updateReview(url) {
            $0.groupID = nil
            $0.sessionID = nil
            $0.checkout = nil
            $0.temporary = false
        }
    }
}

/// Which content the right panel shows. Both toolbar icons switch it; the one
/// whose mode is shown looks selected.
enum InboxMode: String {
    case notifications, reviews
    static let storageKey = "inboxMode"
}

extension InboxMode {
    /// On while the panel shows this mode. Turning it on shows the panel in this
    /// mode; turning it off — a click on the icon that is already pressed —
    /// hides the panel, as the bell always did.
    static func binding(_ mine: InboxMode, shown: Binding<Bool>, mode: Binding<InboxMode>) -> Binding<Bool> {
        Binding(
            get: { shown.wrappedValue && mode.wrappedValue == mine },
            set: { on in
                if on {
                    mode.wrappedValue = mine
                    shown.wrappedValue = true
                } else {
                    shown.wrappedValue = false
                }
            })
    }
}

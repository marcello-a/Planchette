import SwiftUI

/// The Reviews mode of the right panel: the pull requests that wait for the
/// user's review, by stage. It keeps the notifications panel's header, rows and
/// spacing — only the content differs. A row opens in place: the checkout
/// picker for a request, the findings for a finished review. Nothing covers the
/// terminal, and nothing reaches GitHub before "Send review".
struct ReviewsPanel: View {
    @EnvironmentObject var appState: AppState
    /// On by default: a team request is for the team, and a list of them buries
    /// the ones meant for you.
    @AppStorage("reviewsOnlyMine") private var onlyMine = true
    @AppStorage("reviewsShowSent") private var showSent = true
    @State private var expanded: String?
    /// The checkout picked per PR: a path, or `temporaryChoice`.
    @State private var choice: [String: String] = [:]
    @State private var runChecks: [String: Bool] = [:]

    private static let temporaryChoice = "\u{0}temporary"

    var body: some View {
        let sections = appState.reviewSections(onlyMine: onlyMine, showSent: showSent)
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = appState.reviewNotice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(notice).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { appState.reviewNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help(L10n.t(.close))
                }
                .font(.caption)
                .foregroundStyle(AttentionState.ready.tint)
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            if !appState.reviewsReachable {
                placeholder("exclamationmark.triangle", L10n.t(.reviewsNoGh))
            } else if sections.isEmpty {
                placeholder("checkmark.seal", L10n.t(.reviewsEmpty))
            } else {
                ScrollView {
                    // Not lazy: the list is short, and a lazy stack kept a row that moved to
                    // another section out of the accessibility tree.
                    VStack(spacing: 0) {
                        section(.reviewsNeedsYou, sections.needsYou)
                        section(.reviewsReviewing, sections.reviewing)
                        section(.reviewsSent, sections.sent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { openFocused() }
        .onChange(of: appState.reviewFocus) { _, _ in openFocused() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L10n.t(.reviewsPanel)).font(.headline)
                let unseen = appState.unseenReviewCount
                if unseen > 0 {
                    Text("\(unseen)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button {
                    appState.refreshReviews(manual: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t(.reviewsRefresh))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { filters; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 4) { filters }
            }
            if let checked = appState.reviewsCheckedAt {
                Text(L10n.t(.reviewsCheckedAt, checked.formatted(date: .omitted, time: .shortened)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var filters: some View {
        Toggle(L10n.t(.reviewsOnlyMine), isOn: $onlyMine)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(L10n.t(.reviewsOnlyMineHelp))
        Toggle(L10n.t(.reviewsShowSent), isOn: $showSent)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(L10n.t(.reviewsShowSentHelp))
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(text).font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ title: LKey, _ rows: [ReviewRecord]) -> some View {
        if !rows.isEmpty {
            HStack(spacing: 6) {
                Text(L10n.t(title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // The same count badges the project headers carry, per stage.
                let byStage = Dictionary(grouping: rows, by: \.stage)
                ForEach([ReviewStage.findings, .requested, .reviewing], id: \.self) { stage in
                    if let count = byStage[stage]?.count, count > 0 {
                        StateCountBadge(state: stage.state, count: count)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
            ForEach(rows) { record in
                row(record)
                if expanded == record.id {
                    drawer(record)
                }
            }
            Divider()
        }
    }

    // MARK: Row

    private func row(_ record: ReviewRecord) -> some View {
        let state = record.stage.state
        return Button {
            tap(record)
        } label: {
            PanelRow(
                unread: record.unread, tint: state.tint,
                // A PR title reads from its start: the ticket, then the words.
                title: record.pr.title, truncation: .tail,
                detail: meta(record)
            ) {
                StateIcon(state: state, size: 14)
            } chip: {
                ReviewChip(text: chipText(record), tint: state.tint)
            } trailing: {
                if let until = record.snoozedUntil, until > Date() {
                    SnoozeBadge(until: until)
                } else {
                    WaitingTimeText(since: record.since)
                }
            }
        }
        .buttonStyle(.plain)
        // A row is one element with a name: the PR, then its stage. Without this
        // the button had no label at all, for VoiceOver and for the perf scripts.
        .accessibilityLabel(Text(verbatim: record.pr.title))
        .accessibilityValue(Text(verbatim: chipText(record)))
        .help(hoverDetail(record))
        .contextMenu { rowMenu(record) }
    }

    private func tap(_ record: ReviewRecord) {
        switch record.stage {
        case .reviewing:
            appState.showReviewTerminal(record.id)
        case .sent:
            appState.openReviewOnGitHub(record.id)
        case .requested, .findings:
            appState.markReviewSeen(record.id)
            toggle(record.id)
        }
    }

    private func toggle(_ url: String) {
        if expanded == url {
            expanded = nil
        } else {
            expanded = url
            if reviews(url)?.stage == .requested { appState.loadReviewCheckouts(for: url) }
        }
    }

    private func openFocused() {
        guard let url = appState.reviewFocus else { return }
        appState.reviewFocus = nil
        appState.markReviewSeen(url)
        if expanded != url { toggle(url) }
    }

    private func reviews(_ url: String) -> ReviewRecord? { appState.reviews[url] }

    /// The second line: where the PR is and how big, or where its review runs.
    private func meta(_ record: ReviewRecord) -> Text {
        let pr = record.pr
        // Verbatim throughout: a localized Text formats numbers, and #5612 became #5.612.
        var text: Text
        switch record.stage {
        case .requested:
            text = Text(verbatim: "\(pr.repoName) #\(pr.number) · \(pr.author) · ")
                + Text(verbatim: "+\(pr.additions)").foregroundColor(AttentionState.ready.tint)
                + Text(verbatim: " ")
                + Text(verbatim: "−\(pr.deletions)").foregroundColor(AttentionState.error.tint)
        case .reviewing:
            text = Text(verbatim: "#\(pr.number) · " + L10n.t(.reviewMetaIn, checkoutName(record)))
        case .findings:
            text = Text(verbatim: "#\(pr.number) · " + L10n.t(.reviewMetaReviewedIn, checkoutName(record)))
        case .sent:
            text = Text(verbatim: "#\(pr.number) · " + L10n.t(.reviewMetaWaitingFor, pr.author))
        }
        if !pr.requestedFromMe, let team = pr.team {
            text = text + Text(verbatim: " · " + L10n.t(.reviewMetaTeam, team))
        }
        return text
    }

    private func checkoutName(_ record: ReviewRecord) -> String {
        if record.temporary { return L10n.t(.reviewMetaTemporary) }
        return record.checkout.map { ($0 as NSString).lastPathComponent } ?? "—"
    }

    private func chipText(_ record: ReviewRecord) -> String {
        switch record.stage {
        case .requested:
            return L10n.t(record.updated ? .reviewChipUpdated : .reviewChipRequested)
        case .reviewing:
            return L10n.t(.reviewChipReviewing)
        case .findings:
            if record.sending { return L10n.t(.reviewChipSending) }
            let count = appState.reviewFindings[record.id]?.findings.count ?? 0
            switch count {
            case 0: return L10n.t(.reviewChipNoFindings)
            case 1: return L10n.t(.reviewFindingOne)
            default: return L10n.t(.reviewFindingsCount, count)
            }
        case .sent:
            switch record.verdict {
            case .approve: return L10n.t(.reviewChipApproved)
            case .requestChanges: return L10n.t(.reviewChipChangesRequested)
            case .comment, nil: return L10n.t(.reviewChipCommented)
            }
        }
    }

    /// The whole story on hover: the rows clip it to two lines.
    private func hoverDetail(_ record: ReviewRecord) -> String {
        let pr = record.pr
        var lines = [pr.title, "\(pr.repo) #\(pr.number) · \(pr.author)"]
        lines.append(L10n.t(.reviewChangedFiles, pr.changedFiles, pr.additions, pr.deletions))
        switch pr.checks {
        case .passed: lines.append(L10n.t(.reviewChecksPassed))
        case .failed: lines.append(L10n.t(.reviewChecksFailed))
        case .pending: lines.append(L10n.t(.reviewChecksPending))
        case .none: break
        }
        if pr.isDraft { lines.append(L10n.t(.reviewDraft)) }
        lines.append(pr.requestedFromMe ? L10n.t(.reviewRequestedFromYou)
            : L10n.t(.reviewRequestedFromTeam, pr.team ?? "—"))
        if let error = record.lastError { lines.append("⚠︎ \(error)") }
        switch record.stage {
        case .requested: lines.append(L10n.t(.reviewHelpRequested))
        case .reviewing: lines.append(L10n.t(.reviewHelpReviewing))
        case .findings: lines.append(L10n.t(.reviewHelpFindings))
        case .sent: lines.append(L10n.t(.reviewHelpSent))
        }
        return lines.joined(separator: "\n\n")
    }

    @ViewBuilder
    private func rowMenu(_ record: ReviewRecord) -> some View {
        if record.unread {
            Button(L10n.t(.markRead)) { appState.markReviewSeen(record.id) }
        } else if record.stage.needsYou {
            Button(L10n.t(.markUnread)) { appState.markReviewUnread(record.id) }
        }
        laterMenu(record)
        Divider()
        Button(L10n.t(.reviewOpenOnGitHub)) { appState.openReviewOnGitHub(record.id) }
    }

    @ViewBuilder
    private func laterMenu(_ record: ReviewRecord) -> some View {
        Menu(L10n.t(.reviewLater)) {
            ForEach(SnoozeOption.allCases) { option in
                Button(L10n.t(option.labelKey)) {
                    appState.snoozeReview(record.id, until: option.date(from: Date()))
                    if expanded == record.id { expanded = nil }
                }
            }
            if record.snoozedUntil != nil {
                Divider()
                Button(L10n.t(.remindCancel)) { appState.clearReviewSnooze(record.id) }
            }
        }
    }

    // MARK: Drawers

    @ViewBuilder
    private func drawer(_ record: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = record.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch record.stage {
            case .requested: checkoutPicker(record)
            case .findings: findingsList(record)
            case .reviewing, .sent: EmptyView()
            }
        }
        .padding(.leading, 41)
        .padding(.trailing, 12)
        .padding(.bottom, 9)
    }

    // MARK: Checkout picker

    @ViewBuilder
    private func checkoutPicker(_ record: ReviewRecord) -> some View {
        let url = record.id
        Text(L10n.t(.reviewIn))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
        if let checkouts = appState.reviewCheckouts[url] {
            let free = checkouts.filter(\.isFree)
            let busy = checkouts.filter { !$0.isFree }
            let repoRoot = checkouts.first?.repoRoot
            let selected = choice[url] ?? free.first?.path ?? (repoRoot == nil ? nil : Self.temporaryChoice)
            if checkouts.isEmpty {
                Text(L10n.t(.reviewNoCheckout, record.pr.repo))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(free) { checkout in
                    radio(title: checkout.name, detail: freeDetail(checkout),
                          recommended: checkout == free.first, on: selected == checkout.path) {
                        choice[url] = checkout.path
                    }
                }
                if repoRoot != nil {
                    radio(title: L10n.t(.reviewTemporaryWorktree), detail: L10n.t(.reviewTemporaryWorktreeHelp),
                          recommended: free.isEmpty, on: selected == Self.temporaryChoice) {
                        choice[url] = Self.temporaryChoice
                    }
                }
                if !busy.isEmpty {
                    DisclosureGroup(busy.count == 1 ? L10n.t(.reviewBusyCountOne) : L10n.t(.reviewBusyCount, busy.count)) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(busy) { checkout in
                                radio(title: checkout.name, detail: busyDetail(checkout),
                                      recommended: false, on: false, enabled: false) {}
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Toggle(L10n.t(.reviewRunChecks), isOn: Binding(
                get: { runChecks[url] ?? false }, set: { runChecks[url] = $0 }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(L10n.t(.reviewRunChecksHelp))
            HStack(spacing: 8) {
                Button(L10n.t(.reviewStart)) {
                    let checkout = free.first { $0.path == selected }
                    appState.startReview(url, in: checkout, repoRoot: repoRoot, runChecks: runChecks[url] ?? false)
                    expanded = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selected == nil)
                laterMenu(record)
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                Spacer(minLength: 0)
                gitHubButton(url)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func radio(title: String, detail: String, recommended: Bool, on: Bool,
                       enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        if recommended {
                            Text(L10n.t(.reviewSuggested))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func freeDetail(_ checkout: ReviewRequests.Checkout) -> String {
        var parts = [L10n.t(.reviewFreeClean, checkout.branch ?? L10n.t(.reviewDetached))]
        if let last = checkout.lastActivity {
            Self.relative.locale = Locale(identifier: L10n.current.resolved.rawValue)
            parts.append(L10n.t(.reviewLastUsed, Self.relative.localizedString(for: last, relativeTo: Date())))
        }
        return parts.joined(separator: " · ")
    }

    private func busyDetail(_ checkout: ReviewRequests.Checkout) -> String {
        checkout.busy.map { reason in
            switch reason {
            case .agentRunning: L10n.t(.reviewBusyRunning)
            case .waitingForAnswer: L10n.t(.reviewBusyWaiting)
            case .error: L10n.t(.reviewBusyError)
            case .backgroundTask: L10n.t(.reviewBusyBackground)
            case .uncommitted(let count): L10n.t(.reviewBusyUncommitted, count)
            case .devServer(let port): L10n.t(.reviewBusyDevServer, port)
            case .reviewRunning(let number): L10n.t(.reviewBusyReview, number)
            case .unreadResult: L10n.t(.reviewBusyUnread)
            case .agentOnWorkBranch: L10n.t(.reviewBusyAgentOnBranch, checkout.branch ?? "—")
            }
        }.joined(separator: " · ")
    }

    private func gitHubButton(_ url: String) -> some View {
        Button {
            appState.openReviewOnGitHub(url)
        } label: {
            Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L10n.t(.reviewOpenOnGitHub))
    }

    // MARK: Findings

    @ViewBuilder
    private func findingsList(_ record: ReviewRecord) -> some View {
        let url = record.id
        if let findings = appState.reviewFindings[url] {
            if let summary = findings.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let all = findings.findings
            let decisions = all.map { appState.reviewDecision($0, of: url) }
            if all.isEmpty {
                Text(L10n.t(.reviewNoFindings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    Text(L10n.t(.reviewSetAll))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .fixedSize()
                    decisionPicker(Set(decisions).count == 1 ? decisions.first : nil) { decision in
                        appState.setAllReviewDecisions(url, to: decision)
                    }
                }
                if !record.decisions.isEmpty,
                   zip(all, decisions).contains(where: { ReviewFindings.preselected($0.0) != $0.1 }) {
                    Button(L10n.t(.reviewBackToPreselection)) { appState.resetReviewDecisions(url) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                ForEach(findings.sorted) { finding in
                    findingCard(finding, url: url)
                }
                Text(ReviewDecision.allCases.compactMap { decision -> String? in
                    let count = decisions.filter { $0 == decision }.count
                    return count > 0 ? "\(label(decision)) \(count)" : nil
                }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                if decisions.contains(.fix) {
                    Text(L10n.t(.reviewFixWarning, record.pr.author))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { appState.reviewVerdict(of: url) },
                    set: { appState.setReviewVerdict(url, to: $0) })) {
                    ForEach(ReviewVerdict.allCases) { verdict in
                        Text(label(verdict)).tag(verdict)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help(L10n.t(.reviewVerdictHelp))
                Button(L10n.t(.reviewSend)) { appState.sendReview(url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(record.sending)
                    .help(L10n.t(.reviewSendHelp))
                Spacer(minLength: 0)
                gitHubButton(url)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func findingCard(_ finding: ReviewFindings.Finding, url: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                SeverityTag(severity: finding.severity)
                if let location = finding.location {
                    Text(location)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(finding.path ?? location)
                }
                Spacer(minLength: 2)
                if finding.hasSuggestion {
                    Text(L10n.t(.reviewSuggestionTag))
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .help(L10n.t(.reviewSuggestionHelp))
                }
            }
            Text(finding.text)
                .font(.caption)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            decisionPicker(appState.reviewDecision(finding, of: url)) { decision in
                appState.setReviewDecision(url, finding: finding.id, to: decision)
            }
        }
        .padding(7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        // What the author will read, before it is sent.
        .help(finding.comment ?? finding.text)
    }

    /// Comment · Fix · Skip. `selection` nil shows none chosen ("Set all" over
    /// mixed decisions).
    private func decisionPicker(_ selection: ReviewDecision?, set: @escaping (ReviewDecision) -> Void) -> some View {
        Picker("", selection: Binding<ReviewDecision?>(
            get: { selection }, set: { if let value = $0 { set(value) } })) {
            ForEach(ReviewDecision.allCases) { decision in
                Text(label(decision)).tag(Optional(decision))
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .help(L10n.t(.reviewDecisionHelp))
    }

    private func label(_ decision: ReviewDecision) -> String {
        switch decision {
        case .comment: L10n.t(.reviewDecisionComment)
        case .fix: L10n.t(.reviewDecisionFix)
        case .skip: L10n.t(.reviewDecisionSkip)
        }
    }

    private func label(_ verdict: ReviewVerdict) -> String {
        switch verdict {
        case .comment: L10n.t(.reviewVerdictComment)
        case .approve: L10n.t(.reviewVerdictApprove)
        case .requestChanges: L10n.t(.reviewVerdictRequestChanges)
        }
    }
}

/// A review's stage in the corner of its row — drawn like `StateChip`, with the
/// review's own words.
struct ReviewChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// HIGH / MEDIUM / LOW — in words, coloured as a second signal only.
struct SeverityTag: View {
    let severity: ReviewFindings.Severity

    var body: some View {
        let (key, tint): (LKey, Color) = switch severity {
        case .high: (.reviewSeverityHigh, AttentionState.error.tint)
        case .medium: (.reviewSeverityMedium, .orange)
        case .low: (.reviewSeverityLow, .gray)
        }
        Text(L10n.t(key))
            .font(.system(size: 9, weight: .bold))
            .textCase(.uppercase)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
    }
}

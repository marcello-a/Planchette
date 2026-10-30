import SwiftUI

/// Persistent right-hand notification sidebar, mirroring the projects and
/// tabs structure: one section per project (same order as the sidebar), one
/// row per tab with its current state and notification. Click a row to jump
/// straight to that tab; click a project header to jump to the project.
/// Resizable via the enclosing HSplitView.
struct AttentionPanel: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("inboxOnlyActive") private var onlyActive = false
    /// With "Only active": the terminals that are working too. Off, because a terminal that
    /// works does not need you — and "Only active" is the list of what does.
    @AppStorage("inboxIncludeRunning") private var includeRunning = false
    /// On by default: the panel's job is "what needs me", and a list that also
    /// holds everything already dealt with buries that. Unticking it shows the
    /// full mirror again, and the choice is remembered.
    @AppStorage("inboxOnlyUnread") private var onlyUnread = true
    let windowID: UUID

    /// A terminal is unread while its last report — a question, an error, a
    /// finished turn — has not been looked at.
    private func isUnread(_ session: TerminalSession) -> Bool { session.isUnread }

    @AppStorage(InboxMode.storageKey) private var mode: InboxMode = .notifications

    var body: some View {
        // One panel, two lists: the toolbar icons pick which (`InboxMode`).
        if mode == .reviews && appState.reviewsEnabled {
            ReviewsPanel()
        } else {
            notifications
        }
    }

    @ViewBuilder
    private var notifications: some View {
        // Order and filtering live in `AppState.notificationSections`, which the
        // control API answers from as well: what another program can read and
        // what this panel shows must be one list (see `ControlAPI`).
        let sections = appState.notificationSections(
            windowID: windowID, unreadOnly: onlyUnread, activeOnly: onlyActive,
            includeRunning: includeRunning)
            .map { (group: $0.group, tabs: $0.sessions) }

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.t(.notificationsPanel)).font(.headline)
                    // How much is unread, which is what the filter below acts on.
                    if appState.unreadCount > 0 {
                        Text("\(appState.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Button {
                        appState.markAllRead()
                    } label: {
                        Image(systemName: "envelope.open")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(appState.unreadCount == 0)
                    .help(L10n.t(.markAllRead))
                }
                // Three checkboxes in a panel that can be narrow: they wrap rather than clip.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { filters; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 4) { filters }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider()

            if sections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz").font(.title2)
                    Text(L10n.t(.allQuiet)).font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections, id: \.group.id) { section in
                            projectHeader(section.group)
                            ForEach(section.tabs) { session in
                                tabRow(session)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    /// The three checkboxes. "Show running" only means something while "Only active" is ticked:
    /// without it the list holds everything, running terminals included — it dims, but stays in reach.
    @ViewBuilder
    private var filters: some View {
        Toggle(L10n.t(.onlyUnread), isOn: $onlyUnread)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(L10n.t(.onlyUnreadHelp))
        Toggle(L10n.t(.onlyActive), isOn: $onlyActive)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(L10n.t(.onlyActiveHelp))
        Toggle(L10n.t(.includeRunning), isOn: $includeRunning)
            .toggleStyle(.checkbox)
            .font(.caption)
            .help(L10n.t(.includeRunningHelp))
            .disabled(!onlyActive)
    }

    // MARK: Project section header

    private func projectHeader(_ group: SessionGroup) -> some View {
        // The same badge row the sidebar puts on the project — errors, questions,
        // unseen results — instead of one badge for the most urgent state. One
        // project, one set of numbers, wherever you read it (`StateSummaryBadges`).
        // Silent tabs keep their colour in the list but stop counting here.
        let counted = appState.sessions(in: group).filter { !appState.isMuted($0) }

        return Button {
            appState.select(group: group)
        } label: {
            HStack(spacing: 6) {
                if let color = group.color.color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(group.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if group.favorite {
                    PixelIcon(sprite: PixelSprites.star, size: 10, tint: .yellow)
                }
                if let until = group.snoozedUntil, until > Date() {
                    SnoozeBadge(until: until)
                }
                Spacer(minLength: 4)
                StateSummaryBadges(sessions: counted)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { GroupAttentionMenu(group: group) }
    }

    // MARK: Tab row

    /// Full context for a hover tooltip: the whole question/error (rows clip
    /// it to 2 lines), the task it belongs to, and the path.
    private func hoverDetail(_ session: TerminalSession) -> String {
        var lines: [String] = []
        if let message = session.lastMessage { lines.append(message) }
        if let task = session.currentTask { lines.append("→ \(task)") }
        lines.append(session.currentDirectory)
        return lines.joined(separator: "\n\n")
    }

    private func tabRow(_ session: TerminalSession) -> some View {
        // The row's middle line is the prompt this terminal is on, not the
        // agent's own message: "Claude is waiting for your input" says what the
        // badge in the corner already says, and the prompt is the thing you have
        // to remember to answer the question. The message stays on hover.
        let detail = session.promptLine

        let unread = isUnread(session)
        return Button {
            appState.select(session: session)
        } label: {
            PanelRow(
                unread: unread, tint: session.state.tint,
                title: appState.notificationHeadline(for: session),
                detail: detail.flatMap { $0.isEmpty ? nil : Text($0) }
            ) {
                SessionStateIcon(session: session, size: 14)
            } chip: {
                StateChip(state: session.state, inBackground: appState.runsInBackground(session))
            } trailing: {
                if let until = appState.snoozeEnd(for: session), until > Date() {
                    SnoozeBadge(until: until)
                } else {
                    WaitingTimeText(since: session.stateSince)
                }
            }
        }
        .buttonStyle(.plain)
        .help(hoverDetail(session))
        .contextMenu {
            Button(L10n.t(.markReady)) { appState.markReady(session.id) }
            // Read/unread by hand, so a row can be kept for later without
            // opening it, or dismissed without opening it either.
            if unread {
                Button(L10n.t(.markRead)) { appState.markSeen(session.id) }
            } else if session.state.isReport {
                Button(L10n.t(.markUnread)) { appState.markUnread(session.id) }
            }
            Divider()
            SessionAttentionMenu(session: session, includesDone: false)
        }
    }
}

/// One row of the right panel, in either of its modes — the same sprite, title,
/// chip, second line and age, so a review reads like a terminal does.
///
/// Unread is carried by the bar down the leading edge of the row and the weight
/// of the title — never by colour alone, and never by a ring: a circle drawn
/// around a pixel sprite fights it.
struct PanelRow<Icon: View, Chip: View, Trailing: View>: View {
    let unread: Bool
    /// The colour of the unread bar: the state's own.
    let tint: Color
    let title: String
    /// Middle for a terminal (its name ends in what matters), tail for a PR title.
    var truncation: Text.TruncationMode = .middle
    /// The row's middle line, at most two lines; it ends before the age instead
    /// of running under it.
    let detail: Text?
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let chip: () -> Chip
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            icon()
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                // The state belongs in the corner, next to the name it describes.
                HStack(spacing: 5) {
                    Text(title)
                        .font(.subheadline).fontWeight(unread ? .bold : .medium)
                        .foregroundStyle(unread ? .primary : .secondary).lineLimit(1)
                        .truncationMode(truncation)
                    Spacer(minLength: 4)
                    chip()
                }
                // The age is short, fixed and always in the same place, so the
                // eye finds it without a line of its own.
                HStack(alignment: .bottom, spacing: 8) {
                    if let detail {
                        detail
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    trailing()
                }
            }
        }
        .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        // The unread mark: a bar in the margin, in the state's own colour. It
        // sits outside the text and outside the sprite, so it can be scanned
        // down the edge of the list without crowding either.
        .overlay(alignment: .leading) {
            if unread {
                Capsule().fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.leading, 5)
            }
        }
    }
}

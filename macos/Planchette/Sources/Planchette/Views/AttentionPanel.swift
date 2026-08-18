import SwiftUI

/// Persistent right-hand notification sidebar, mirroring the projects and
/// tabs structure: one section per project (same order as the sidebar), one
/// row per tab with its current state and notification. Click a row to jump
/// straight to that tab; click a project header to jump to the project.
/// Resizable via the enclosing HSplitView.
struct AttentionPanel: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("inboxOnlyActive") private var onlyActive = false
    /// On by default: the panel's job is "what needs me", and a list that also
    /// holds everything already dealt with buries that. Unticking it shows the
    /// full mirror again, and the choice is remembered.
    @AppStorage("inboxOnlyUnread") private var onlyUnread = true
    let windowID: UUID

    /// A terminal is unread while its last report — a question, an error, a
    /// finished turn — has not been looked at.
    private func isUnread(_ session: TerminalSession) -> Bool { session.isUnread }

    var body: some View {
        // Order and filtering live in `AppState.notificationSections`, which the
        // control API answers from as well: what another program can read and
        // what this panel shows must be one list (see `ControlAPI`).
        let sections = appState.notificationSections(
            windowID: windowID, unreadOnly: onlyUnread, activeOnly: onlyActive)
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
                HStack(spacing: 10) {
                    Toggle(L10n.t(.onlyUnread), isOn: $onlyUnread)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help(L10n.t(.onlyUnreadHelp))
                    Toggle(L10n.t(.onlyActive), isOn: $onlyActive)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Spacer()
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

    /// The row's name: the branch of this terminal's checkout, from its ticket on
    /// (`marcello/feat/NIE-1902-format-switch` → `NIE-1902-format-switch`) — the
    /// ticket and the branch in one string, which is what tells two worktrees of
    /// one repo apart. The line under it already says what the terminal is doing,
    /// so repeating the task up here would cost the width the branch needs.
    ///
    /// A name you typed still wins, and a terminal outside a repo keeps the title
    /// it gives itself.
    private func headline(_ session: TerminalSession) -> String {
        if let custom = session.customTitle, !custom.isEmpty { return custom }
        if let branch = appState.branches[session.id] {
            let cut = Titles.branchFromTicket(branch)
            if !cut.isEmpty { return cut }
        }
        return session.displayTitle
    }

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
            HStack(alignment: .top, spacing: 9) {
                // Unread is carried by the bar down the leading edge of the row
                // and the weight of the title — never by colour alone, and never
                // by a ring: a circle drawn around a pixel sprite fights it.
                StateIcon(state: session.state, size: 14)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    // The state belongs in the corner, next to the name it
                    // describes. The clock time it replaces is gone: "12m" below
                    // answers "how long" without arithmetic, and the wall-clock
                    // hour of a state change answered nothing.
                    HStack(spacing: 5) {
                        Text(headline(session))
                            .font(.subheadline).fontWeight(unread ? .bold : .medium)
                            .foregroundStyle(unread ? .primary : .secondary).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        StateChip(state: session.state)
                    }
                    // Prompt and age on one line: two rows of prompt at most, and
                    // it ends before the age instead of running under it — the age
                    // is short, fixed and always in the same place, so the eye
                    // finds it without a line of its own.
                    HStack(alignment: .bottom, spacing: 8) {
                        if let detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if let until = appState.snoozeEnd(for: session), until > Date() {
                            SnoozeBadge(until: until)
                        } else {
                            WaitingTimeText(since: session.stateSince)
                        }
                    }
                }
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
            // The unread mark: a bar in the margin, in the state's own colour.
            // It sits outside the text and outside the sprite, so it can be
            // scanned down the edge of the list without crowding either.
            .overlay(alignment: .leading) {
                if unread {
                    Capsule().fill(session.state.tint)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                        .padding(.leading, 5)
                }
            }
        }
        .buttonStyle(.plain)
        .help(hoverDetail(session))
        .contextMenu {
            // Read/unread by hand, so a row can be kept for later without
            // opening it, or dismissed without opening it either.
            if unread {
                Button(L10n.t(.markRead)) { appState.markSeen(session.id) }
            } else if session.state.isReport {
                Button(L10n.t(.markUnread)) { appState.markUnread(session.id) }
            }
            Divider()
            SessionAttentionMenu(session: session)
            Divider()
            Button(L10n.t(.rename)) { appState.promptRename(session: session) }
        }
    }
}

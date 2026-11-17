import AppKit
import SwiftUI

/// The to-do board, in the main area: the queue as a column on the left, and to its right the
/// cards that are running, those that wait on someone, and a row of the done ones. A card is
/// moved by its buttons or by dragging it — onto a lane, or onto a card to land before it — and
/// glides there. Each lane wears the sprite and colour of the terminal state it is named after,
/// so a running card has the running robot. The model is `TodoBoard` (`Todos.swift`).
struct TodoBoardView: View {
    @EnvironmentObject var appState: AppState
    @Namespace private var cards
    @State private var newText = ""
    @State private var targetedLane: TodoLane?

    static let queueWidth: CGFloat = 270
    static let cardWidth: CGFloat = 230

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 10) {
                lane(.queued) { queueColumn }
                    .frame(width: Self.queueWidth)
                VStack(spacing: 10) {
                    lane(.running) { grid(.running) }
                        .frame(maxHeight: .infinity)
                    lane(.waiting) { grid(.waiting) }
                        .frame(maxHeight: .infinity)
                    lane(.done) { doneRow }
                        .frame(height: 128)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").foregroundStyle(.secondary)
            Text(L10n.t(.todos)).font(.title2.bold())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Lanes

    /// A lane's frame: its name and count in its state's colour, and the drop that puts a card
    /// at its end.
    private func lane<Content: View>(_ lane: TodoLane, @ViewBuilder content: () -> Content) -> some View {
        let count = appState.todos.items(in: lane).count
        let targeted = targetedLane == lane
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StateIcon(state: lane.state, size: 12)
                Text(lane.title.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(lane.state.tint)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if lane == .done, count > 0 {
                    Button(L10n.t(.todoClearDone)) {
                        withAnimation(Self.motion) { appState.updateTodos { $0.clearDone() } }
                    }
                    .help(L10n.t(.todoClearDone))
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .background(lane.state.tint.opacity(targeted ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(lane.state.tint.opacity(targeted ? 0.6 : 0.2), lineWidth: targeted ? 1.5 : 1)
        )
        .onDrop(of: [TabDragType.utType], isTargeted: Binding(
            get: { targetedLane == lane },
            set: { on in
                if on { targetedLane = lane } else if targetedLane == lane { targetedLane = nil }
            }
        )) { providers in
            drop(providers, into: lane, before: nil)
        }
    }

    /// The queue: the field that adds a card, and the cards under it.
    private var queueColumn: some View {
        VStack(spacing: 8) {
            TextField(L10n.t(.todoNewPlaceholder), text: $newText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    withAnimation(Self.motion) { appState.updateTodos { $0.add(newText) } }
                    newText = ""
                }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(appState.todos.items(in: .queued)) { card($0) }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func grid(_ lane: TodoLane) -> some View {
        let items = appState.todos.items(in: lane)
        return ScrollView {
            if items.isEmpty {
                Text(L10n.t(.todoDropHere))
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardWidth), spacing: 6, alignment: .top)],
                      alignment: .leading, spacing: 6) {
                ForEach(items) { card($0) }
            }
            .padding(.bottom, 4)
        }
    }

    /// The done cards as one row, the latest first.
    private var doneRow: some View {
        let items = appState.todos.items(in: .done)
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 6) {
                ForEach(items) { card($0).frame(width: Self.cardWidth) }
            }
            .padding(.bottom, 4)
        }
    }

    private func card(_ item: TodoItem) -> some View {
        TodoCardView(item: item, onDrop: { providers in drop(providers, into: item.lane, before: item.id) })
            .matchedGeometryEffect(id: item.id, in: cards)
    }

    // MARK: Moving

    static let motion = Animation.spring(response: 0.38, dampingFraction: 0.82)

    private func drop(_ providers: [NSItemProvider], into lane: TodoLane, before: UUID?) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(TabDragItem.typeIdentifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: TabDragItem.typeIdentifier) { data, _ in
            guard let data, let id = TodoDrag.decoded(data) else { return }
            DispatchQueue.main.async {
                withAnimation(Self.motion) {
                    appState.updateTodos { $0.move(id, to: lane, before: before) }
                }
            }
        }
        return true
    }
}

extension TodoLane {
    var title: String {
        switch self {
        case .queued: L10n.t(.todoLaneQueued)
        case .running: L10n.t(.todoLaneRunning)
        case .waiting: L10n.t(.todoLaneWaiting)
        case .done: L10n.t(.todoLaneDone)
        }
    }

    /// The button that moves a card here, and what it says.
    var moveLabel: String {
        switch self {
        case .queued: L10n.t(.todoBackToQueue)
        case .running: L10n.t(.todoMoveRunning)
        case .waiting: L10n.t(.todoMoveWaiting)
        case .done: L10n.t(.todoMoveDone)
        }
    }

    var moveSymbol: String {
        switch self {
        case .queued: "arrow.uturn.backward"
        case .running: "play.fill"
        case .waiting: "hourglass"
        case .done: "checkmark"
        }
    }
}

/// One card: its sprite and text, what it points at, its note and link, the moves it offers.
/// Double-click the text to edit it; the menu has the rest.
struct TodoCardView: View {
    @EnvironmentObject var appState: AppState
    let item: TodoItem
    let onDrop: ([NSItemProvider]) -> Bool

    private enum Field { case text, note, link }
    @State private var editing: Field?
    @State private var draft = ""
    @State private var hovered = false
    @State private var targeted = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(item.lane.state.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                titleRow
                if editing == .note || editing == .link {
                    field
                } else if let note = item.note {
                    Text(note)
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                chips
                footer
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(targeted ? item.lane.state.tint : Color.secondary.opacity(0.2),
                              lineWidth: targeted ? 2 : 1)
        )
        .opacity(item.lane == .done ? 0.75 : 1)
        .onHover { hovered = $0 }
        .help(L10n.t(.todoDragHelp))
        .contextMenu { menu }
        .modifier(DragUnlessEditing(id: item.id, editing: editing != nil))
        .onDrop(of: [TabDragType.utType], isTargeted: $targeted, perform: onDrop)
    }

    // MARK: Parts

    @ViewBuilder
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StateIcon(state: item.lane.state, size: 11)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            if editing == .text {
                field
            } else {
                Text(item.text)
                    .font(.callout)
                    .strikethrough(item.lane == .done, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { begin(.text) }
            }
        }
    }

    private var field: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand { editing = nil }
            .onChange(of: focused) { _, now in if !now, editing != nil { commit() } }
    }

    private var placeholder: String {
        switch editing {
        case .note: L10n.t(.todoNotePlaceholder)
        case .link: L10n.t(.todoLinkPlaceholder)
        default: ""
        }
    }

    /// What the card points at — the terminal with its live state, or the project — and its link.
    @ViewBuilder
    private var chips: some View {
        let group = item.groupID.flatMap { id in appState.groups.first { $0.id == id } }
        let session = item.sessionID.flatMap { appState.sessions[$0] }
        if group != nil || item.link != nil {
            HStack(spacing: 5) {
                if let group {
                    Button { appState.open(todo: item) } label: {
                        HStack(spacing: 4) {
                            if let session {
                                SessionStateIcon(session: session, size: 10)
                            } else if let color = group.color.color {
                                Circle().fill(color).frame(width: 7, height: 7)
                            } else {
                                Image(systemName: "folder").font(.caption2)
                            }
                            Text(session.map { "\(group.name) · \(appState.tabName(for: $0))" } ?? group.name)
                                .lineLimit(1)
                        }
                        .chip()
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t(.todoOpenLinkedHelp))
                }
                if let link = item.link, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "link").font(.caption2)
                            Text(TodoLink.label(link)).lineLimit(1)
                        }
                        .chip()
                    }
                    .buttonStyle(.plain)
                    .help(link)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(Self.age(of: item))
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            // The moves: always on a done card (its undo), on hover elsewhere — a board full of
            // buttons reads as a form.
            ForEach(item.lane == .done ? [.queued] : item.lane.forward, id: \.self) { target in
                Button {
                    withAnimation(TodoBoardView.motion) {
                        appState.updateTodos { $0.move(item.id, to: target) }
                    }
                } label: {
                    Image(systemName: target.moveSymbol)
                        .font(.caption)
                        .foregroundStyle(target == .queued ? Color.secondary : target.state.tint)
                }
                .buttonStyle(.borderless)
                .help(target.moveLabel)
                .accessibilityLabel(target.moveLabel)
            }
            .opacity(hovered || item.lane == .done ? 1 : 0)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(L10n.t(.todoEdit)) { begin(.text) }
        Button(item.note == nil ? L10n.t(.todoAddNote) : L10n.t(.todoEditNote)) { begin(.note) }
            .help(L10n.t(.todoNoteHelp))
        Button(item.link == nil ? L10n.t(.todoAddLink) : L10n.t(.todoEditLink)) { begin(.link) }
            .help(L10n.t(.todoNoteHelp))
        if item.note != nil {
            Button(L10n.t(.todoRemoveNote)) { appState.updateTodos { $0.update(item.id) { $0.note = nil } } }
        }
        if item.link != nil {
            Button(L10n.t(.todoRemoveLink)) { appState.updateTodos { $0.update(item.id) { $0.link = nil } } }
        }
        Divider()
        Menu(L10n.t(.todoLinkTo)) {
            ForEach(appState.groups) { group in
                let terminals = appState.sessions(in: group)
                if terminals.isEmpty {
                    Button(group.name) { link(group: group.id, session: nil) }
                } else {
                    Menu(group.name) {
                        Button(L10n.t(.todoWholeProject)) { link(group: group.id, session: nil) }
                        Divider()
                        ForEach(terminals) { session in
                            Button(appState.tabName(for: session)) { link(group: group.id, session: session.id) }
                        }
                    }
                }
            }
        }
        .help(L10n.t(.todoLinkToHelp))
        if item.groupID != nil {
            Button(L10n.t(.todoUnlink)) { link(group: nil, session: nil) }
            Button(L10n.t(.todoOpenTerminal)) { appState.openTerminal(for: item) }
                .help(L10n.t(.todoOpenTerminalHelp))
        }
        Divider()
        ForEach(TodoLane.allCases.filter { $0 != item.lane }, id: \.self) { target in
            Button(target.moveLabel) {
                withAnimation(TodoBoardView.motion) { appState.updateTodos { $0.move(item.id, to: target) } }
            }
        }
        Divider()
        Button(L10n.t(.todoDelete), role: .destructive) {
            withAnimation(TodoBoardView.motion) { appState.updateTodos { $0.remove(item.id) } }
        }
    }

    // MARK: Editing

    private func begin(_ field: Field) {
        switch field {
        case .text: draft = item.text
        case .note: draft = item.note ?? ""
        case .link: draft = item.link ?? ""
        }
        editing = field
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard let field = editing else { return }
        editing = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.updateTodos { board in
            board.update(item.id) { card in
                switch field {
                case .text:
                    if let cleaned = TodoBoard.cleaned(text) { card.text = cleaned }
                case .note:
                    card.note = text.isEmpty ? nil : text
                case .link:
                    // Something that is no link leaves the link as it was.
                    if text.isEmpty { card.link = nil } else if let link = TodoLink.normalized(text) { card.link = link }
                }
            }
        }
    }

    private func link(group: UUID?, session: UUID?) {
        appState.updateTodos { $0.update(item.id) { $0.groupID = group; $0.sessionID = session } }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// Since when the card is done, or else since when it exists.
    private static func age(of item: TodoItem) -> String {
        relative.locale = Locale(identifier: L10n.current.resolved.rawValue)
        return relative.localizedString(for: item.doneAt ?? item.createdAt, relativeTo: Date())
    }
}

/// A card drags while it is not being edited: a drag would take the text selection from the field.
private struct DragUnlessEditing: ViewModifier {
    let id: UUID
    let editing: Bool

    func body(content: Content) -> some View {
        if editing {
            content
        } else {
            content.onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: TabDragItem.typeIdentifier, visibility: .ownProcess
                ) { completion in
                    completion(TodoDrag.encoded(id), nil)
                    return nil
                }
                return provider
            }
        }
    }
}

private extension View {
    func chip() -> some View {
        font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

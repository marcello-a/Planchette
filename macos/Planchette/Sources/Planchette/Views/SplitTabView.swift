import SwiftUI
import UniformTypeIdentifiers

/// The content of the tab in front: its split tree, a terminal in every leaf.
///
/// A drag of a tab or of a pane's title can land on an edge of any pane — the terminal
/// itself, not only its title — and the view splits there, as iTerm2 does.
struct SplitTabView: View {
    @EnvironmentObject var appState: AppState
    let tab: SplitLayout
    let group: SessionGroup

    var body: some View {
        SplitNodeView(node: tab, group: group, showsHeaders: tab.leaves.count > 1)
            // A tab keeps its identity while its panes stay the same ones, so a rearranged
            // tree is the same view; a tab with other panes is another view.
            .id(tab.stableID)
    }
}

private struct SplitNodeView: View {
    @EnvironmentObject var appState: AppState
    let node: SplitLayout
    let group: SessionGroup
    let showsHeaders: Bool

    var body: some View {
        switch node {
        case .leaf(let id):
            if let session = appState.sessions[id] {
                PaneView(session: session, group: group, showsHeader: showsHeaders)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        case .row(let children):
            HSplitView {
                ForEach(children, id: \.stableID) { child in
                    SplitNodeView(node: child, group: group, showsHeaders: showsHeaders)
                        .frame(minWidth: 120, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .column(let children):
            VSplitView {
                ForEach(children, id: \.stableID) { child in
                    SplitNodeView(node: child, group: group, showsHeaders: showsHeaders)
                        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
                }
            }
        }
    }
}

/// One terminal, with edge drop zones, and a title bar when the tab holds more than one pane.
private struct PaneView: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    let group: SessionGroup
    let showsHeader: Bool
    @State private var dropEdge: LayoutEdge?
    @State private var paneSize: CGSize = .zero

    private var isActive: Bool {
        appState.groups.first { $0.id == group.id }?.activeSessionID == session.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            TerminalHostView(session: session, autoFocus: isActive)
                .id(session.id)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { paneSize = proxy.size }
                    .onChange(of: proxy.size) { _, s in paneSize = s }
            }
        )
        .overlay { dropIndicator }
        .onDrop(of: [TabDragType.utType], delegate: PaneDropDelegate(
            targetID: session.id, groupID: group.id, appState: appState,
            paneSize: paneSize, dropEdge: $dropEdge))
        .onDisappear { dropEdge = nil }
        // Where one pane ends and the next begins; a single pane has no neighbour to tell apart.
        .border(showsHeader ? Color.black.opacity(0.2) : .clear, width: 0.5)
    }

    private var header: some View {
        HStack(spacing: 5) {
            SessionStateIcon(session: session, size: 12)
            Text(appState.tabName(for: session)).font(.caption.weight(.medium)).lineLimit(1)
            Text(session.shortPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button {
                TabCloser.confirmAndClose(
                    [session.id], title: L10n.t(.closeTabAlertTitle, appState.tabName(for: session)),
                    appState: appState)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(.closeHelp))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                             : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
        // The title bar is the pane's tab, so it carries the state line — the terminal
        // body stays clean.
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(session.state.tint).frame(height: 2)
            } else {
                Divider()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.select(session: session) }
        // Drag the pane by its title (the terminal keeps text selection). A titled preview
        // replaces the default, blank one.
        .onDrag({
            appState.draggingTabItem = .pane(session.id)
            return TabDragType.provider(for: .pane(session.id))
        }, preview: {
            DragPreview(title: appState.tabName(for: session), symbol: "rectangle.split.2x1")
        })
        .contextMenu {
            Button(L10n.t(.movePaneToTab)) {
                appState.extractPane(session.id, before: nil, groupID: group.id)
            }
            Divider()
            Button(L10n.t(.close), role: .destructive) {
                TabCloser.confirmAndClose(
                    [session.id], title: L10n.t(.closeTabAlertTitle, appState.tabName(for: session)),
                    appState: appState)
            }
        }
        .help(session.currentDirectory)
    }

    /// Lights the half where the dragged tab or pane will land (iTerm2-style).
    @ViewBuilder
    private var dropIndicator: some View {
        GeometryReader { geo in
            if let edge = dropEdge {
                let r = DropGeometry.rect(for: edge, in: geo.size).insetBy(dx: 4, dy: 4)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: max(r.width, 0), height: max(r.height, 0))
                    .position(x: r.midX, y: r.midY)
                    .animation(.easeOut(duration: 0.12), value: edge)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The picture under the pointer while a tab or a pane is dragged.
struct DragPreview: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
    }
}

/// The pasteboard type of a tab or pane drag, and how to make and read one. Never plain text:
/// see `TabDragItem`.
enum TabDragType {
    static let utType = UTType.json

    static func provider(for item: TabDragItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: TabDragItem.typeIdentifier, visibility: .ownProcess
        ) { completion in
            completion(item.encoded, nil)
            return nil
        }
        return provider
    }

    /// Read the item off the provider, then hand it over on the main queue.
    static func load(from providers: [NSItemProvider], then done: @escaping @MainActor (TabDragItem) -> Void) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(TabDragItem.typeIdentifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: TabDragItem.typeIdentifier) { data, _ in
            guard let data, let item = TabDragItem(encoded: data) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(item) } }
        }
        return true
    }
}

/// Where in a pane the pointer is, as an edge — and the half that edge claims.
enum DropGeometry {
    /// The edge nearest to the pointer: the pane is cut by its diagonals into four.
    static func nearestEdge(of location: CGPoint, in size: CGSize) -> LayoutEdge {
        let w = max(size.width, 1), h = max(size.height, 1)
        let fx = min(max(location.x / w, 0), 1)
        let fy = min(max(location.y / h, 0), 1)
        let distances: [(LayoutEdge, CGFloat)] =
            [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }

    static func rect(for edge: LayoutEdge, in size: CGSize) -> CGRect {
        switch edge {
        case .left: return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

/// Works out the edge from the drop location and performs the drop. It lights up, and
/// accepts, only a drop that would change the arrangement.
private struct PaneDropDelegate: DropDelegate {
    let targetID: UUID
    let groupID: UUID
    let appState: AppState
    let paneSize: CGSize
    @Binding var dropEdge: LayoutEdge?

    func dropEntered(info: DropInfo) { dropEdge = validEdge(for: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let edge = validEdge(for: info)
        dropEdge = edge
        return DropProposal(operation: edge == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { dropEdge = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let edge = validEdge(for: info) else { dropEdge = nil; return false }
        dropEdge = nil
        appState.draggingTabItem = nil
        let target = targetID, group = groupID, state = appState
        return TabDragType.load(from: info.itemProviders(for: [TabDragType.utType])) { item in
            switch item {
            case .tab(let tab): state.dropTab(tab, onto: target, edge: edge, groupID: group)
            case .pane(let pane): state.dropPane(pane, onto: target, edge: edge, groupID: group)
            }
            // What was dropped is what you are looking at.
            if let dropped = item.terminal { state.focusPane(dropped) }
        }
    }

    /// The nearest edge, but only if dropping there would change the strip.
    private func validEdge(for info: DropInfo) -> LayoutEdge? {
        let edge = DropGeometry.nearestEdge(of: info.location, in: paneSize)
        guard let item = appState.draggingTabItem else { return edge }
        let result: [SplitLayout]?
        switch item {
        case .tab(let tab): result = appState.dropTabResult(tab, onto: targetID, edge: edge, groupID: groupID)
        case .pane(let pane): result = appState.dropPaneResult(pane, onto: targetID, edge: edge, groupID: groupID)
        }
        return result == nil ? nil : edge
    }
}

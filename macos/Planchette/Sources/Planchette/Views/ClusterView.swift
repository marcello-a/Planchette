import SwiftUI
import UniformTypeIdentifiers

/// Cluster mode: terminals arranged as resizable split panes. Drag a pane by
/// its header onto another pane's edge (top/bottom/left/right) to re-split —
/// same interaction model as iTerm2.
struct ClusterView: View {
    @EnvironmentObject var appState: AppState
    let group: SessionGroup

    var body: some View {
        SplitNodeView(node: appState.clusterLayout(for: group), group: group)
    }
}

private struct SplitNodeView: View {
    @EnvironmentObject var appState: AppState
    let node: SplitLayout
    let group: SessionGroup

    var body: some View {
        switch node {
        case .leaf(let id):
            if let session = appState.sessions[id] {
                PaneView(session: session, group: group)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        case .row(let children):
            HSplitView {
                ForEach(children, id: \.stableID) { child in
                    SplitNodeView(node: child, group: group)
                        .frame(minWidth: 120, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .column(let children):
            VSplitView {
                ForEach(children, id: \.stableID) { child in
                    SplitNodeView(node: child, group: group)
                        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
                }
            }
        }
    }
}

/// A single terminal pane with a draggable header and edge drop zones.
private struct PaneView: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    let group: SessionGroup
    @State private var dropEdge: LayoutEdge?
    @State private var paneSize: CGSize = .zero

    private var isActive: Bool {
        appState.groups.first { $0.id == group.id }?.activeSessionID == session.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(session: session, autoFocus: false)
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
        .onDrop(of: [.plainText, .text], delegate: PaneDropDelegate(
            targetID: session.id, groupID: group.id, appState: appState,
            paneSize: paneSize, dropEdge: $dropEdge))
        .onDisappear { dropEdge = nil }
        .border(Color.black.opacity(0.2), width: 0.5)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle().fill(session.state.tint).frame(width: 7, height: 7)
            Text(session.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
            Text(session.shortPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                             : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { appState.select(session: session) }
        // Drag the pane by its header (the terminal body keeps text selection).
        // A titled preview replaces the default (ugly, blank) drag image.
        .onDrag({
            appState.draggingClusterSessionID = session.id
            return NSItemProvider(object: session.id.uuidString as NSString)
        }, preview: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.split.2x1")
                Text(session.displayTitle).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
        })
        .help(session.currentDirectory)
    }

    /// Highlights the half where the dragged pane will land (iTerm2-style).
    @ViewBuilder
    private var dropIndicator: some View {
        GeometryReader { geo in
            if let edge = dropEdge {
                let r = rect(for: edge, in: geo.size).insetBy(dx: 4, dy: 4)
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

    private func rect(for edge: LayoutEdge, in size: CGSize) -> CGRect {
        switch edge {
        case .left:   return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:  return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:    return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

/// Computes the target edge from the drop location and performs the move.
/// Only highlights and accepts drops that would actually rearrange the panes —
/// dropping a pane back where it already is is refused (no phantom highlight).
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
        appState.draggingClusterSessionID = nil
        guard let provider = info.itemProviders(for: [.plainText, .text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let dragged = UUID(uuidString: str) else { return }
            DispatchQueue.main.async {
                appState.moveInCluster(dragged, target: targetID, edge: edge, groupID: groupID)
            }
        }
        return true
    }

    /// The nearest edge, but only if dropping there would change the layout;
    /// otherwise nil (a no-op position — dragging a pane onto where it already
    /// sits, or onto itself).
    private func validEdge(for info: DropInfo) -> LayoutEdge? {
        let edge = nearestEdge(for: info)
        guard let dragged = appState.draggingClusterSessionID else { return edge }
        return appState.clusterMoveResult(
            dragged: dragged, target: targetID, edge: edge, groupID: groupID) != nil ? edge : nil
    }

    /// Nearest edge to the pointer within the pane (iTerm2-style quadrants).
    private func nearestEdge(for info: DropInfo) -> LayoutEdge {
        let w = max(paneSize.width, 1), h = max(paneSize.height, 1)
        let fx = min(max(info.location.x / w, 0), 1)
        let fy = min(max(info.location.y / h, 0), 1)
        let distances: [(LayoutEdge, CGFloat)] =
            [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }
}

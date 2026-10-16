import Foundation

/// The tab strip of a project: an ordered list of tabs, each one a split tree of
/// terminals — the model of iTerm2. A tab with one leaf is the plain tab of old; a tab
/// with several is a window of split panes that lives under a single tab.
///
/// Everything here is pure and unit-tested. The rules it keeps, after every operation:
///
/// - every terminal of the project is a leaf of exactly one tab, once;
/// - there is no empty tab, no node with a single child, no row inside a row and no
///   column inside a column (`SplitLayout.normalized`);
/// - an operation that would change nothing answers `nil`, so a drop that puts a pane
///   back where it was is refused instead of animating.
enum TabStrip {
    // MARK: Reading

    /// The strip for exactly `ids`: leaves that are gone drop out (and a tab that held only
    /// those), a terminal that is in two places stays in the first, and a terminal that is in
    /// no tab gets one of its own at the end. `nil` — a project that never split anything, or
    /// state written before tabs held splits — is one tab per terminal.
    static func synced(_ tabs: [SplitLayout]?, to ids: [UUID]) -> [SplitLayout] {
        let allowed = Set(ids)
        var seen = Set<UUID>()
        var result: [SplitLayout] = []
        for tab in tabs ?? [] {
            if let kept = tab.pruned({ allowed.contains($0) && seen.insert($0).inserted }) {
                result.append(kept.normalized())
            }
        }
        for id in ids where seen.insert(id).inserted {
            result.append(.leaf(id))
        }
        return result
    }

    /// The tab a terminal is in.
    static func index(of id: UUID, in tabs: [SplitLayout]) -> Int? {
        tabs.firstIndex { $0.leaves.contains(id) }
    }

    /// Every terminal, tab by tab, pane by pane — the order the sidebar lists them in.
    static func order(_ tabs: [SplitLayout]) -> [UUID] {
        tabs.flatMap(\.leaves)
    }

    /// Which terminal is current once `id` is gone: its neighbour in the same tab; when it was
    /// alone in its tab, the tab to the right, else the one to the left.
    static func successor(of id: UUID, in tabs: [SplitLayout]) -> UUID? {
        guard let tab = index(of: id, in: tabs) else { return nil }
        let leaves = tabs[tab].leaves
        if leaves.count > 1, let at = leaves.firstIndex(of: id) {
            return at + 1 < leaves.count ? leaves[at + 1] : leaves[at - 1]
        }
        if tab + 1 < tabs.count { return tabs[tab + 1].leaves.first }
        if tab > 0 { return tabs[tab - 1].leaves.first }
        return nil
    }

    // MARK: Changing

    /// The strip without a terminal; a tab it leaves empty goes with it.
    static func removing(_ id: UUID, from tabs: [SplitLayout]) -> [SplitLayout] {
        tabs.compactMap { $0.pruned { $0 != id }?.normalized() }
    }

    /// Move a tab to stand before the tab that is at index `before` now (`tabs.count` is the
    /// end). Moving it to where it stands is nothing.
    static func moveTab(from: Int, before: Int, in tabs: [SplitLayout]) -> [SplitLayout]? {
        guard tabs.indices.contains(from), (0...tabs.count).contains(before) else { return nil }
        var rest = tabs
        let tab = rest.remove(at: from)
        rest.insert(tab, at: before > from ? before - 1 : before)
        return rest == tabs ? nil : rest
    }

    /// Drop a whole tab on an edge of a pane of another tab: its panes join that tab, with
    /// the arrangement they had, and the strip loses one tab.
    static func dropTab(
        at from: Int, onto target: UUID, edge: LayoutEdge, in tabs: [SplitLayout]
    ) -> [SplitLayout]? {
        guard tabs.indices.contains(from),
              let to = index(of: target, in: tabs), to != from else { return nil }
        var rest = tabs
        let moving = rest.remove(at: from)
        let at = to > from ? to - 1 : to
        rest[at] = rest[at].inserting(moving, besides: target, edge: edge).normalized()
        return rest
    }

    /// Drop one pane on an edge of another pane — in its own tab (rearranging it) or in
    /// another one (joining it; a tab the pane leaves empty goes).
    static func dropPane(
        _ dragged: UUID, onto target: UUID, edge: LayoutEdge, in tabs: [SplitLayout]
    ) -> [SplitLayout]? {
        guard dragged != target,
              let from = index(of: dragged, in: tabs),
              let to = index(of: target, in: tabs) else { return nil }
        var rest = tabs
        var at = to
        if let remaining = rest[from].pruned({ $0 != dragged }) {
            rest[from] = remaining.normalized()
        } else {
            rest.remove(at: from)
            if to > from { at = to - 1 }
        }
        rest[at] = rest[at].inserting(.leaf(dragged), besides: target, edge: edge).normalized()
        return rest == tabs ? nil : rest
    }

    /// Take a pane out of its tab and make it a tab of its own, standing before the tab at
    /// index `before` (`tabs.count` is the end). A pane that is alone already just moves.
    static func extractPane(_ id: UUID, before: Int, in tabs: [SplitLayout]) -> [SplitLayout]? {
        guard let from = index(of: id, in: tabs), (0...tabs.count).contains(before) else { return nil }
        if tabs[from].leaves.count == 1 { return moveTab(from: from, before: before, in: tabs) }
        var rest = tabs
        guard let remaining = rest[from].pruned({ $0 != id }) else { return nil }
        rest[from] = remaining.normalized()
        rest.insert(.leaf(id), at: before)
        return rest
    }

    /// Every tab in one, as a grid: two tabs side by side, four as two over two. The
    /// arrangement inside each tab stays.
    static func combined(_ tabs: [SplitLayout]) -> [SplitLayout]? {
        guard tabs.count > 1 else { return nil }
        let columns = Int(Double(tabs.count).squareRoot().rounded(.up))
        let rows: [SplitLayout] = stride(from: 0, to: tabs.count, by: columns).map { start in
            let row = Array(tabs[start..<min(start + columns, tabs.count)])
            return row.count == 1 ? row[0] : .row(row)
        }
        return [(rows.count == 1 ? rows[0] : .column(rows)).normalized()]
    }

    /// Every pane a tab of its own, in the order they have. Nothing when that is so already.
    static func separated(_ tabs: [SplitLayout]) -> [SplitLayout]? {
        let leaves = order(tabs)
        return leaves.count == tabs.count ? nil : leaves.map { .leaf($0) }
    }
}

extension SplitLayout {
    /// Keep the leaves `keep` accepts, asking in order and so able to keep a terminal once;
    /// what is left collapses. `nil` when nothing is.
    func pruned(_ keep: (UUID) -> Bool) -> SplitLayout? {
        switch self {
        case .leaf(let id):
            return keep(id) ? self : nil
        case .row(let children):
            return Self.collapsed(children.compactMap { $0.pruned(keep) }, isRow: true)
        case .column(let children):
            return Self.collapsed(children.compactMap { $0.pruned(keep) }, isRow: false)
        }
    }

    private static func collapsed(_ children: [SplitLayout], isRow: Bool) -> SplitLayout? {
        if children.isEmpty { return nil }
        if children.count == 1 { return children[0] }
        return isRow ? .row(children) : .column(children)
    }

    /// Put `node` — a pane, or a whole arrangement — on an edge of the leaf `target`.
    func inserting(_ node: SplitLayout, besides target: UUID, edge: LayoutEdge) -> SplitLayout {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            switch edge {
            case .left: return .row([node, self])
            case .right: return .row([self, node])
            case .top: return .column([node, self])
            case .bottom: return .column([self, node])
            }
        case .row(let children):
            return .row(children.map { $0.inserting(node, besides: target, edge: edge) })
        case .column(let children):
            return .column(children.map { $0.inserting(node, besides: target, edge: edge) })
        }
    }
}

/// What a drag of the tab bar or of a pane's title carries: a whole tab (named by its first
/// terminal) or one pane.
///
/// It travels as JSON, never as text. A terminal accepts dropped text and types it at the
/// prompt, so a tab dragged over a terminal as plain text would have typed its id into the
/// shell; JSON is a type the terminal does not take. (A type of our own would be cleaner, but an
/// undeclared one never reaches a drop target, and an unbundled dev build has no Info.plist to
/// declare it in.)
enum TabDragItem: Equatable {
    case tab(UUID)
    case pane(UUID)

    /// The pasteboard type of both.
    static let typeIdentifier = "public.json"

    var encoded: Data {
        let object: [String: String]
        switch self {
        case .tab(let id): object = ["planchetteTab": id.uuidString]
        case .pane(let id): object = ["planchettePane": id.uuidString]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    init?(encoded data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.count == 1, let (key, value) = object.first, let text = value as? String,
              let id = UUID(uuidString: text) else { return nil }
        switch key {
        case "planchetteTab": self = .tab(id)
        case "planchettePane": self = .pane(id)
        default: return nil
        }
    }
}

extension TabDragItem {
    /// A terminal the drag stands for: the pane itself, or the first pane of a tab.
    var terminal: UUID? {
        switch self {
        case .tab(let id), .pane(let id): return id
        }
    }
}

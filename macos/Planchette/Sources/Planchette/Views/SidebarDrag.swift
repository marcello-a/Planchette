import SwiftUI
import UniformTypeIdentifiers

/// What a drag in the project panel carries: projects (a multi-selection drags all of them), one
/// terminal, or one folder.
///
/// It travels as JSON, like a tab's drag (`TabDragItem`), never as text: a terminal accepts
/// dropped text and types it at the prompt, so a project dragged over a terminal as plain text
/// typed its ids into the shell. A terminal travels exactly as a dragged pane does, so the tab
/// bar and the panes read it too — and a tab or a pane dragged into the panel reads as one.
enum SidebarDragItem: Equatable {
    case projects([UUID])
    case terminal(UUID)
    case folder(UUID)

    static let typeIdentifier = TabDragItem.typeIdentifier

    var encoded: Data {
        switch self {
        case .terminal(let id):
            return TabDragItem.pane(id).encoded
        case .projects(let ids):
            // One string, like every other drag of ours: a reader that knows only tabs and panes
            // sees an unknown key and lets it go.
            return Self.json(["planchetteProjects": ids.map(\.uuidString).joined(separator: " ")])
        case .folder(let id):
            return Self.json(["planchetteFolder": id.uuidString])
        }
    }

    init?(encoded data: Data) {
        if let item = TabDragItem(encoded: data), let id = item.terminal {
            self = .terminal(id)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.count == 1, let (key, value) = object.first, let text = value as? String
        else { return nil }
        switch key {
        case "planchetteProjects":
            let ids = text.split(separator: " ").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return nil }
            self = .projects(ids)
        case "planchetteFolder":
            guard let id = UUID(uuidString: text) else { return nil }
            self = .folder(id)
        default:
            return nil
        }
    }

    private static func json(_ object: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

extension SidebarDragItem: Transferable {
    struct NotOurs: Error {}

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .json) { item in
            item.encoded
        } importing: { data in
            guard let item = SidebarDragItem(encoded: data) else { throw NotOurs() }
            return item
        }
    }
}

/// Drop handling for one row of the project panel. `dropDestination` only reports whether a drag
/// is over a view, never where — and "where" is the point of dropping into a list: above this row
/// or below it. `DropDelegate` reports the live location, so the insertion line follows the
/// pointer and the drop lands in the gap you aimed at. What the row does with which kind of drag
/// is the row's business (`perform`).
struct SidebarDropDelegate: DropDelegate {
    let rowID: UUID
    /// Row height, read from the row itself — the midpoint decides the gap.
    let height: () -> CGFloat
    let slot: (SidebarView.DropSlot?) -> Void
    let perform: (_ item: SidebarDragItem, _ below: Bool) -> Void

    private func below(_ info: DropInfo) -> Bool {
        info.location.y > height() / 2
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.json])
    }

    func dropEntered(info: DropInfo) {
        slot(SidebarView.DropSlot(rowID: rowID, below: below(info)))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        slot(SidebarView.DropSlot(rowID: rowID, below: below(info)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        slot(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let landsBelow = below(info)
        slot(nil)
        guard let provider = info.itemProviders(for: [.json]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: SidebarDragItem.typeIdentifier) { data, _ in
            guard let data, let item = SidebarDragItem(encoded: data) else { return }
            DispatchQueue.main.async { perform(item, landsBelow) }
        }
        return true
    }
}

import SwiftUI

/// The thin lines that tie a folder to its projects and a project to its terminals: a line down
/// from the parent's disclosure arrow, a short stub to each child — "├" — and a bend at the last
/// one — "└". Each in the colour of its folder or project, so a glance says what belongs where.
///
/// The List draws every row on its own, so every row draws its own slice of the lines, in its
/// row background: the slices meet without a gap, as the project wash's do (`ProjectWash`).
enum TreeLines {
    /// Which parent a line hangs from.
    enum Column { case folder, project }

    enum Kind: Equatable {
        /// A child that is not the last: the line goes on below it, with a stub to it.
        case tee
        /// The last child: the line bends into its stub and ends.
        case corner
        /// A row under a child that is not the last (that child's own terminals): only the line.
        case through
        /// The parent's own row: the line starts under its arrow and runs down to the children.
        case start
    }

    struct Line: Equatable {
        var column: Column
        var kind: Kind
        var color: SessionColor
    }

    /// The folder's slice of a row that belongs to project `index` of `count` in it: the project
    /// row itself (`isProjectRow`), or a row under it — its terminals, or one peeking out.
    static func folderLine(index: Int, of count: Int, isProjectRow: Bool) -> Kind? {
        let last = index == count - 1
        if isProjectRow { return last ? .corner : .tee }
        return last ? nil : .through
    }

    /// A project's slice of its terminal `index` of `count`.
    static func projectLine(index: Int, of count: Int) -> Kind {
        index == count - 1 ? .corner : .tee
    }

    // Where the lines run, in the row background's own coordinates (it starts at the list's
    // edge, not at the row's indented content). Measured on the sidebar: the line runs down
    // the middle of the parent's disclosure arrow, and the stub stops short of the child.
    static func x(_ column: Column) -> CGFloat { column == .folder ? 18 : 32 }
    static func stubEnd(_ column: Column) -> CGFloat { column == .folder ? 24 : 50 }
    /// The stub meets a child's first line, not the middle of a row that may be three lines high.
    static let stubY: CGFloat = 13
    static let radius: CGFloat = 3
}

/// The slices of the tree lines one row draws.
struct TreeLinesSlice: View {
    let lines: [TreeLines.Line]

    var body: some View {
        Canvas { context, size in
            for line in lines {
                let x = TreeLines.x(line.column), end = TreeLines.stubEnd(line.column)
                let y = min(TreeLines.stubY, size.height / 2)
                var path = Path()
                switch line.kind {
                case .start:
                    // From just under the arrow, which sits in the middle of a one-line row.
                    path.move(to: CGPoint(x: x, y: size.height / 2 + 8))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                case .through:
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                case .tee:
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: end, y: y))
                case .corner:
                    // "└" with a small round bend: thin lines with a hard corner look like a frame.
                    let r = TreeLines.radius
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: y - r))
                    path.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: end, y: y))
                }
                context.stroke(path, with: .color(Self.tint(line.color)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    /// The parent's colour, softened so the line stays a hint; a parent without one gets a grey
    /// that only just shows.
    static func tint(_ color: SessionColor) -> Color {
        color.color.map { $0.opacity(0.55) } ?? Color.secondary.opacity(0.3)
    }
}

/// The row background of everything inside a folder: the folder's wash while the folder is
/// selected, then whatever the row paints itself (a project's colour over its terminals), then
/// the tree lines on top. Row backgrounds meet without a gap, so the wash reads as one area.
struct TreeRowBackground<Own: View>: View {
    let folder: SidebarView.FolderPlace?
    let lines: [TreeLines.Line]
    @ViewBuilder var own: () -> Own

    var body: some View {
        ZStack {
            if let folder, folder.highlighted {
                FolderHighlight(color: folder.color)
            }
            own()
            TreeLinesSlice(lines: lines)
        }
    }
}

extension TreeRowBackground where Own == EmptyView {
    init(folder: SidebarView.FolderPlace?, lines: [TreeLines.Line]) {
        self.init(folder: folder, lines: lines) { EmptyView() }
    }
}

/// A selected folder's colour behind what belongs to it: soft, and fading to the right, so the
/// rows stay readable and their own colours still show. A folder without a colour lends the
/// selection's.
struct FolderHighlight: View {
    let color: SessionColor

    var body: some View {
        let tint = color.color ?? Color.accentColor
        LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.06)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

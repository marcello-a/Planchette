import SwiftUI

/// The wash behind a project: the color picked in the project's Color menu, strongest
/// where the project starts and fading out from there. A project without a color has no
/// wash at all — "none" means none — and Settings → General → Project color
/// (`ProjectColorLook`) decides where the wash shows and how strong it is.
///
/// Two shapes. A **strip** is the label of a project and the header of its tab bar: it
/// runs sideways, strongest at the left, gone before the dev-server links and the view
/// switch at the right. A **body** is what lies under an open label in the project panel,
/// behind the terminals: much softer than the label it hangs from, and one gradient for
/// all of them.
struct ProjectGradient: View {
    enum Shape {
        /// A label or a header: left to right.
        case strip
        /// The terminal in row `row` of `count` under an open label. The terminals of a project are
        /// rows of the list, each with a background of its own, so each one draws its own slice of the
        /// one gradient (see `ProjectWash`).
        case body(row: Int, of: Int)
    }

    let color: SessionColor
    let look: ProjectColorLook
    var shape: Shape = .strip

    var body: some View {
        if let base = color.color, let power = ProjectWash.strengths(isLabel: isStrip, look: look) {
            switch shape {
            case .strip:
                LinearGradient(
                    colors: [base.opacity(power.lead), base.opacity(power.tail)],
                    startPoint: .leading, endPoint: .trailing)
            case .body(let row, let count):
                let edge = ProjectWash.slice(row: row, of: count, lead: power.lead, tail: power.tail)
                LinearGradient(
                    colors: [base.opacity(edge.top), base.opacity(edge.bottom)],
                    startPoint: .top, endPoint: .bottom)
                    // The label fades out sideways; so does what hangs from it.
                    .mask(LinearGradient(
                        colors: [.black, .black.opacity(ProjectWash.sideFade)],
                        startPoint: .leading, endPoint: .trailing))
                    .clipShape(ProjectWash.outline(row: row, of: count))
                    .padding(.leading, ProjectWash.leadingInset)
                    .padding(.trailing, ProjectWash.trailingInset)
            }
        } else {
            Color.clear
        }
    }

    private var isStrip: Bool {
        if case .strip = shape { return true }
        return false
    }
}

/// What it takes to draw the wash: how strong it is, and how one gradient is drawn over
/// several rows of a list, each of which paints its own background. Pure, so the numbers
/// are tested rather than remembered.
enum ProjectWash {
    /// The strength of a label's wash at its left end and at its right end, in the colorful
    /// look — the one 0.2.36 shipped, and what every other strength is a share of.
    static let colorfulLabel = (lead: 0.34, tail: 0.05)
    /// The same for the wash behind the terminals, at its top and at its bottom.
    static let colorfulBody = (lead: 0.12, tail: 0.03)

    /// The strength at the start and at the end of a wash, or nil when nothing is drawn:
    /// the project has no color, or the setting leaves this place out.
    static func strengths(isLabel: Bool, hasColor: Bool = true, look: ProjectColorLook) -> (lead: Double, tail: Double)? {
        guard hasColor, isLabel ? look.showsLabel : look.showsBody else { return nil }
        let full = isLabel ? colorfulLabel : colorfulBody
        let share = look.strength.factor(isLabel: isLabel)
        return (full.lead * share, full.tail * share)
    }

    /// How strong the fade is at the top and at the bottom of row `row` of `count`: one straight line
    /// from `lead`, at the top of the first row, to `tail`, at the bottom of the last, cut in equal
    /// parts. Rows are not all equally tall, so the slope varies a little from row to row — the
    /// strength never jumps, which is what makes it read as one.
    ///
    /// Drawn in slices because a background put on the project's `DisclosureGroup` is handed to
    /// every row of it, and each one then runs the whole fade — a band per terminal.
    static func slice(row: Int, of count: Int, lead: Double, tail: Double) -> (top: Double, bottom: Double) {
        let rows = max(count, 1)
        let row = min(max(row, 0), rows - 1)
        func strength(at step: Int) -> Double { lead + (tail - lead) * Double(step) / Double(rows) }
        return (strength(at: row), strength(at: row + 1))
    }

    /// How much of its strength the wash keeps at the right edge.
    static let sideFade = 0.45

    /// The gap between the wash and the edges of the row: on the right the same as the label's, so
    /// the block ends where the label above it ends; on the left less, so it reaches under the arrow.
    static let leadingInset: CGFloat = 8
    static let trailingInset: CGFloat = 16

    static let radius: CGFloat = 6

    /// The corners that make the rows one block: the first row is rounded at the top, the last at the
    /// bottom, and where two rows meet there is nothing to see.
    static func outline(row: Int, of count: Int) -> UnevenRoundedRectangle {
        let first = row <= 0
        let last = row >= count - 1
        return UnevenRoundedRectangle(
            topLeadingRadius: first ? radius : 0, bottomLeadingRadius: last ? radius : 0,
            bottomTrailingRadius: last ? radius : 0, topTrailingRadius: first ? radius : 0)
    }
}

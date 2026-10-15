import SwiftUI

extension Color {
    /// The violet of the app icon, #3A2861: what a project is tinted with until it has a color
    /// of its own, so an uncolored project says "Planchette" and not "unset".
    static let planchettePurple = Color(red: 0x3A / 255, green: 0x28 / 255, blue: 0x61 / 255)

    /// The same hue, light enough to tint a light window without making black text hard to read.
    static let planchettePurpleLight = Color(red: 0x8C / 255, green: 0x74 / 255, blue: 0xD0 / 255)
}

extension SessionColor {
    /// The color the user chose, or Planchette purple when there is none.
    var accent: Color { color ?? .planchettePurple }
}

/// The wash behind a project: its color — the one picked in the project's Color menu, the violet of
/// the app icon until then — strongest where the project starts and fading out from there.
///
/// Two shapes. A **strip** is the label of a project and the header of its tab bar: it runs sideways,
/// strongest at the left, gone before the dev-server links and the view switch at the right. A
/// **body** is what lies under an open label in the project panel, behind the terminals: much softer
/// than the label it hangs from, and one gradient for all of them.
///
/// The icon's violet is dark: it needs full strength to show on a dark window, where the system
/// colors need a third of it, and a lighter tint of its hue on a light one.
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
    var shape: Shape = .strip
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = look
        switch shape {
        case .strip:
            LinearGradient(
                colors: [look.base.opacity(look.lead), look.base.opacity(look.tail)],
                startPoint: .leading, endPoint: .trailing)
        case .body(let row, let count):
            let edge = ProjectWash.slice(row: row, of: count, lead: look.lead, tail: look.tail)
            LinearGradient(
                colors: [look.base.opacity(edge.top), look.base.opacity(edge.bottom)],
                startPoint: .top, endPoint: .bottom)
                // The label fades out sideways; so does what hangs from it.
                .mask(LinearGradient(
                    colors: [.black, .black.opacity(ProjectWash.sideFade)],
                    startPoint: .leading, endPoint: .trailing))
                .clipShape(ProjectWash.outline(row: row, of: count))
                .padding(.leading, ProjectWash.leadingInset)
                .padding(.trailing, ProjectWash.trailingInset)
        }
    }

    private var isStrip: Bool {
        if case .strip = shape { return true }
        return false
    }

    private var look: (base: Color, lead: Double, tail: Double) {
        switch (color.color, scheme) {
        case (.some(let chosen), _):
            return (chosen, isStrip ? 0.34 : 0.12, isStrip ? 0.05 : 0.03)
        case (.none, .dark):
            return (.planchettePurple, isStrip ? 1.0 : 0.34, isStrip ? 0.12 : 0.07)
        case (.none, _):
            return (.planchettePurpleLight, isStrip ? 0.5 : 0.18, isStrip ? 0.06 : 0.04)
        }
    }
}

/// What it takes to draw one gradient over several rows of a list, each of which paints its own
/// background: every row gets the part of the fade that lies at its place, so a row ends exactly as
/// strong as the next one starts. (A background put on the project's `DisclosureGroup` instead is
/// handed to every row of it, and each one then runs the whole fade — a band per terminal.)
enum ProjectWash {
    /// How strong the fade is at the top and at the bottom of row `row` of `count`: one straight line
    /// from `lead`, at the top of the first row, to `tail`, at the bottom of the last, cut in equal
    /// parts. Rows are not all equally tall, so the slope varies a little from row to row — the
    /// strength never jumps, which is what makes it read as one.
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

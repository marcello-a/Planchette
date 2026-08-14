import AppKit
import SwiftUI

/// Pixel-art sprites for the five attention states — the one place their shape
/// is defined, for the sidebar, the tabs, the panels and the menu bar.
///
/// The visual language is Claude's own: the spark (`✳`) it prints while it
/// works, drawn as pixels. Idle is a dim ember of it, a question opens the
/// spark up, and a running turn is a little robot with its legs actually
/// moving — the one state where "something is happening right now" is the whole
/// message, and a still picture cannot say it. The two verdicts speak plainer
/// than the spark: a finished turn is a thumbs-up, an error is a sad face cut
/// out of a filled block — the one sprite drawn in negative, so the red reads
/// as a solid warning even at 11pt.
///
/// Shape carries the state, not just colour: an 8×8 sprite is legible at 11pt,
/// tells red from blue for anyone who cannot, and survives the menu bar, where a
/// tinted SF Symbol would be flattened to a template. Hand-plotted rather than
/// scaled from a font, so the pixels land on whole device pixels at 1× and 2×.
enum StatePixels {
    static let size = 8

    /// Seconds per frame for the states that move.
    static let frameDuration = 0.18

    /// Every frame of a state, `#` on and anything else off, row 0 at the top.
    /// One frame for the still states; the robot cycles through four.
    static func frames(_ state: AttentionState) -> [[String]] {
        switch state {
        // free — a dim ember of the spark: lit, but nothing going on.
        case .free: [[
            "........",
            "........",
            "...##...",
            "..####..",
            "..####..",
            "...##...",
            "........",
            "........",
        ]]

        // running — a robot mid-stride. Head and body hold still, the arms and
        // legs carry the motion, so the sprite reads as one thing that moves
        // rather than four different pictures.
        case .running: [
            [
                "..#..#..",
                ".######.",
                ".#.##.#.",
                "#.####..",
                "#.####.#",
                "..####..",
                "..##.#..",
                ".##...#.",
            ],
            [
                "..#..#..",
                ".######.",
                ".#.##.#.",
                "..####.#",
                "#.####.#",
                "..####..",
                "..#..#..",
                "..#..#..",
            ],
            [
                "..#..#..",
                ".######.",
                ".#.##.#.",
                "..####.#",
                "#.####..",
                "..####..",
                "..#.##..",
                ".#...##.",
            ],
            [
                "..#..#..",
                ".######.",
                ".#.##.#.",
                "#.####..",
                "#.####.#",
                "..####..",
                "..#..#..",
                "..#..#..",
            ],
        ]

        // waiting — the spark, opened into a question.
        case .waiting: [[
            ".######.",
            "##....##",
            "#.....##",
            "....###.",
            "...##...",
            "...##...",
            "........",
            "...##...",
        ]]

        // ready — a check mark, drawn with the same two-pixel stroke as the
        // question mark, so the pair reads as one family: asked, answered.
        case .ready: [[
            "........",
            "......##",
            ".....##.",
            "#...##..",
            "##.##...",
            ".####...",
            "..##....",
            "........",
        ]]

        // error — a sad face, drawn in NEGATIVE: the block is lit (red), the
        // eyes and the down-turned mouth are the holes. The only inverse
        // sprite — a solid red block is the loudest thing an 8×8 can say.
        case .error: [[
            ".######.",
            "########",
            "##.##.##",
            "########",
            "########",
            "###..###",
            "##.##.##",
            ".######.",
        ]]
        }
    }

    static func sprite(_ state: AttentionState, frame: Int = 0) -> [String] {
        let all = frames(state)
        return all[frame % all.count]
    }

    /// Whether this state's sprite moves.
    static func isAnimated(_ state: AttentionState) -> Bool { frames(state).count > 1 }

    /// The lit pixels as grid positions, so both renderers share one geometry.
    static func cells(_ state: AttentionState, frame: Int = 0) -> [(x: Int, y: Int)] {
        sprite(state, frame: frame).enumerated().flatMap { y, row in
            row.enumerated().compactMap { x, char in char == "#" ? (x, y) : nil }
        }
    }

    /// The sprite as an image for AppKit surfaces (the menu bar). Not a template
    /// image: the state colour is the other half of the information. Still — a
    /// status item redrawn four times a second would be a battery bug, not a
    /// feature.
    @MainActor
    static func nsImage(_ state: AttentionState, pointSize: CGFloat = 13) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
            let pixel = pointSize / CGFloat(size)
            NSColor(state.tint).setFill()
            for cell in cells(state) {
                NSRect(x: CGFloat(cell.x) * pixel, y: CGFloat(cell.y) * pixel,
                       width: pixel, height: pixel).fill()
            }
            return true
        }
        image.accessibilityDescription = state.label
        return image
    }
}

/// Pixel sprites that are not states but sit beside them, so the sidebar does
/// not mix pixel art with vector glyphs.
enum PixelSprites {
    /// The favourite ("main project") mark: a four-point spark, symmetric on
    /// both axes. A five-pointed star cannot be even on an 8x8 grid — one arm
    /// always lands off-centre and the whole thing reads as a blob with legs.
    static let star = [
        "...##...",
        "...##...",
        "..####..",
        "########",
        "########",
        "..####..",
        "...##...",
        "...##...",
    ]
}

/// Any 8x8 sprite, in one colour. `StateIcon` is the state-aware wrapper.
struct PixelIcon: View {
    let sprite: [String]
    var size: CGFloat = 11
    var tint: Color = .primary

    var body: some View {
        Canvas { context, _ in
            let pixel = size / CGFloat(StatePixels.size)
            for (y, row) in sprite.enumerated() {
                for (x, char) in row.enumerated() where char == "#" {
                    context.fill(
                        Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                    width: pixel, height: pixel)),
                        with: .color(tint))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// A state as a pixel sprite, tinted by the state itself. Animated states run
/// off a shared timeline, so every robot on screen steps in time and no view
/// holds a timer of its own.
struct StateIcon: View {
    let state: AttentionState
    var size: CGFloat = 13
    /// Overrides the state's own colour.
    var tint: Color?

    var body: some View {
        if StatePixels.isAnimated(state) {
            TimelineView(.periodic(from: .now, by: StatePixels.frameDuration)) { context in
                sprite(frame: Int(context.date.timeIntervalSinceReferenceDate
                    / StatePixels.frameDuration))
            }
        } else {
            sprite(frame: 0)
        }
    }

    private func sprite(frame: Int) -> some View {
        Canvas { context, _ in
            let pixel = size / CGFloat(StatePixels.size)
            let color = tint ?? state.tint
            for cell in StatePixels.cells(state, frame: frame) {
                let rect = CGRect(x: CGFloat(cell.x) * pixel, y: CGFloat(cell.y) * pixel,
                                  width: pixel, height: pixel)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.label)
        .help(state.label)
    }
}

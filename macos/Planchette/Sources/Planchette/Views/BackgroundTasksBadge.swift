import SwiftUI

/// The symbol for "this terminal runs something in the background", in the same
/// pixel art as the state icon it sits under.
///
/// One task is a terminal window with a prompt (`>_`); from two on, the window
/// holds the number instead — the count lives in the symbol, not beside it, so
/// the badge keeps one footprint however many tasks there are. Two digits make
/// the window wider, never taller.
enum BackgroundTaskSprite {
    static let height = 9

    /// A terminal window with a prompt: `>_`.
    static let prompt = [
        ".#######.",
        "#.......#",
        "#.#.....#",
        "#..#....#",
        "#...#...#",
        "#..#....#",
        "#.#..##.#",
        "#.......#",
        ".#######.",
    ]

    /// Digits, 3 pixels wide and 5 tall — the smallest size that stays legible.
    private static let digits: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"],
        "3": ["###", "..#", "###", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", ".#.", ".#.", ".#."],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "###"],
    ]

    /// Beyond this the window would outgrow the row; nobody reads a count of a
    /// hundred background tasks as anything but "a lot".
    static let largestCount = 99

    /// The sprite for `count` tasks, row 0 at the top, `#` lit.
    static func rows(count: Int) -> [String] {
        guard count > 1 else { return prompt }
        let glyphs = String(min(count, largestCount)).compactMap { digits[$0] }
        let textWidth = glyphs.count * 3 + (glyphs.count - 1)
        // Border and one pixel of air on each side of the digits; never narrower
        // than the prompt window, so a single digit does not shrink the badge.
        let width = max(prompt[0].count, textWidth + 4)
        let left = (width - textWidth) / 2
        var grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
        for x in 1..<(width - 1) {
            grid[0][x] = "#"
            grid[height - 1][x] = "#"
        }
        for y in 1..<(height - 1) {
            grid[y][0] = "#"
            grid[y][width - 1] = "#"
        }
        for (index, glyph) in glyphs.enumerated() {
            for (dy, row) in glyph.enumerated() {
                for (dx, char) in row.enumerated() where char == "#" {
                    grid[2 + dy][left + index * 4 + dx] = "#"
                }
            }
        }
        return grid.map { String($0) }
    }
}

/// The badge under a terminal's state icon: what runs in the background, as a
/// symbol and — from two on — a number. What exactly runs is on hover.
struct BackgroundTasksBadge: View {
    let tasks: [BackgroundTask]
    /// Points per sprite pixel.
    var pixel: CGFloat = 1.25
    var tint: Color = .secondary

    var body: some View {
        let rows = BackgroundTaskSprite.rows(count: tasks.count)
        let tooltip = BackgroundTasks.tooltip(for: tasks)
        Canvas { context, _ in
            // One path, one fill: neighbouring pixels filled one by one leave a
            // faint seam wherever the pixel size is not a whole device pixel.
            var path = Path()
            for (y, row) in rows.enumerated() {
                for (x, char) in row.enumerated() where char == "#" {
                    path.addRect(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                        width: pixel, height: pixel))
                }
            }
            context.fill(path, with: .color(tint))
        }
        .frame(width: CGFloat(rows[0].count) * pixel, height: CGFloat(rows.count) * pixel)
        .accessibilityElement()
        .accessibilityLabel(tooltip)
        .help(tooltip)
    }
}

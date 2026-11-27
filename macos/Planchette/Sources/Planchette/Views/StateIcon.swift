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

    /// A globe, for a terminal whose turn is over and whose Claude still runs a shell or an agent
    /// in the background (a dev server, a review agent): purple like `running`, because it is,
    /// but not the robot, because nothing is being done *to you* right now — it is a place
    /// something runs. Still, unlike the robot: a dev server is there for days, and a hundred
    /// turning globes would cost what the animation guard of `StateIcon` exists to save.
    ///
    /// 13×13, not the states' 8×8: a globe is lines — a ring, a meridian, an equator, two
    /// latitudes — and at 8 pixels the lines are as thick as the gaps and it turns into a blob.
    /// At the default 13 pt every pixel is one point.
    static let globe = [
        "....#####....",
        "..###...###..",
        ".##.#...#.##.",
        ".###########.",
        "#..#.....#..#",
        "#..#.....#..#",
        "#############",
        "#..#.....#..#",
        "#..#.....#..#",
        ".###########.",
        ".##.#...#.##.",
        "..###...###..",
        "....#####....",
    ]

    /// `zZ`, a Claude that Planchette put to sleep because its terminal sat idle (`ClaudeSleep`).
    /// Opening the terminal wakes it.
    static let asleep = [
        "........",
        "....####",
        "......#.",
        ".####.#.",
        "...#####",
        "..#.....",
        ".####...",
        "........",
    ]

    /// A database, for a terminal that runs a database client or a tunnel to one
    /// (`AppState.showsDatabaseMark`).
    static let database = [
        "..####..",
        ".#....#.",
        ".######.",
        ".#....#.",
        ".######.",
        ".#....#.",
        "..####..",
        "........",
    ]

    /// `>_`, a shell prompt, for a free terminal with no agent in it (`AppState.showsShellMark`):
    /// the free dot says "Claude is idle here", and a plain shell is not an idle Claude.
    static let shell = [
        "........",
        ".#......",
        "..#.....",
        "...#....",
        "..#.....",
        ".#......",
        "....####",
        "........",
    ]

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

    /// Images built once per (state, size) — the menu bar re-evaluates its label
    /// on every state change, and allocating a fresh NSImage each time was pure
    /// churn. Safe to cache across appearance changes: the drawing handler runs
    /// at draw time, so the colour resolves against the current appearance.
    @MainActor
    private static var imageCache: [String: NSImage] = [:]

    /// The sprite as an image for AppKit surfaces (the menu bar). Not a template
    /// image: the state colour is the other half of the information. Still — a
    /// status item redrawn four times a second would be a battery bug, not a
    /// feature.
    @MainActor
    static func nsImage(_ state: AttentionState, pointSize: CGFloat = 13) -> NSImage {
        let key = "\(state.rawValue)-\(pointSize)"
        if let cached = imageCache[key] { return cached }
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
        imageCache[key] = image
        return image
    }
}

/// Pixel sprites that are not states but sit beside them, so the sidebar does
/// not mix pixel art with vector glyphs.
enum PixelSprites {
    /// The favourite ("main project") mark: a solid five-point star — filled,
    /// no outline and no face, because at this size an outline eats the fill and
    /// a face turns to noise.
    ///
    /// 14x14, not the states' 8x8: five points do not divide into eight, and a
    /// polygon rasterised smaller than this loses its legs to single pixels that
    /// disappear on screen. The legs here are deliberately thicker than a true
    /// polygon would make them, which is what every hand-drawn pixel star does.
    static let star = [
        "..............",
        "......##......",
        ".....####.....",
        ".....####.....",
        "##############",
        ".############.",
        "..##########..",
        "...########...",
        "...########...",
        "..####..####..",
        "..###....###..",
        ".###......###.",
        ".##........##.",
        "..............",
    ]
}

/// Any square pixel sprite, in one colour. `StateIcon` is the state-aware
/// wrapper; the grid comes from the sprite, so a shape that needs more room
/// than the states' 8x8 can have it without changing on-screen size.
struct PixelIcon: View {
    let sprite: [String]
    var size: CGFloat = 11
    var tint: Color = .primary

    var body: some View {
        Canvas { context, _ in
            let grid = max(sprite.count, sprite.first?.count ?? StatePixels.size)
            let pixel = size / CGFloat(grid)
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

/// Whether the app is frontmost, as an observable — so views can stop work
/// nobody can see. Its one consumer is the sprite animation below.
@MainActor
final class AppActivity: ObservableObject {
    static let shared = AppActivity()
    @Published private(set) var isActive: Bool

    private init() {
        isActive = NSApp?.isActive ?? true
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = true }
        }
        center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = false }
        }
    }
}

/// A state as a pixel sprite, tinted by the state itself. Animated states run
/// in Core Animation (`AnimatedSprite`), so every robot on screen steps in time,
/// no view holds a timer of its own and a frame step costs SwiftUI nothing.
///
/// The animation stops while the app is in the background: a still sprite
/// stands in, and nothing runs while nobody is looking.
struct StateIcon: View {
    let state: AttentionState
    var size: CGFloat = 13
    /// Overrides the state's own colour.
    var tint: Color?
    /// The globe in place of the robot: the turn is over and only background work runs. Only
    /// meaningful for `running`; it keeps the running colour and does not move.
    var inBackground = false
    /// `>_` in place of the free dot (a plain shell, no agent in it) or of the robot (a program
    /// runs in front of the shell). Only meaningful for `free` and `running`.
    var shell = false
    /// `zZ`: its Claude sleeps (`ClaudeSleep`). Wins over `shell`, in the free colour.
    var asleep = false
    /// The database in place of the robot: a database client or a tunnel to one runs in front.
    /// Only meaningful for `running`.
    var database = false

    @ObservedObject private var activity = AppActivity.shared

    var body: some View {
        if inBackground {
            PixelIcon(sprite: StatePixels.globe, size: size, tint: tint ?? state.tint)
                .accessibilityLabel(L10n.t(.stateBackground))
                .help(L10n.t(.stateBackground))
        } else if asleep {
            PixelIcon(sprite: StatePixels.asleep, size: size, tint: tint ?? AttentionState.free.tint)
                .accessibilityLabel(L10n.t(.stateAsleep))
                .help(L10n.t(.stateAsleep))
        } else if database && state == .running {
            PixelIcon(sprite: StatePixels.database, size: size, tint: tint ?? state.tint)
                .accessibilityLabel(L10n.t(.stateDatabase))
                .help(L10n.t(.stateDatabase))
        } else if shell && (state == .free || state == .running) {
            PixelIcon(sprite: StatePixels.shell, size: size, tint: tint ?? state.tint)
                .accessibilityLabel(L10n.t(state == .free ? .stateShell : .stateProgram))
                .help(L10n.t(state == .free ? .stateShell : .stateProgram))
        } else {
            animatedOrStill
        }
    }

    private var animatedOrStill: some View {
        Group {
            // A static sprite while the app is in the background — nothing ticks.
            // In front the frames run in Core Animation (`AnimatedSprite`): a
            // SwiftUI timeline invalidated the hosting view on every frame, and
            // each tick escalated into a layout pass of the whole window — about
            // a quarter of a core with three robots on screen.
            if StatePixels.isAnimated(state) && activity.isActive {
                AnimatedSprite(state: state, size: size, tint: tint ?? state.tint)
                    .frame(width: size, height: size)
            } else {
                sprite(frame: 0)
            }
        }
        .accessibilityLabel(state.label)
        .help(state.label)
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
    }
}

/// A terminal's state as its row, tab or tile draws it: the sprite of its state — and the globe in
/// place of the robot while its turn is over and only its background work runs
/// (`AppState.runsInBackground`). One view for every place that draws a session, so none of them
/// can forget it.
struct SessionStateIcon: View {
    @EnvironmentObject var appState: AppState
    let session: TerminalSession
    var size: CGFloat = 13
    /// Draw `>_` for a plain shell (`AppState.showsShellMark`) — where a tab draws it.
    var marksShell = false

    var body: some View {
        StateIcon(state: session.state, size: size, inBackground: appState.runsInBackground(session),
                  shell: appState.showsProgramMark(session) || (marksShell && appState.showsShellMark(session)),
                  asleep: session.state == .free && appState.isSleeping(session),
                  database: appState.showsDatabaseMark(session))
    }
}

/// An animated sprite whose frames Core Animation steps through on its own.
///
/// The frames are prerendered as 8×8 images, scaled up with nearest-neighbour
/// filtering so the pixels stay sharp, and played by a discrete keyframe
/// animation of the layer's `contents`. The render server runs it: no SwiftUI
/// update, no layout and no main-thread work per frame. Every animation takes
/// its phase from the media clock, so all sprites of a state step together.
struct AnimatedSprite: NSViewRepresentable {
    let state: AttentionState
    let size: CGFloat
    let tint: Color

    func makeNSView(context: Context) -> SpriteLayerView { SpriteLayerView() }

    func updateNSView(_ view: SpriteLayerView, context: Context) {
        view.show(state: state, tint: NSColor(tint))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpriteLayerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class SpriteLayerView: NSView {
    private var state: AttentionState?
    private var tint: NSColor?
    /// What the current images were drawn for; drawn again only when it changes.
    private var drawn: (state: AttentionState, color: CGColor)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }

    // Only a picture: a click, a drag or a hover goes to the row, tab or tile
    // around it, as it did through the Canvas this replaces.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(state: AttentionState, tint: NSColor) {
        self.state = state
        self.tint = tint
        refresh()
    }

    // The tint can be a dynamic colour: resolve it again in the new appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    // A layer leaving the window loses nothing, but one added back after
    // `removeAllAnimations` (or a fresh window) needs its animation again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawn = nil
        refresh()
    }

    private func refresh() {
        guard let layer, let state, let tint else { return }
        var color = tint.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = tint.cgColor }
        if let drawn, drawn.state == state, drawn.color == color,
           layer.animation(forKey: "frames") != nil || StatePixels.frames(state).count < 2 {
            return
        }
        drawn = (state, color)
        let images = StatePixels.frames(state).indices.compactMap {
            SpriteImages.image(state, frame: $0, color: color)
        }
        layer.removeAnimation(forKey: "frames")
        layer.contents = images.first
        guard images.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.calculationMode = .discrete
        animation.duration = Double(images.count) * StatePixels.frameDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // In step with every other sprite: the cycle position is read off the
        // media clock, the same for all of them.
        animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: animation.duration)
        layer.add(animation, forKey: "frames")
    }
}

/// The frames of a state as 8×8 images in one colour.
enum SpriteImages {
    static func image(_ state: AttentionState, frame: Int, color: CGColor) -> CGImage? {
        let side = StatePixels.size
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(color)
        for cell in StatePixels.cells(state, frame: frame) {
            // Row 0 is the top of the sprite; a bitmap context counts from the bottom.
            context.fill(CGRect(x: cell.x, y: side - 1 - cell.y, width: 1, height: 1))
        }
        return context.makeImage()
    }
}

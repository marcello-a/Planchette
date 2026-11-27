import XCTest
@testable import Planchette

final class SpriteImagesTests: XCTestCase {
    /// Lit pixels of an 8×8 image, as (x, y) with row 0 at the top — the sprite's own order.
    private func litPixels(_ image: CGImage) -> Set<String> {
        let side = StatePixels.size
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(
            data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var lit: Set<String> = []
        for row in 0..<side {
            for x in 0..<side where data[(row * side + x) * 4 + 3] > 0 {
                lit.insert("\(x),\(row)")  // memory row 0 is the top row of the image
            }
        }
        return lit
    }

    func testEveryFrameOfEveryStateDrawsExactlyItsCells() throws {
        let color = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        for state in [AttentionState.ready, .running, .waiting, .error, .free] {
            for frame in StatePixels.frames(state).indices {
                let image = try XCTUnwrap(SpriteImages.image(state, frame: frame, color: color))
                XCTAssertEqual(image.width, StatePixels.size)
                let expected = Set(StatePixels.cells(state, frame: frame).map { "\($0.x),\($0.y)" })
                XCTAssertEqual(litPixels(image), expected, "\(state) frame \(frame)")
            }
        }
    }

    func testTheRobotHasSeveralFramesToAnimate() {
        XCTAssertTrue(StatePixels.isAnimated(.running))
        XCTAssertGreaterThan(StatePixels.frames(.running).count, 1)
    }
}

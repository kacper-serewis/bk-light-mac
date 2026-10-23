import XCTest
@testable import BKLight

final class BKLightTests: XCTestCase {
    func testFrameHeaderMatchesPythonReference() {
        // 1x1 PNG from bk-light-app/python.py; header computed with bk_light build_frame().
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADklEQVR4nGP4z8DAwAAABQABf6XWDAAAAABJRU5ErkJggg==")!
        let frame = PanelProtocol.buildFrame(png: png)
        XCTAssertEqual(frame.prefix(15).map { String(format: "%02x", $0) }.joined(), "5500020000460000002d2dafec0065")
        XCTAssertEqual(frame.dropFirst(15), png)
    }

    func testClockIndex() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))! }
        XCTAssertEqual(Renderer.clockIndex(for: at(12, 0), calendar: calendar), 0)
        XCTAssertEqual(Renderer.clockIndex(for: at(0, 0), calendar: calendar), 32)
        XCTAssertEqual(Renderer.clockIndex(for: at(11, 59), calendar: calendar), 63)
    }

    func testRotationIsCounterClockwise() {
        // Mark the top-right pixel; a 90° CCW turn (PIL semantics) moves it to the top-left.
        var bitmap = Bitmap(width: 4, height: 4)
        bitmap.pixels[(0 * 4 + 3) * 4] = 255
        let rotated = bitmap.rotated(ccw: 90)
        XCTAssertEqual(rotated.pixels[0], 255)
        XCTAssertEqual(bitmap.rotated(ccw: 360), bitmap)
        XCTAssertEqual(bitmap.rotated(ccw: 90).rotated(ccw: 270), bitmap)
    }

    func testSlicesProduceOnePNGPerPanel() throws {
        let sheet = try XCTUnwrap(Renderer.spriteSheet)
        XCTAssertEqual(sheet.width, 128)
        let canvas = Renderer.clock(index: 10, size: 64)
        let panels = Slot.allCases.map { PanelConfig(id: UUID(), name: "p\($0.rawValue)", slot: $0, rotation: $0.defaultRotation) }
        let slices = Renderer.slices(canvas: canvas, panels: panels, layout: .tiled, brightness: 1)
        XCTAssertEqual(slices.count, 4)
        for png in slices.values {
            let image = try XCTUnwrap(CGImage.decode(png))
            XCTAssertEqual(image.width, 32)
            print("tile png bytes:", png.count)
        }
    }

    func testCoverTileSize() throws {
        // Worst case: a photo-like noise image, to see how big a tile PNG gets vs. the 512 B ATT limit.
        var noise = Bitmap(width: 64, height: 64)
        for i in 0..<noise.pixels.count where i % 4 != 3 { noise.pixels[i] = UInt8.random(in: 0...255) }
        let png = try XCTUnwrap(noise.crop(x: 0, y: 0, width: 32, height: 32).pngData())
        print("noise tile png bytes:", png.count)
    }
}

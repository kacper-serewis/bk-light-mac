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

    func testAveragedAndBilinear() {
        // Left half red, right half blue → 2×1 average is pure red / pure blue.
        var bitmap = Bitmap(width: 4, height: 2)
        for y in 0..<2 { for x in 0..<4 { bitmap.pixels[(y * 4 + x) * 4 + (x < 2 ? 0 : 2)] = 255 } }
        let averaged = bitmap.averaged(width: 2, height: 1)
        XCTAssertEqual(Array(averaged.pixels[0..<3]), [255, 0, 0])
        XCTAssertEqual(Array(averaged.pixels[4..<7]), [0, 0, 255])

        // Upscaling keeps the corners and blends in between.
        let wide = averaged.resizedBilinear(width: 8, height: 1)
        XCTAssertEqual(Array(wide.pixels[0..<3]), [255, 0, 0])
        XCTAssertEqual(Array(wide.pixels[28..<31]), [0, 0, 255])
        XCTAssertTrue((1...254).contains(wide.pixels[3 * 4]))
    }

    func testMeanDifferenceAndSaturation() {
        var a = Bitmap(width: 2, height: 2)
        let b = a
        XCTAssertEqual(a.meanDifference(to: b), 0)
        a.pixels[0] = 120
        XCTAssertEqual(a.meanDifference(to: b), 10)
        XCTAssertEqual(a.meanDifference(to: Bitmap(width: 1, height: 1)), .infinity)

        var gray = Bitmap(width: 1, height: 1)
        gray.pixels[0...2] = [100, 100, 100]
        XCTAssertEqual(gray.saturated(by: 2), gray)
    }

    func testScreenRenderSizes() {
        let capture = Bitmap(width: 128, height: 80)
        for style in ScreenStyle.allCases {
            XCTAssertEqual(Renderer.screen(capture, style: style, size: 64).width, 64)
            XCTAssertEqual(Renderer.screen(capture, style: style, size: 32).height, 32)
        }
    }

    func testOldSettingsStillDecode() throws {
        // Saved by the version before ambilight: no screenStyle key.
        let id = UUID()
        let json = """
            {"panels":[{"id":"\(id.uuidString)","name":"LED_BLE_1","slot":1,"rotation":270}],
             "layout":"tiled","source":"spotifyApp","mode":"clockOnly","brightness":0.5,
             "dynamicBrightness":false,"haBaseURL":"","haEntityID":"media_player.x","idleGrace":7}
            """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.panels.first?.id, id)
        XCTAssertEqual(settings.mode, .clockOnly)
        XCTAssertEqual(settings.idleGrace, 7)
        XCTAssertEqual(settings.screenStyle, .glow)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip, settings)
    }
}

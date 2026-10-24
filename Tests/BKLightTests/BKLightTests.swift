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

    func testNightSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))! }
        var settings = AppSettings()
        XCTAssertFalse(settings.isNight(at: at(3, 0), calendar: calendar))   // disabled by default
        settings.nightEnabled = true
        settings.nightStart = 23 * 60
        settings.nightEnd = 7 * 60                                           // wraps past midnight
        XCTAssertTrue(settings.isNight(at: at(23, 0), calendar: calendar))
        XCTAssertTrue(settings.isNight(at: at(3, 0), calendar: calendar))
        XCTAssertFalse(settings.isNight(at: at(7, 0), calendar: calendar))
        XCTAssertFalse(settings.isNight(at: at(12, 0), calendar: calendar))
        settings.nightStart = 60
        settings.nightEnd = 6 * 60                                           // same day
        XCTAssertTrue(settings.isNight(at: at(1, 0), calendar: calendar))
        XCTAssertFalse(settings.isNight(at: at(0, 30), calendar: calendar))
    }

    func testRuleSettingsDefaultsAndOrderRepair() throws {
        // Before the rules existed: automatic mode meant cover art, then the clock.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"mode":"auto","source":"spotifyApp"}"#.utf8))
        XCTAssertEqual(old.source, .spotifyApp)
        XCTAssertEqual(old.activeEnabled, [.music])
        XCTAssertEqual(old.idleScreens, [.clock])
        XCTAssertEqual(old.activeOrder, ActiveSource.allCases)

        let repaired = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"activeOrder":["screen","screen"]}"#.utf8))
        XCTAssertEqual(repaired.activeOrder, [.screen] + ActiveSource.allCases.filter { $0 != .screen })
        XCTAssertEqual(AppSettings().source, .system)
    }

    func testPixelFont() {
        XCTAssertEqual(PixelFont.width(of: "12"), 7)
        XCTAssertEqual(PixelFont.width(of: "12", scale: 3), 21)
        XCTAssertEqual(PixelFont.width(of: "é"), PixelFont.width(of: "E"))
        var bitmap = Bitmap(width: 8, height: 8)
        bitmap.text("1", x: 0, y: 0, .white)
        XCTAssertEqual(bitmap.pixels[(0 * 8 + 1) * 4], 255)   // top of the "1"
        XCTAssertEqual(bitmap.pixels[(0 * 8 + 0) * 4], 0)
    }

    @MainActor
    func testSystemMonitorSamples() {
        let monitor = SystemMonitor()
        monitor.sample()
        monitor.sample()
        let snapshot = monitor.snapshot
        XCTAssertTrue((0...1).contains(snapshot.memory))
        XCTAssertTrue((0...1).contains(snapshot.disk))
        XCTAssertTrue((0...1).contains(snapshot.cpu))
        XCTAssertEqual(monitor.generation, 2)
    }

    func testWeatherKinds() {
        XCTAssertEqual(Renderer.weatherKind(code: 0), .clear)
        XCTAssertEqual(Renderer.weatherKind(code: 61), .rain)
        XCTAssertEqual(Renderer.weatherKind(code: 75), .snow)
        XCTAssertEqual(Renderer.weatherKind(code: 96), .thunder)
        XCTAssertEqual(Renderer.weather(WeatherReport(temperature: 5, code: 2, isDay: true, high: 8, low: 1), size: 32).width, 32)
    }

    private func haStates(_ json: String) -> [String: HAState] {
        HomeAssistant.parseStates(Data(json.utf8))
    }

    func testHomeAssistantDiscovery() {
        let states = haStates("""
            [{"entity_id":"sensor.a1_print_status","state":"running","attributes":{},"last_changed":"2026-10-24T10:00:00.123+00:00"},
             {"entity_id":"sensor.a1_print_progress","state":"57","attributes":{}},
             {"entity_id":"sensor.a1_remaining_time","state":"1.5","attributes":{}},
             {"entity_id":"image.a1_cover_image","state":"2026","attributes":{"entity_picture":"/api/image_proxy/image.a1_cover_image?token=x"}},
             {"entity_id":"sensor.washer_machine_state","state":"run","attributes":{"options":["pause","run","stop"]}},
             {"entity_id":"sensor.washer_job_state","state":"rinse","attributes":{}},
             {"entity_id":"sensor.washer_completion_time","state":"2026-10-24T11:00:00+00:00","attributes":{}},
             {"entity_id":"sensor.p1_meter_power","state":"435.0","attributes":{}},
             {"entity_id":"climate.thermo","state":"heat","attributes":{"current_temperature":18.8,"temperature":19,"hvac_action":"heating"}},
             {"entity_id":"sensor.thermo_humidity","state":"58.96","attributes":{}}]
            """)
        let printer = HomeAssistant.printer(in: states)
        XCTAssertEqual(printer?.status, "running")
        XCTAssertEqual(printer?.progress ?? 0, 0.57, accuracy: 0.001)
        XCTAssertEqual(printer?.remainingMinutes, 90)
        XCTAssertEqual(printer?.coverPath, "/api/image_proxy/image.a1_cover_image?token=x")
        XCTAssertEqual(printer?.changedAt, HomeAssistant.timestamp("2026-10-24T10:00:00.123+00:00"))

        let washer = HomeAssistant.washer(in: states)
        XCTAssertEqual(washer?.job, "rinse")
        XCTAssertEqual(washer.map { Renderer.washerPhase($0) }, "SPOELEN")

        let home = HomeAssistant.home(in: states)
        XCTAssertEqual(home.power, 435)
        XCTAssertEqual(home.indoor, 18.8)
        XCTAssertEqual(home.target, 19)
        XCTAssertEqual(home.humidity, 58.96)
        XCTAssertTrue(home.heating)
        XCTAssertEqual(Renderer.duration(minutes: 65), "1:05")
    }

    func testWhenHomeAssistantScreensShow() {
        let now = Date()
        var printer = HomeAssistant.Printer(status: "finish", progress: 1, remainingMinutes: 0, coverPath: nil, changedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(printer.isShown(at: now))
        printer.changedAt = now.addingTimeInterval(-3600)
        XCTAssertFalse(printer.isShown(at: now))
        printer.status = "idle"
        XCTAssertFalse(printer.isShown(at: now))

        var washer = HomeAssistant.Washer(state: "stop", job: "none", completion: now.addingTimeInterval(-10 * 60))
        XCTAssertTrue(washer.isShown(at: now))
        XCTAssertTrue(washer.isDone(at: now))
        washer.completion = now.addingTimeInterval(-2 * 3600)
        XCTAssertFalse(washer.isShown(at: now))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: h))! }
        let states = haStates("""
            [{"entity_id":"sensor.afvalbeheer_app_morgen","state":"GFT, PBD","attributes":{}},
             {"entity_id":"sensor.afvalbeheer_app_vandaag","state":"Papier","attributes":{}}]
            """)
        XCTAssertEqual(HomeAssistant.bins(in: states, at: at(8), calendar: calendar), HomeAssistant.Bins(types: ["Papier"], tomorrow: false))
        XCTAssertNil(HomeAssistant.bins(in: states, at: at(14), calendar: calendar))
        XCTAssertEqual(HomeAssistant.bins(in: states, at: at(19), calendar: calendar), HomeAssistant.Bins(types: ["GFT", "PBD"], tomorrow: true))
        let none = haStates(#"[{"entity_id":"sensor.afvalbeheer_app_morgen","state":"Geen","attributes":{}}]"#)
        XCTAssertNil(HomeAssistant.bins(in: none, at: at(19), calendar: calendar))
    }

    func testLifeGliderMoves() {
        // A glider comes back to its own shape one cell down-right every 4 generations.
        let glider = [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)]
        var grid = LifeGrid(width: 8, height: 8, alive: glider)
        for _ in 0..<4 { grid.step() }
        XCTAssertEqual(grid.population, 5)
        for (x, y) in glider { XCTAssertTrue(grid.isAlive(x + 1, y + 1)) }
        XCTAssertEqual(Renderer.life(grid).width, 8)
    }
}

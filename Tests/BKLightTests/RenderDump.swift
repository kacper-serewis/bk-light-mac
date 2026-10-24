import XCTest
@testable import BKLight

/// Writes sample canvases to $BKLIGHT_DUMP for eyeballing. Skipped unless the variable is set.
final class RenderDump: XCTestCase {
    func testDump() throws {
        guard let dir = ProcessInfo.processInfo.environment["BKLIGHT_DUMP"] else { throw XCTSkip("BKLIGHT_DUMP not set") }
        let url = URL(fileURLWithPath: dir)
        try Renderer.clock(index: 40, size: 64).pngData()!.write(to: url.appendingPathComponent("clock.png"))
        try Renderer.identifyPattern(size: 64, tiled: true).pngData()!.write(to: url.appendingPathComponent("identify.png"))
        let panels = Slot.allCases.map { PanelConfig(id: UUID(), name: "", slot: $0, rotation: $0.defaultRotation) }
        for (panel, png) in zip(panels, panels.map { Renderer.slices(canvas: Renderer.identifyPattern(size: 64, tiled: true), panels: [$0], layout: .tiled, brightness: 1)[$0.id]! }) {
            try png.write(to: url.appendingPathComponent("tile-\(panel.slot.rawValue + 1).png"))
        }
        for (name, code, isDay) in [("clear", 0, true), ("night", 0, false), ("partly", 2, true), ("cloudy", 3, true),
                                    ("fog", 45, true), ("rain", 63, true), ("snow", 73, true), ("thunder", 95, true)] {
            let report = WeatherReport(temperature: -3.4, code: code, isDay: isDay, high: 12, low: -5)
            try Renderer.weather(report, size: 64).pngData()!.write(to: url.appendingPathComponent("weather-\(name).png"))
            try Renderer.weather(report, size: 32).pngData()!.write(to: url.appendingPathComponent("weather32-\(name).png"))
        }
        let snapshot = SystemSnapshot(cpu: 0.23, memory: 0.71, battery: 0.12, charging: false, disk: 0.5,
                                      cpuHistory: (0..<60).map { 0.5 + 0.45 * sin(Double($0) / 6) })
        try Renderer.systemStatus(snapshot, size: 64).pngData()!.write(to: url.appendingPathComponent("system.png"))
        try Renderer.systemStatus(snapshot, size: 32).pngData()!.write(to: url.appendingPathComponent("system32.png"))
        let now = Date()
        let printer = HomeAssistant.Printer(status: "running", progress: 0.57, remainingMinutes: 83, coverPath: nil, changedAt: now)
        try Renderer.printer(printer, cover: nil, size: 64).pngData()!.write(to: url.appendingPathComponent("printer.png"))
        try Renderer.printer(printer, cover: Renderer.spriteSheet, size: 64).pngData()!.write(to: url.appendingPathComponent("printer-cover.png"))
        let washer = HomeAssistant.Washer(state: "run", job: "rinse", completion: now.addingTimeInterval(42 * 60))
        try Renderer.washer(washer, now: now, size: 64).pngData()!.write(to: url.appendingPathComponent("washer.png"))
        try Renderer.washer(HomeAssistant.Washer(state: "stop", job: "none", completion: now.addingTimeInterval(-60)), now: now, size: 64)
            .pngData()!.write(to: url.appendingPathComponent("washer-done.png"))
        try Renderer.bins(HomeAssistant.Bins(types: ["PBD"], tomorrow: true), size: 64).pngData()!.write(to: url.appendingPathComponent("bins.png"))
        try Renderer.bins(HomeAssistant.Bins(types: ["GFT", "Papier"], tomorrow: false), size: 64).pngData()!.write(to: url.appendingPathComponent("bins-two.png"))
        let history = (0..<60).map { 400 + 300 * sin(Double($0) / 5) + ($0 > 40 ? 1800 : 0) }
        let home = HomeAssistant.Home(power: 435, indoor: 18.8, target: 19, humidity: 59, heating: true)
        try Renderer.home(home, powerHistory: history, size: 64).pngData()!.write(to: url.appendingPathComponent("home.png"))
        var life = LifeGrid(width: 64, height: 64)
        for _ in 0..<20 { life.step() }
        try Renderer.life(life).pngData()!.write(to: url.appendingPathComponent("life.png"))
        try Renderer.printer(printer, cover: nil, size: 32).pngData()!.write(to: url.appendingPathComponent("printer32.png"))
        try Renderer.washer(washer, now: now, size: 32).pngData()!.write(to: url.appendingPathComponent("washer32.png"))
        try Renderer.bins(HomeAssistant.Bins(types: ["PBD"], tomorrow: true), size: 32).pngData()!.write(to: url.appendingPathComponent("bins32.png"))
        try Renderer.home(home, powerHistory: history, size: 32).pngData()!.write(to: url.appendingPathComponent("home32.png"))
        // Optional: BKLIGHT_HASS=/path/to/states.json renders the Home screen from real Home Assistant states.
        if let path = ProcessInfo.processInfo.environment["BKLIGHT_HASS"] {
            let states = HomeAssistant.parseStates(try Data(contentsOf: URL(fileURLWithPath: path)))
            print("hass home:", HomeAssistant.home(in: states), "printer:", String(describing: HomeAssistant.printer(in: states)),
                  "washer:", String(describing: HomeAssistant.washer(in: states)))
            try Renderer.home(HomeAssistant.home(in: states), powerHistory: [], size: 64).pngData()!
                .write(to: url.appendingPathComponent("home-real.png"))
        }

        // Optional: BKLIGHT_SCREEN=/path/to/screenshot.png renders both ambilight styles from it.
        if let path = ProcessInfo.processInfo.environment["BKLIGHT_SCREEN"],
           let image = try CGImage.decode(Data(contentsOf: URL(fileURLWithPath: path))) {
            let capture = Bitmap(drawing: image, width: 128, height: 128 * image.height / image.width, smooth: true)
            for style in ScreenStyle.allCases {
                let canvas = Renderer.screen(capture, style: style, size: 64)
                try canvas.pngData()!.write(to: url.appendingPathComponent("screen-\(style).png"))
                let tiles = Renderer.slices(canvas: canvas, panels: panels, layout: .tiled, brightness: 1)
                print("screen \(style) tile png bytes:", tiles.values.map(\.count).sorted())
            }
        }
    }
}

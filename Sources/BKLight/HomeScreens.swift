import CoreGraphics
import Foundation

extension Renderer {
    /// "1:05" for 65 minutes.
    static func duration(minutes: Int) -> String {
        let m = max(0, minutes)
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    // MARK: 3D printer

    /// Cover image of the model, percentage, time left and a progress bar; "DONE"/"FAIL" afterwards.
    static func printer(_ printer: HomeAssistant.Printer, cover: CGImage?, size: Int) -> Bitmap {
        var b = Bitmap(width: size, height: size)
        let big = size >= 64
        let color: RGB = switch printer.status {
        case "running": .green
        case "pause": .orange
        case "finish": .cyan
        case "failed": .red
        default: .gray
        }
        let imageSize = big ? 36 : 18
        if let cover {
            b.draw(Bitmap(drawing: cover, width: imageSize, height: imageSize, smooth: true), x: (size - imageSize) / 2, y: big ? 1 : 0)
        } else {
            drawPrinterIcon(&b, x: (size - imageSize) / 2, y: big ? 1 : 0, size: imageSize)
        }

        let textY = big ? 40 : 20
        let scale = big ? 2 : 1
        switch printer.status {
        case "finish", "failed":
            b.text(printer.status == "finish" ? "DONE" : "FAIL", centeredAt: size / 2, y: textY, scale: scale, color)
        default:
            b.text("\(Int((printer.progress * 100).rounded()))%", x: big ? 2 : 1, y: textY, scale: scale, .white)
            let right = printer.status == "pause" ? "II" : printer.remainingMinutes.map { duration(minutes: $0) } ?? ""
            b.text(right, rightAt: size - (big ? 2 : 1), y: textY, scale: scale, printer.status == "pause" ? .orange : .lightGray)
        }
        let barY = big ? 55 : 27, barH = big ? 6 : 4
        let progress = printer.status == "finish" ? 1 : printer.progress
        b.fill(x: 1, y: barY, width: size - 2, height: barH, .darkGray)
        b.fill(x: 1, y: barY, width: Int(Double(size - 2) * min(1, max(0, progress))), height: barH, color)
        return b
    }

    private static func drawPrinterIcon(_ b: inout Bitmap, x: Int, y: Int, size s: Int) {
        let f = { (v: Double) in Int(v * Double(s)) }
        b.fill(x: x + f(0.1), y: y + f(0.1), width: f(0.8), height: max(1, f(0.06)), .lightGray)          // gantry
        b.fill(x: x + f(0.1), y: y + f(0.1), width: max(1, f(0.06)), height: f(0.8), .lightGray)          // frame
        b.fill(x: x + f(0.42), y: y + f(0.16), width: f(0.16), height: f(0.18), .orange)                  // print head
        b.fill(x: x + f(0.48), y: y + f(0.34), width: max(1, f(0.04)), height: f(0.06), .orange)          // nozzle
        b.fill(x: x + f(0.3), y: y + f(0.6), width: f(0.4), height: f(0.22), .cyan)                       // part
        b.fill(x: x + f(0.16), y: y + f(0.82), width: f(0.74), height: max(1, f(0.06)), .gray)           // bed
    }

    // MARK: Washing machine

    static func washer(_ washer: HomeAssistant.Washer, now: Date, size: Int) -> Bitmap {
        var b = Bitmap(width: size, height: size)
        let big = size >= 64
        let iconSize = big ? 28 : 14
        let done = washer.isDone(at: now)
        drawWasherIcon(&b, x: (size - iconSize) / 2, y: big ? 2 : 1, size: iconSize, water: done ? .green : .blue)
        if done {
            b.text("KLAAR", centeredAt: size / 2, y: big ? 38 : 19, scale: big ? 2 : 1, .green)
        } else {
            let minutes = washer.completion.map { Int(($0.timeIntervalSince(now) / 60).rounded(.up)) } ?? 0
            b.text(duration(minutes: minutes), centeredAt: size / 2 + 1, y: big ? 34 : 17, scale: big ? 3 : 2, .white)
            if big { b.text(washerPhase(washer), centeredAt: size / 2, y: 55, .lightGray) }
        }
        return b
    }

    static func washerPhase(_ washer: HomeAssistant.Washer) -> String {
        if washer.state == "pause" { return "PAUZE" }
        switch washer.job {
        case "wash", "ai_wash": return "WASSEN"
        case "pre_wash": return "VOORWAS"
        case "rinse", "ai_rinse": return "SPOELEN"
        case "spin", "ai_spin": return "CENTRIFUGE"
        case "drying": return "DROGEN"
        case "weight_sensing": return "WEGEN"
        case "delay_wash": return "UITGESTELD"
        case "finish": return "KLAAR"
        default: return washer.job.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }

    private static func drawWasherIcon(_ b: inout Bitmap, x: Int, y: Int, size s: Int, water: RGB) {
        let d = Double(s)
        b.fill(x: x, y: y, width: s, height: s, .lightGray)
        b.fill(x: x + 1, y: y + 1, width: s - 2, height: max(1, s / 7), RGB(r: 150, g: 150, b: 155))
        b.set(x + s - 3, y + 2, .red)
        let (cx, cy) = (Double(x) + d / 2, Double(y) + d * 0.6)
        b.fillCircle(cx: cx, cy: cy, r: d * 0.32, .darkGray)
        b.fillCircle(cx: cx, cy: cy, r: d * 0.25, .black)
        // Water in the lower half of the drum.
        let r = d * 0.25
        for yy in Int(cy)...Int(cy + r) {
            for xx in Int(cx - r)...Int(cx + r) {
                let dx = Double(xx) + 0.5 - cx, dy = Double(yy) + 0.5 - cy
                if dx * dx + dy * dy <= r * r { b.set(xx, yy, water) }
            }
        }
    }

    // MARK: Bins

    static func binColor(_ type: String) -> RGB {
        let t = type.lowercased()
        if t.contains("gft") || t.contains("groen") { return .green }
        if t.contains("pbd") || t.contains("pmd") || t.contains("plastic") { return .orange }
        if t.contains("papier") { return .blue }
        if t.contains("textiel") { return RGB(r: 200, g: 80, b: 200) }
        return .gray
    }

    static func bins(_ bins: HomeAssistant.Bins, size: Int) -> Bitmap {
        var b = Bitmap(width: size, height: size)
        let big = size >= 64
        let shown = Array(bins.types.prefix(2))
        let iconSize = big ? (shown.count > 1 ? 24 : 30) : (shown.count > 1 ? 13 : 16)
        let gap = big ? 4 : 2
        let total = shown.count * iconSize + (shown.count - 1) * gap
        for (i, type) in shown.enumerated() {
            drawBinIcon(&b, x: (size - total) / 2 + i * (iconSize + gap), y: big ? 2 : 0, size: iconSize, color: binColor(type))
        }
        let label = shown.joined(separator: "+").uppercased()
        let fits = PixelFont.width(of: label, scale: 2) <= size - 2
        b.text(label, centeredAt: size / 2, y: big ? 37 : 19, scale: big && fits ? 2 : 1, .white)
        b.text(bins.tomorrow ? "MORGEN" : "VANDAAG", centeredAt: size / 2, y: big ? 54 : 26, .lightGray)
        return b
    }

    private static func drawBinIcon(_ b: inout Bitmap, x: Int, y: Int, size s: Int, color: RGB) {
        let f = { (v: Double) in Int((v * Double(s)).rounded()) }
        let dark = RGB(r: color.r / 2, g: color.g / 2, b: color.b / 2)
        b.fill(x: x + f(0.08), y: y + f(0.12), width: f(0.84), height: max(1, f(0.1)), color)          // lid
        b.fill(x: x + f(0.4), y: y + f(0.04), width: f(0.2), height: max(1, f(0.08)), color)           // handle
        b.fill(x: x + f(0.14), y: y + f(0.25), width: f(0.72), height: f(0.62), color)                 // body
        for fx in [0.32, 0.5, 0.68] {                                                                  // ribs
            b.fill(x: x + f(fx) - 1, y: y + f(0.33), width: max(1, f(0.05)), height: f(0.44), dark)
        }
        b.fillCircle(cx: Double(x) + Double(s) * 0.26, cy: Double(y) + Double(s) * 0.9, r: max(1, Double(s) * 0.08), .gray)
        b.fillCircle(cx: Double(x) + Double(s) * 0.74, cy: Double(y) + Double(s) * 0.9, r: max(1, Double(s) * 0.08), .gray)
    }

    // MARK: Home

    /// Power use (with a 10-minute graph), indoor temperature and humidity.
    static func home(_ home: HomeAssistant.Home, powerHistory: [Double], size: Int) -> Bitmap {
        var b = Bitmap(width: size, height: size)
        let big = size >= 64
        func powerColor(_ watts: Double) -> RGB { watts < 0 ? .green : watts < 1000 ? .yellow : watts < 2500 ? .orange : .red }

        if let power = home.power {
            drawBolt(&b, x: 1, y: 1, size: big ? 11 : 6, color: powerColor(power))
            let text = abs(power) >= 10_000 ? String(format: "%.1fKW", power / 1000) : "\(Int(power.rounded()))W"
            b.text(text, rightAt: size - (big ? 2 : 1), y: 1, scale: big ? 2 : 1, .white)
        }

        let graphTop = big ? 15 : 8, graphHeight = big ? 24 : 10
        if !powerHistory.isEmpty {
            let peak = max(500, powerHistory.map(abs).max() ?? 0)
            let columns = big ? HomeAssistantHub.powerHistoryLength : size - 2
            let values = Array(powerHistory.suffix(columns))
            for (i, value) in values.enumerated() {
                let h = max(1, Int((abs(value) / peak * Double(graphHeight)).rounded()))
                b.fill(x: 1 + columns - values.count + i + (big ? 1 : 0), y: graphTop + graphHeight - h, width: 1, height: h, powerColor(value))
            }
        }

        let rowY = big ? 44 : 22
        if let indoor = home.indoor {
            b.text(String(format: "%.1f°", indoor), x: big ? 2 : 1, y: rowY, scale: big ? 2 : 1, home.heating ? .orange : .white)
        }
        if let humidity = home.humidity {
            b.text("\(Int(humidity.rounded()))%", rightAt: size - (big ? 2 : 1), y: rowY, scale: big ? 2 : 1, .cyan)
        }
        if big, let target = home.target {
            b.text(String(format: "SET %.1f°", target), x: 2, y: 58, .gray)
        }
        return b
    }

    private static func drawBolt(_ b: inout Bitmap, x: Int, y: Int, size s: Int, color: RGB) {
        let f = { (v: Double) in Int((v * Double(s)).rounded()) }
        let points = [(0.65, 0.0), (0.2, 0.55), (0.55, 0.55), (0.35, 1.0), (0.85, 0.4), (0.5, 0.4), (0.65, 0.0)]
        for (a, c) in zip(points, points.dropFirst()) {
            b.line(x + f(a.0), y + f(a.1), x + f(c.0), y + f(c.1), color)
        }
        b.fill(x: x + f(0.4), y: y + f(0.35), width: max(1, f(0.25)), height: max(1, f(0.25)), color)
    }
}

extension Bitmap {
    /// Copies `other` onto this bitmap with its top-left corner at (x, y).
    mutating func draw(_ other: Bitmap, x: Int, y: Int) {
        for row in 0..<other.height {
            for column in 0..<other.width {
                let i = (row * other.width + column) * 4
                set(x + column, y + row, RGB(r: other.pixels[i], g: other.pixels[i + 1], b: other.pixels[i + 2]))
            }
        }
    }
}

import AppKit
import CoreText
import Foundation

enum Renderer {
    static let spriteSheet: CGImage? = Data(base64Encoded: ClockSprite.pngBase64).flatMap(CGImage.decode)

    /// Same mapping as the Tauri app / watch_ha_media_or_clock.py: 64 frames per day, noon = frame 0.
    static func clockIndex(for date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return ((minutes + 720) % 1440) * 64 / 1440
    }

    /// Dim at night, peak mid-afternoon (from the AppBypass clock script).
    static func dynamicBrightness(for date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        let (night, peak) = (0.15, 0.85)
        let (morning, noonPeak, evening) = (7.0 * 60, 15.0 * 60, 23.0 * 60)
        if minutes < morning || minutes >= evening { return night }
        if minutes <= noonPeak { return night + (peak - night) * (minutes - morning) / (noonPeak - morning) }
        return peak - (peak - night) * (minutes - noonPeak) / (evening - noonPeak)
    }

    static func clock(index: Int, size: Int) -> Bitmap {
        guard let sheet = spriteSheet else { return Bitmap(width: size, height: size) }
        let i = max(0, min(63, index))
        let rect = CGRect(x: (i % 8) * 16, y: (i / 8) * 16, width: 16, height: 16)
        guard let sprite = sheet.cropping(to: rect) else { return Bitmap(width: size, height: size) }
        return Bitmap(drawing: sprite, width: size, height: size, smooth: false)
    }

    static func cover(_ image: CGImage, size: Int) -> Bitmap {
        Bitmap(drawing: image, width: size, height: size, smooth: true)
    }

    /// Big slot numbers on coloured quadrants with a white bar along the top edge,
    /// so you can see whether each panel sits in the right place and the right way up.
    static func identifyPattern(size: Int, tiled: Bool) -> Bitmap {
        var bitmap = Bitmap(width: size, height: size)
        let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemOrange]
        let tile = tiled ? size / 2 : size
        bitmap.withContext { ctx in
            let count = tiled ? 4 : 1
            for slot in 0..<count {
                let x = CGFloat((slot % 2) * tile)
                let yTop = CGFloat((slot / 2) * tile)
                let rect = CGRect(x: x, y: CGFloat(size) - yTop - CGFloat(tile), width: CGFloat(tile), height: CGFloat(tile))
                ctx.setFillColor(colors[slot].cgColor)
                ctx.fill(rect)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3))

                let label = tiled ? "\(slot + 1)" : "↑"
                let font = CTFontCreateWithName("Menlo-Bold" as CFString, CGFloat(tile) * 0.7, nil)
                let attributed = NSAttributedString(string: label, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                ctx.textPosition = .zero
                let bounds = CTLineGetImageBounds(line, ctx)
                ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                           y: rect.midY - bounds.height / 2 - bounds.minY - 1)
                CTLineDraw(line, ctx)
            }
        }
        return bitmap
    }

    /// Cuts the canvas into one PNG per configured panel, applying each panel's rotation.
    static func slices(canvas: Bitmap, panels: [PanelConfig], layout: Layout, brightness: Double) -> [UUID: Data] {
        let dimmed = canvas.scaled(by: brightness)
        var result: [UUID: Data] = [:]
        for panel in panels {
            let tile: Bitmap
            switch layout {
            case .tiled:
                let t = PanelProtocol.tileSize
                tile = dimmed.crop(x: panel.slot.gridX * t, y: panel.slot.gridY * t, width: t, height: t)
            case .mirrored:
                tile = dimmed
            }
            result[panel.id] = tile.rotated(ccw: panel.rotation).pngData()
        }
        return result
    }
}

import Foundation

struct RGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 255, g: 255, b: 255)
    static let gray = RGB(r: 120, g: 120, b: 120)
    static let darkGray = RGB(r: 40, g: 40, b: 40)
    static let lightGray = RGB(r: 200, g: 200, b: 205)
    static let yellow = RGB(r: 255, g: 200, b: 0)
    static let orange = RGB(r: 255, g: 120, b: 0)
    static let red = RGB(r: 255, g: 30, b: 30)
    static let green = RGB(r: 40, g: 220, b: 60)
    static let blue = RGB(r: 40, g: 120, b: 255)
    static let cyan = RGB(r: 0, g: 200, b: 255)
    static let moon = RGB(r: 230, g: 230, b: 180)
}

/// Crisp pixel drawing in top-left coordinates (row 0 is the top row of `pixels`).
extension Bitmap {
    mutating func set(_ x: Int, _ y: Int, _ color: RGB) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 4
        pixels[i] = color.r
        pixels[i + 1] = color.g
        pixels[i + 2] = color.b
    }

    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, _ color: RGB) {
        for yy in max(0, y)..<min(height, y + h) where w > 0 {
            for xx in max(0, x)..<min(width, x + w) { set(xx, yy, color) }
        }
    }

    mutating func fillCircle(cx: Double, cy: Double, r: Double, _ color: RGB) {
        for y in Int(cy - r - 1)...Int(cy + r + 1) {
            for x in Int(cx - r - 1)...Int(cx + r + 1) {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r * r { set(x, y, color) }
            }
        }
    }

    mutating func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: RGB) {
        var (x, y) = (x0, y0)
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            set(x, y, color)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /// Draws `text` in the 3×5 pixel font with its top-left corner at (x, y).
    mutating func text(_ text: String, x: Int, y: Int, scale: Int = 1, _ color: RGB) {
        var cursor = x
        for glyph in PixelFont.glyphs(for: text) {
            for (row, bits) in glyph.rows.enumerated() {
                for (column, bit) in bits.enumerated() where bit {
                    fill(x: cursor + column * scale, y: y + row * scale, width: scale, height: scale, color)
                }
            }
            cursor += (glyph.width + 1) * scale
        }
    }

    mutating func text(_ text: String, centeredAt centerX: Int, y: Int, scale: Int = 1, _ color: RGB) {
        self.text(text, x: centerX - PixelFont.width(of: text, scale: scale) / 2, y: y, scale: scale, color)
    }

    mutating func text(_ text: String, rightAt right: Int, y: Int, scale: Int = 1, _ color: RGB) {
        self.text(text, x: right - PixelFont.width(of: text, scale: scale), y: y, scale: scale, color)
    }
}

/// A 3×5 pixel font (digits, A–Z and a few symbols). Lowercase is drawn as uppercase,
/// accents are dropped, and anything else becomes "?".
enum PixelFont {
    static let height = 5

    struct Glyph {
        let width: Int
        let rows: [[Bool]]
    }

    static func width(of text: String, scale: Int = 1) -> Int {
        let glyphs = glyphs(for: text)
        guard !glyphs.isEmpty else { return 0 }
        return (glyphs.reduce(0) { $0 + $1.width + 1 } - 1) * scale
    }

    static func glyphs(for text: String) -> [Glyph] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
            .map { table[$0] ?? table["?"]! }
    }

    private static let table: [Character: Glyph] = {
        let source: [Character: [String]] = [
            "0": ["###", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", "###"],
            "2": ["###", "..#", "###", "#..", "###"], "3": ["###", "..#", ".##", "..#", "###"],
            "4": ["#.#", "#.#", "###", "..#", "..#"], "5": ["###", "#..", "###", "..#", "###"],
            "6": ["###", "#..", "###", "#.#", "###"], "7": ["###", "..#", "..#", ".#.", ".#."],
            "8": ["###", "#.#", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "###"],
            "A": [".#.", "#.#", "###", "#.#", "#.#"], "B": ["##.", "#.#", "##.", "#.#", "##."],
            "C": [".##", "#..", "#..", "#..", ".##"], "D": ["##.", "#.#", "#.#", "#.#", "##."],
            "E": ["###", "#..", "##.", "#..", "###"], "F": ["###", "#..", "##.", "#..", "#.."],
            "G": [".##", "#..", "#.#", "#.#", ".##"], "H": ["#.#", "#.#", "###", "#.#", "#.#"],
            "I": ["###", ".#.", ".#.", ".#.", "###"], "J": ["..#", "..#", "..#", "#.#", ".#."],
            "K": ["#.#", "#.#", "##.", "#.#", "#.#"], "L": ["#..", "#..", "#..", "#..", "###"],
            "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"], "N": ["##.", "#.#", "#.#", "#.#", "#.#"],
            "O": [".#.", "#.#", "#.#", "#.#", ".#."], "P": ["##.", "#.#", "##.", "#..", "#.."],
            "Q": [".#.", "#.#", "#.#", "##.", ".##"], "R": ["##.", "#.#", "##.", "#.#", "#.#"],
            "S": [".##", "#..", ".#.", "..#", "##."], "T": ["###", ".#.", ".#.", ".#.", ".#."],
            "U": ["#.#", "#.#", "#.#", "#.#", "###"], "V": ["#.#", "#.#", "#.#", "#.#", ".#."],
            "W": ["#...#", "#...#", "#.#.#", "##.##", "#...#"], "X": ["#.#", "#.#", ".#.", "#.#", "#.#"],
            "Y": ["#.#", "#.#", ".#.", ".#.", ".#."], "Z": ["###", "..#", ".#.", "#..", "###"],
            "%": ["#..", "..#", ".#.", "#..", "..#"], "°": ["###", "#.#", "###", "...", "..."],
            "-": ["...", "...", "###", "...", "..."], "+": ["...", ".#.", "###", ".#.", "..."],
            "/": ["..#", "..#", ".#.", "#..", "#.."], "?": ["###", "..#", ".#.", "...", ".#."],
            ".": [".", ".", ".", ".", "#"], ":": [".", "#", ".", "#", "."], ",": [".", ".", ".", "#", "#"],
            "'": ["#", "#", ".", ".", "."], " ": ["..", "..", "..", "..", ".."],
        ]
        return source.mapValues { rows in
            Glyph(width: rows[0].count, rows: rows.map { $0.map { $0 == "#" } })
        }
    }()
}

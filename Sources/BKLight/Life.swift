import Foundation

/// Conway's Game of Life on a wrap-around grid, one generation per second. Cells keep their
/// age for colour; the board reseeds when it dies out, settles into a short loop, or gets old.
struct LifeGrid {
    let width: Int
    let height: Int
    private(set) var ages: [UInt8]       // 0 = dead, otherwise generations alive (capped)
    private(set) var generation = 0
    private var recent: [Int] = []       // hashes of the last few boards, to spot loops

    static let maxGenerations = 500

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        ages = []
        seed()
    }

    init(width: Int, height: Int, alive: [(Int, Int)]) {
        self.width = width
        self.height = height
        ages = [UInt8](repeating: 0, count: width * height)
        for (x, y) in alive { ages[y * width + x] = 1 }
    }

    var population: Int { ages.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }

    func isAlive(_ x: Int, _ y: Int) -> Bool { ages[y * width + x] > 0 }

    mutating func seed() {
        ages = (0..<width * height).map { _ in Double.random(in: 0..<1) < 0.3 ? 1 : 0 }
        generation = 0
        recent = []
    }

    mutating func step() {
        var next = ages
        for y in 0..<height {
            for x in 0..<width {
                var neighbours = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        if ages[((y + dy + height) % height) * width + (x + dx + width) % width] > 0 { neighbours += 1 }
                    }
                }
                let i = y * width + x
                if ages[i] > 0 {
                    next[i] = neighbours == 2 || neighbours == 3 ? UInt8(min(255, Int(ages[i]) + 1)) : 0
                } else {
                    next[i] = neighbours == 3 ? 1 : 0
                }
            }
        }
        ages = next
        generation += 1

        var hasher = Hasher()
        for age in ages { hasher.combine(age > 0) }
        let hash = hasher.finalize()
        let stuck = recent.contains(hash)
        recent = Array((recent + [hash]).suffix(12))
        if stuck || population < width * height / 40 || generation >= Self.maxGenerations { seed() }
    }
}

extension Renderer {
    /// Newborn cells are bright, older ones fade from cyan to deep blue.
    static func life(_ grid: LifeGrid) -> Bitmap {
        var b = Bitmap(width: grid.width, height: grid.height)
        for y in 0..<grid.height {
            for x in 0..<grid.width where grid.isAlive(x, y) {
                let age = Double(min(30, Int(grid.ages[y * grid.width + x]) - 1)) / 30
                b.set(x, y, RGB(r: UInt8(200 * (1 - age)), g: UInt8(255 - 175 * age), b: 255))
            }
        }
        return b
    }
}

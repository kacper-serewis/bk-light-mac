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
    }
}

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small RGBA8 pixel buffer used for everything sent to the panels.
struct Bitmap: Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: self.pixels.count, by: 4) { self.pixels[i] = 255 }
    }

    /// Draws `image` aspect-filled (center crop) into a new bitmap.
    init(drawing image: CGImage, width: Int, height: Int, smooth: Bool) {
        self.init(width: width, height: height)
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawW = Double(image.width) * scale
        let drawH = Double(image.height) * scale
        let rect = CGRect(x: (Double(width) - drawW) / 2, y: (Double(height) - drawH) / 2, width: drawW, height: drawH)
        withContext { ctx in
            ctx.interpolationQuality = smooth ? .high : .none
            ctx.draw(image, in: rect)
        }
    }

    /// Runs `body` with a CGContext backed by this bitmap (origin bottom-left, as usual for CG).
    mutating func withContext(_ body: (CGContext) -> Void) {
        let (w, h) = (width, height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            body(ctx)
        }
    }

    func crop(x: Int, y: Int, width w: Int, height h: Int) -> Bitmap {
        var out = Bitmap(width: w, height: h)
        for row in 0..<h {
            let src = ((y + row) * width + x) * 4
            out.pixels.replaceSubrange(row * w * 4..<(row + 1) * w * 4, with: pixels[src..<src + w * 4])
        }
        return out
    }

    /// Counter-clockwise rotation in 90° steps (matches PIL `Image.rotate(deg)` for square images).
    func rotated(ccw degrees: Int) -> Bitmap {
        let turns = ((degrees % 360) + 360) % 360 / 90
        guard turns > 0, width == height else { return self }
        var current = self
        for _ in 0..<turns {
            var out = Bitmap(width: width, height: height)
            let n = width
            for ny in 0..<n {
                for nx in 0..<n {
                    // new(nx, ny) = old(n-1-ny, nx)
                    let src = (nx * n + (n - 1 - ny)) * 4
                    let dst = (ny * n + nx) * 4
                    out.pixels[dst..<dst + 4] = current.pixels[src..<src + 4]
                }
            }
            current = out
        }
        return current
    }

    func scaled(by factor: Double) -> Bitmap {
        guard factor < 0.999 else { return self }
        var out = self
        for i in stride(from: 0, to: out.pixels.count, by: 4) {
            for c in 0..<3 { out.pixels[i + c] = UInt8(Double(out.pixels[i + c]) * factor) }
        }
        return out
    }

    func cgImage() -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func nsImage() -> NSImage? {
        guard let image = cgImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}

extension CGImage {
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

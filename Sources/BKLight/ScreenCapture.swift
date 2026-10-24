import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the main display at a tiny resolution for the ambilight mode. Frames are only
/// published when they differ noticeably from the previous one, so a still screen sends nothing.
@MainActor
final class ScreenCapture {
    private(set) var frame: Bitmap?
    private(set) var generation = 0
    private(set) var status = ""
    private(set) var failed = false
    var onChange: (() -> Void)?

    private var running = false
    private var session = 0
    private var stream: SCStream?
    private var output: FrameOutput?

    /// Capture width in pixels; the height follows the display's aspect ratio.
    private static let captureWidth = 128

    func start() {
        guard !running else { return }
        running = true
        session += 1
        let id = session
        update(status: "Starting screen capture…", failed: false)
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self, self.session == id else { return }
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    self.fail("No display found", session: id)
                    return
                }
                // Leave our own window out, so the preview doesn't feed back into the capture.
                let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = Self.captureWidth
                config.height = max(1, Self.captureWidth * display.height / max(1, display.width))
                config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.queueDepth = 3

                let output = FrameOutput(
                    onFrame: { [weak self] bitmap in
                        Task { @MainActor in self?.receive(bitmap, session: id) }
                    },
                    onStop: { [weak self] error in
                        Task { @MainActor in self?.fail("Screen capture stopped: \(error.localizedDescription)", session: id) }
                    }
                )
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
                guard self.session == id else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.output = output
                self.update(status: "Capturing display \(display.width)×\(display.height)", failed: false)
            } catch {
                guard let self, self.session == id else { return }
                self.fail(CGPreflightScreenCaptureAccess()
                    ? "Screen capture failed: \(error.localizedDescription)"
                    : "Allow BK Light under System Settings › Privacy & Security › Screen & System Audio Recording, then press Retry.",
                    session: id)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        session += 1
        let stream = stream
        self.stream = nil
        output = nil
        frame = nil
        Task { try? await stream?.stopCapture() }
    }

    func restart() {
        stop()
        start()
    }

    private func receive(_ bitmap: Bitmap, session id: Int) {
        guard session == id else { return }
        frame = bitmap
        generation += 1
        onChange?()
    }

    private func fail(_ message: String, session id: Int) {
        guard session == id else { return }
        running = false
        stream = nil
        output = nil
        update(status: message, failed: true)
    }

    private func update(status: String, failed: Bool) {
        self.status = status
        self.failed = failed
        onChange?()
    }
}

/// Receives ScreenCaptureKit frames on its own queue and converts them to RGBA bitmaps.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "nl.serewis.bklight.screen")
    private let onFrame: @Sendable (Bitmap) -> Void
    private let onStop: @Sendable (Error) -> Void
    private var lastPublished: Bitmap?   // only touched on `queue`

    /// Mean per-channel change (0–255) below which a frame is dropped; skips caret blinks and the like.
    private static let changeThreshold = 1.0

    init(onFrame: @escaping @Sendable (Bitmap) -> Void, onStop: @escaping @Sendable (Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var bitmap = Bitmap(width: width, height: height)
        for y in 0..<height {
            let row = base + y * bytesPerRow
            for x in 0..<width {
                let src = row + x * 4   // BGRA
                let dst = (y * width + x) * 4
                bitmap.pixels[dst] = src[2]
                bitmap.pixels[dst + 1] = src[1]
                bitmap.pixels[dst + 2] = src[0]
            }
        }
        if let lastPublished, bitmap.meanDifference(to: lastPublished) < Self.changeThreshold { return }
        lastPublished = bitmap
        onFrame(bitmap)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

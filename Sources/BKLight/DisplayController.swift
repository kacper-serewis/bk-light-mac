import AppKit
import Combine
import Foundation

/// Decides what the wall shows (cover art vs. Minecraft clock), renders it and
/// pushes one tile to each panel whenever the picture actually changes.
@MainActor
final class DisplayController: ObservableObject {
    enum Content: Equatable {
        case none, clock(Int), cover(String), identify
        var label: String {
            switch self {
            case .none: "Nothing"
            case .clock(let index): "Minecraft clock (frame \(index + 1)/64)"
            case .cover: "Album cover"
            case .identify: "Identify pattern"
            }
        }
    }

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.panels != oldValue.panels { bluetooth.sync(wanted: Set(settings.panels.map(\.id))) }
            if settings.source != oldValue.source || settings.haBaseURL != oldValue.haBaseURL
                || settings.haEntityID != oldValue.haEntityID {
                restartSource()
            }
            render(force: true)
        }
    }
    @Published var haToken: String {
        didSet {
            guard haToken != oldValue else { return }
            Keychain.write("ha-token", haToken)
            restartSource()
        }
    }

    @Published private(set) var nowPlaying = NowPlaying()
    @Published private(set) var sourceStatus = ""
    @Published private(set) var content: Content = .none
    @Published private(set) var preview: NSImage?
    @Published private(set) var appliedBrightness = 1.0

    let bluetooth = BluetoothManager()

    private var source: NowPlayingSource?
    private var coverCache: (key: String, image: CGImage)?
    private var coverFetchKey: String?
    private var lastPlayingAt = Date.distantPast
    private var lastRenderKey = ""
    private var identifyUntil = Date.distantPast
    private var tick: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        settings = AppSettings.load()
        haToken = Keychain.read("ha-token")
        bluetooth.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        bluetooth.onLinksChanged = { [weak self] in self?.render(force: true) }
        bluetooth.sync(wanted: Set(settings.panels.map(\.id)))
        restartSource()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render(force: false) }
        }
        render(force: true)
    }

    // MARK: Panel assignment

    func assign(_ device: DiscoveredPanel, to slot: Slot) {
        var panels = settings.panels.filter { $0.slot != slot && $0.id != device.id }
        panels.append(PanelConfig(id: device.id, name: device.name, slot: slot, rotation: slot.defaultRotation))
        settings.panels = panels.sorted { $0.slot.rawValue < $1.slot.rawValue }
    }

    func unassign(_ slot: Slot) {
        settings.panels.removeAll { $0.slot == slot }
    }

    func setRotation(_ rotation: Int, for slot: Slot) {
        guard let index = settings.panels.firstIndex(where: { $0.slot == slot }) else { return }
        settings.panels[index].rotation = rotation
    }

    func identify() {
        identifyUntil = Date().addingTimeInterval(8)
        render(force: true)
    }

    // MARK: Source

    private func restartSource() {
        source?.stop()
        let newSource: NowPlayingSource = switch settings.source {
        case .spotifyApp: SpotifyAppSource()
        case .homeAssistant: HomeAssistantSource(baseURL: settings.haBaseURL, token: haToken, entityID: settings.haEntityID)
        }
        newSource.onChange = { [weak self, weak newSource] playing in
            guard let self, let newSource, newSource === self.source else { return }
            self.sourceStatus = newSource.status
            if playing != self.nowPlaying { self.nowPlaying = playing }
            if playing.isPlaying { self.lastPlayingAt = Date() }
            self.render(force: false)
        }
        source = newSource
        sourceStatus = newSource.status
        coverCache = nil
        newSource.start()
    }

    private func loadCover(key: String) {
        guard coverFetchKey != key, let source else { return }
        coverFetchKey = key
        Task { [weak self] in
            let data = try? await source.fetchArtwork()
            guard let self, self.coverFetchKey == key else { return }
            self.coverFetchKey = nil
            if let data, let image = CGImage.decode(data) {
                self.coverCache = (key, image)
                self.render(force: false)
            }
        }
    }

    // MARK: Rendering

    private func desiredContent(now: Date) -> Content {
        if now < identifyUntil { return .identify }
        switch settings.mode {
        case .off: return .none
        case .clockOnly: return .clock(Renderer.clockIndex(for: now))
        case .auto:
            let recentlyPlaying = nowPlaying.isPlaying || now.timeIntervalSince(lastPlayingAt) < settings.idleGrace
            if recentlyPlaying, let key = nowPlaying.artworkKey, !key.isEmpty {
                if coverCache?.key == key { return .cover(key) }
                loadCover(key: key)
                // Keep showing the previous cover while the new one downloads.
                if case .cover = content, coverCache != nil { return content }
            }
            return .clock(Renderer.clockIndex(for: now))
        }
    }

    func render(force: Bool) {
        let now = Date()
        let next = desiredContent(now: now)
        var brightness = settings.brightness
        if settings.dynamicBrightness, case .clock = next {
            brightness *= Renderer.dynamicBrightness(for: now) / 0.85
        }
        brightness = min(1, max(0.02, brightness))
        let size = settings.layout == .tiled ? PanelProtocol.tileSize * 2 : PanelProtocol.tileSize

        let key = "\(next)|\(Int(brightness * 50))|\(settings.layout)|\(settings.panels.map { "\($0.id)\($0.slot)\($0.rotation)" })"
        guard force || key != lastRenderKey else { return }
        lastRenderKey = key

        let canvas: Bitmap
        switch next {
        case .none: canvas = Bitmap(width: size, height: size)
        case .clock(let index): canvas = Renderer.clock(index: index, size: size)
        case .cover: canvas = coverCache.map { Renderer.cover($0.image, size: size) } ?? Bitmap(width: size, height: size)
        case .identify: canvas = Renderer.identifyPattern(size: size, tiled: settings.layout == .tiled)
        }

        content = next
        appliedBrightness = brightness
        preview = canvas.scaled(by: max(brightness, 0.35)).nsImage()
        for (id, png) in Renderer.slices(canvas: canvas, panels: settings.panels, layout: settings.layout, brightness: brightness) {
            bluetooth.link(for: id)?.submit(png: png)
        }
    }
}

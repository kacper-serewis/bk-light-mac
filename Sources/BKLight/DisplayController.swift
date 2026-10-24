import AppKit
import Combine
import Foundation

/// Decides what the wall shows (identify > mode off > night > away > the chosen mode, where
/// automatic mode applies the active sources in order and otherwise rotates the idle screens),
/// renders it and pushes one tile to each panel whenever the picture actually changes.
@MainActor
final class DisplayController: ObservableObject {
    enum Content: Equatable {
        case none, clock(Int), cover(String), screen(Int), weather(String), system(Int)
        case printer(String), laundry(String), bins(String), home(Int), life(Int), identify
        var label: String {
            switch self {
            case .none: "Nothing"
            case .clock(let index): "Minecraft clock (frame \(index + 1)/64)"
            case .cover: "Album cover"
            case .screen: "Screen colours"
            case .weather: "Weather"
            case .system: "System status"
            case .printer: "3D printer"
            case .laundry: "Washing machine"
            case .bins: "Bins"
            case .home: "Home"
            case .life: "Game of Life"
            case .identify: "Identify pattern"
            }
        }
    }

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            updateServices()
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
            updateServices()
        }
    }

    @Published private(set) var nowPlaying = NowPlaying()
    @Published private(set) var sourceStatus = ""
    @Published private(set) var content: Content = .none
    @Published private(set) var preview: NSImage?
    @Published private(set) var appliedBrightness = 1.0
    @Published private(set) var screenStatus = ""
    @Published private(set) var screenFailed = false
    @Published private(set) var weatherStatus = ""
    @Published private(set) var isAway = false
    @Published private(set) var homeAssistantStatus = ""

    let bluetooth = BluetoothManager()
    private lazy var sender = FrameSender(bluetooth: bluetooth)
    private let screen = ScreenCapture()
    private let weather = WeatherService()
    private let monitor = SystemMonitor()
    private let activity = MacActivity()
    private let hub = HomeAssistantHub()
    private var life: LifeGrid?

    private var source: NowPlayingSource?
    private var coverCache: (key: String, image: CGImage)?
    private var coverFetchKey: String?
    private var lastPlayingAt = Date.distantPast
    private var lastRenderKey = ""
    private var identifyUntil = Date.distantPast
    private var tick: Timer?
    private var tickCount = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        settings = AppSettings.load()
        haToken = Keychain.read("ha-token")
        bluetooth.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        bluetooth.onLinksChanged = { [weak self] in self?.render(force: true) }
        bluetooth.sync(wanted: Set(settings.panels.map(\.id)))
        restartSource()
        screen.onChange = { [weak self] in
            guard let self else { return }
            if self.screenStatus != self.screen.status { self.screenStatus = self.screen.status }
            if self.screenFailed != self.screen.failed { self.screenFailed = self.screen.failed }
            self.render(force: false)
        }
        weather.onChange = { [weak self] in
            guard let self else { return }
            self.weatherStatus = self.weather.status
            self.render(force: false)
        }
        hub.onChange = { [weak self] in
            guard let self else { return }
            self.homeAssistantStatus = self.hub.status
            self.render(force: false)
        }
        activity.onChange = { [weak self] in
            guard let self else { return }
            self.isAway = self.activity.isAway
            self.updateServices()
            self.render(force: false)
        }
        activity.onWillSleep = { [weak self] done in self?.prepareForSleep(done) ?? done() }
        isAway = activity.isAway
        updateServices()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
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

    func retryScreenCapture() {
        screen.restart()
    }

    func findWeatherPlace(_ query: String) async {
        weatherStatus = "Searching…"
        do {
            if let place = try await WeatherService.geocode(query) {
                settings.weatherPlace = place
            } else {
                weatherStatus = "No place found for “\(query)”"
            }
        } catch {
            weatherStatus = "Search failed: \(error.localizedDescription)"
        }
    }

    // MARK: Services

    var showsScreenColours: Bool {
        settings.mode == .ambilight || (settings.mode == .auto && settings.activeEnabled.contains(.screen))
    }

    var showsWeather: Bool { uses(idle: .weather, mode: .weather) }

    var usesHomeAssistant: Bool {
        settings.mode == .home || (settings.mode == .auto && (
            settings.activeEnabled.contains(where: \.usesHomeAssistant) || settings.idleScreens.contains(.home)))
    }

    /// What the Home Assistant screens found, for the settings window.
    var homeAssistantFound: String {
        let states = hub.states
        guard !states.isEmpty else { return "" }
        var found: [String] = []
        if HomeAssistant.printer(in: states) != nil { found.append("3D printer") }
        if HomeAssistant.washer(in: states) != nil { found.append("washing machine") }
        if states.keys.contains(where: { $0.hasPrefix("sensor.afvalbeheer") && $0.hasSuffix("_morgen") }) { found.append("bins") }
        let home = HomeAssistant.home(in: states)
        if home.power != nil { found.append("P1 meter") }
        if home.indoor != nil { found.append("thermostat") }
        return found.isEmpty ? "Nothing recognised yet" : "Found: " + found.joined(separator: ", ")
    }

    private func uses(idle screen: IdleScreen, mode: DisplayMode) -> Bool {
        settings.mode == mode || (settings.mode == .auto && settings.idleScreens.contains(screen))
    }

    /// Starts or stops screen capture and weather polling depending on what can be shown.
    private func updateServices() {
        if showsScreenColours && !activity.isAway { screen.start() } else { screen.stop() }
        weather.update(place: settings.weatherPlace, active: uses(idle: .weather, mode: .weather))
        hub.update(baseURL: settings.haBaseURL, token: haToken, active: usesHomeAssistant)
    }

    private func onTick() {
        tickCount += 1
        if tickCount % 2 == 0, uses(idle: .system, mode: .system) { monitor.sample() }
        if case .life = content { life?.step() }
        render(force: false)
    }

    /// Before system sleep: show what "away" asks for and give the panels a moment to receive it.
    private func prepareForSleep(_ done: @escaping () -> Void) {
        guard settings.awayAction == .off else { return done() }
        render(force: false)
        Task { [weak self] in
            for _ in 0..<60 {
                guard let self, !self.sender.isIdle else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            done()
        }
    }

    // MARK: Source

    private func restartSource() {
        source?.stop()
        let newSource: NowPlayingSource = switch settings.source {
        case .system: SystemMediaSource()
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
        if settings.mode == .off { return .none }
        if settings.isNight(at: now) {
            return settings.nightAction == .off ? .none : .clock(Renderer.clockIndex(for: now))
        }
        if activity.isAway && settings.awayAction == .off { return .none }

        switch settings.mode {
        case .off: return .none
        case .clockOnly: return .clock(Renderer.clockIndex(for: now))
        case .ambilight: return .screen(screen.generation)
        case .weather: return weatherContent() ?? .clock(Renderer.clockIndex(for: now))
        case .system: return .system(monitor.generation)
        case .home: return homeContent() ?? .clock(Renderer.clockIndex(for: now))
        case .life: return .life(life?.generation ?? 0)
        case .auto:
            for source in settings.activeOrder where settings.activeEnabled.contains(source) {
                switch source {
                case .music:
                    if let cover = musicContent(now: now) { return cover }
                case .screen:
                    if !activity.isAway, screen.frame != nil { return .screen(screen.generation) }
                case .printer:
                    if let printer = HomeAssistant.printer(in: hub.states), printer.isShown(at: now) {
                        let hasCover = printer.coverPath.map { hub.image(path: $0) != nil } ?? false
                        return .printer("\(printer)|\(hasCover)")
                    }
                case .laundry:
                    if let washer = HomeAssistant.washer(in: hub.states), washer.isShown(at: now) {
                        return .laundry("\(washer)|\(Int(now.timeIntervalSince1970 / 60))")
                    }
                case .bins:
                    if let bins = HomeAssistant.bins(in: hub.states, at: now) { return .bins("\(bins)") }
                }
            }
            return idleContent(now: now)
        }
    }

    private func musicContent(now: Date) -> Content? {
        let recentlyPlaying = nowPlaying.isPlaying || now.timeIntervalSince(lastPlayingAt) < settings.idleGrace
        guard recentlyPlaying, let key = nowPlaying.artworkKey, !key.isEmpty else { return nil }
        if coverCache?.key == key { return .cover(key) }
        loadCover(key: key)
        // Keep showing the previous cover while the new one downloads.
        if case .cover = content, coverCache != nil { return content }
        return nil
    }

    private func homeContent() -> Content? {
        let home = HomeAssistant.home(in: hub.states)
        return home.power != nil || home.indoor != nil ? .home(hub.generation) : nil
    }

    private func weatherContent() -> Content? {
        weather.report.map { .weather("\($0)") }
    }

    /// Enabled idle screens take turns; weather only counts once it has data.
    private func idleContent(now: Date) -> Content {
        var available: [Content] = []
        for screen in IdleScreen.allCases where settings.idleScreens.contains(screen) {
            switch screen {
            case .clock: available.append(.clock(Renderer.clockIndex(for: now)))
            case .weather: if let weather = weatherContent() { available.append(weather) }
            case .system: available.append(.system(monitor.generation))
            case .home: if let home = homeContent() { available.append(home) }
            case .life: available.append(.life(life?.generation ?? 0))
            }
        }
        guard !available.isEmpty else {
            return settings.idleScreens.isEmpty ? .none : .clock(Renderer.clockIndex(for: now))
        }
        let slot = Int(now.timeIntervalSince1970 / max(5, settings.idleRotation))
        return available[slot % available.count]
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

        let key = "\(next)|\(Int(brightness * 50))|\(settings.layout)|\(settings.screenStyle)|\(settings.panels.map { "\($0.id)\($0.slot)\($0.rotation)" })"
        guard force || key != lastRenderKey else { return }
        lastRenderKey = key

        let canvas: Bitmap
        switch next {
        case .none: canvas = Bitmap(width: size, height: size)
        case .clock(let index): canvas = Renderer.clock(index: index, size: size)
        case .cover: canvas = coverCache.map { Renderer.cover($0.image, size: size) } ?? Bitmap(width: size, height: size)
        case .screen:
            canvas = screen.frame.map { Renderer.screen($0, style: settings.screenStyle, size: size) } ?? Bitmap(width: size, height: size)
        case .weather:
            canvas = weather.report.map { Renderer.weather($0, size: size) } ?? Bitmap(width: size, height: size)
        case .system: canvas = Renderer.systemStatus(monitor.snapshot, size: size)
        case .printer:
            if let printer = HomeAssistant.printer(in: hub.states) {
                canvas = Renderer.printer(printer, cover: printer.coverPath.flatMap { hub.image(path: $0) }, size: size)
            } else {
                canvas = Bitmap(width: size, height: size)
            }
        case .laundry:
            canvas = HomeAssistant.washer(in: hub.states).map { Renderer.washer($0, now: now, size: size) } ?? Bitmap(width: size, height: size)
        case .bins:
            canvas = HomeAssistant.bins(in: hub.states, at: now).map { Renderer.bins($0, size: size) } ?? Bitmap(width: size, height: size)
        case .home:
            canvas = Renderer.home(HomeAssistant.home(in: hub.states), powerHistory: hub.powerHistory, size: size)
        case .life:
            if life?.width != size { life = LifeGrid(width: size, height: size) }
            canvas = Renderer.life(life!)
        case .identify: canvas = Renderer.identifyPattern(size: size, tiled: settings.layout == .tiled)
        }

        content = next
        appliedBrightness = brightness
        preview = canvas.scaled(by: max(brightness, 0.35)).nsImage()
        sender.submit(Renderer.slices(canvas: canvas, panels: settings.panels, layout: settings.layout, brightness: brightness))
    }
}

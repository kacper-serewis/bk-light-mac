import Foundation
import Security

/// Grid position of a panel in the 2x2 wall.
enum Slot: Int, CaseIterable, Codable, Identifiable {
    case topLeft = 0, topRight, bottomLeft, bottomRight
    var id: Int { rawValue }
    var gridX: Int { rawValue % 2 }
    var gridY: Int { rawValue / 2 }
    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
    /// Defaults from the AppBypass config.yaml (left column 90°, right column 270°).
    var defaultRotation: Int { gridX == 0 ? 90 : 270 }
}

struct PanelConfig: Codable, Identifiable, Equatable {
    var id: UUID          // CoreBluetooth peripheral identifier (macOS hides MAC addresses)
    var name: String
    var slot: Slot
    var rotation: Int     // counter-clockwise degrees, like PIL's Image.rotate
}

enum Layout: String, Codable, CaseIterable, Identifiable {
    case tiled, mirrored
    var id: String { rawValue }
    var label: String { self == .tiled ? "One 64×64 image across 2×2" : "Same image on every panel" }
}

enum MediaSource: String, Codable, CaseIterable, Identifiable {
    case system, spotifyApp, homeAssistant
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Anything playing on this Mac"
        case .spotifyApp: "Spotify app (AppleScript)"
        case .homeAssistant: "Home Assistant media player"
        }
    }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case auto, clockOnly, ambilight, weather, system, home, life, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic (rules)"
        case .clockOnly: "Clock"
        case .ambilight: "Screen colours (ambilight)"
        case .weather: "Weather"
        case .system: "System status"
        case .home: "Home (Home Assistant)"
        case .life: "Game of Life"
        case .off: "Off (black)"
        }
    }
}

/// In automatic mode: shown only while they have something to show, first match wins.
enum ActiveSource: String, Codable, CaseIterable, Identifiable {
    case music, screen, printer, laundry, bins
    var id: String { rawValue }
    var label: String {
        switch self {
        case .music: "Music (cover art while playing)"
        case .screen: "Screen colours (while you use the Mac)"
        case .printer: "3D printer (while printing)"
        case .laundry: "Washing machine (running, then done)"
        case .bins: "Bins (evening before pickup)"
        }
    }
    var usesHomeAssistant: Bool { self == .printer || self == .laundry || self == .bins }
}

/// In automatic mode: shown in turns when no active source applies.
enum IdleScreen: String, Codable, CaseIterable, Identifiable {
    case clock, weather, system, home, life
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clock: "Clock"
        case .weather: "Weather"
        case .system: "System status"
        case .home: "Home: power, temperature (Home Assistant)"
        case .life: "Game of Life"
        }
    }
}

enum AwayAction: String, Codable, CaseIterable, Identifiable {
    case off, keep
    var id: String { rawValue }
    var label: String { self == .off ? "Turn the wall off" : "Keep showing music and idle screens" }
}

enum NightAction: String, Codable, CaseIterable, Identifiable {
    case off, clock
    var id: String { rawValue }
    var label: String { self == .off ? "Wall off" : "Clock only" }
}

enum ScreenStyle: String, Codable, CaseIterable, Identifiable {
    case glow, mirror
    var id: String { rawValue }
    var label: String { self == .glow ? "Soft glow (average colours)" : "Mirror (mini screen)" }
}

struct AppSettings: Codable, Equatable {
    var panels: [PanelConfig] = []
    var layout: Layout = .tiled
    var source: MediaSource = .system
    var mode: DisplayMode = .auto
    var brightness: Double = 0.85
    var dynamicBrightness = true
    var haBaseURL = ""
    var haEntityID = "media_player.spotify"
    /// Seconds to keep the cover after playback stops, so skipping tracks doesn't flash the clock.
    var idleGrace: Double = 4
    var screenStyle: ScreenStyle = .glow

    var activeOrder: [ActiveSource] = ActiveSource.allCases
    var activeEnabled: Set<ActiveSource> = [.music]
    var idleScreens: Set<IdleScreen> = [.clock]
    /// Seconds per idle screen when several are enabled.
    var idleRotation: Double = 20
    /// Locked, display asleep, screensaver or system sleep.
    var awayAction: AwayAction = .off
    var nightEnabled = false
    var nightStart = 0          // minutes after midnight
    var nightEnd = 7 * 60
    var nightAction: NightAction = .off
    var weatherPlace: WeatherPlace?

    private static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func panel(in slot: Slot) -> PanelConfig? { panels.first { $0.slot == slot } }

    func isNight(at date: Date, calendar: Calendar = .current) -> Bool {
        guard nightEnabled, nightStart != nightEnd else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return nightStart < nightEnd
            ? (nightStart..<nightEnd).contains(minutes)
            : minutes >= nightStart || minutes < nightEnd
    }
}

extension AppSettings {
    /// Decodes key by key so settings saved by an older version (without newer keys) keep their values.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = AppSettings()
        panels = value(.panels, defaults.panels)
        layout = value(.layout, defaults.layout)
        source = value(.source, defaults.source)
        mode = value(.mode, defaults.mode)
        brightness = value(.brightness, defaults.brightness)
        dynamicBrightness = value(.dynamicBrightness, defaults.dynamicBrightness)
        haBaseURL = value(.haBaseURL, defaults.haBaseURL)
        haEntityID = value(.haEntityID, defaults.haEntityID)
        idleGrace = value(.idleGrace, defaults.idleGrace)
        screenStyle = value(.screenStyle, defaults.screenStyle)
        // Keep every source exactly once, so newly added ones show up in the list.
        let order = value(.activeOrder, defaults.activeOrder)
        activeOrder = order.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            + ActiveSource.allCases.filter { !order.contains($0) }
        activeEnabled = value(.activeEnabled, defaults.activeEnabled)
        idleScreens = value(.idleScreens, defaults.idleScreens)
        idleRotation = value(.idleRotation, defaults.idleRotation)
        awayAction = value(.awayAction, defaults.awayAction)
        nightEnabled = value(.nightEnabled, defaults.nightEnabled)
        nightStart = value(.nightStart, defaults.nightStart)
        nightEnd = value(.nightEnd, defaults.nightEnd)
        nightAction = value(.nightAction, defaults.nightAction)
        weatherPlace = value(.weatherPlace, defaults.weatherPlace)
    }
}

/// Home Assistant token lives in the login keychain rather than UserDefaults.
enum Keychain {
    private static let service = "nl.serewis.bklight"

    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

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
    case spotifyApp, homeAssistant
    var id: String { rawValue }
    var label: String { self == .spotifyApp ? "Spotify app on this Mac" : "Home Assistant media player" }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case auto, clockOnly, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Cover art, clock when idle"
        case .clockOnly: "Clock only"
        case .off: "Off (black)"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var panels: [PanelConfig] = []
    var layout: Layout = .tiled
    var source: MediaSource = .spotifyApp
    var mode: DisplayMode = .auto
    var brightness: Double = 0.85
    var dynamicBrightness = true
    var haBaseURL = ""
    var haEntityID = "media_player.spotify"
    /// Seconds to keep the cover after playback stops, so skipping tracks doesn't flash the clock.
    var idleGrace: Double = 4

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

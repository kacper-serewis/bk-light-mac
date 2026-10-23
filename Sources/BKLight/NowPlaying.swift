import AppKit
import Foundation

struct NowPlaying: Equatable {
    var isPlaying = false
    var title = ""
    var artist = ""
    var artworkKey: String?   // changes whenever the artwork changes
}

@MainActor
protocol NowPlayingSource: AnyObject {
    var onChange: ((NowPlaying) -> Void)? { get set }
    var status: String { get }
    func start()
    func stop()
    func fetchArtwork() async throws -> Data?
}

/// Reads the Spotify desktop app via AppleScript. Spotify posts a distributed
/// notification on every play/pause/track change; a slow poll covers the rest.
@MainActor
final class SpotifyAppSource: NowPlayingSource {
    var onChange: ((NowPlaying) -> Void)?
    private(set) var status = "Waiting for Spotify"
    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    private var artworkURL: URL?

    private static let script = NSAppleScript(source: """
        if application "Spotify" is running then
            tell application "Spotify"
                set s to player state as string
                if s is "stopped" then return "stopped"
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t)
            end tell
        else
            return "not running"
        end if
        """)

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        pollTask?.cancel()
    }

    private func refresh() {
        var error: NSDictionary?
        guard let output = Self.script?.executeAndReturnError(&error).stringValue else {
            let code = error?[NSAppleScript.errorNumber] as? Int
            status = code == -1743
                ? "Not allowed to control Spotify. Enable it in System Settings › Privacy & Security › Automation."
                : "AppleScript error: \(error?[NSAppleScript.errorMessage] as? String ?? "unknown")"
            onChange?(NowPlaying())
            return
        }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 4 else {
            status = output == "not running" ? "Spotify is not running" : "Spotify is stopped"
            artworkURL = nil
            onChange?(NowPlaying())
            return
        }
        artworkURL = URL(string: parts[3])
        status = "Spotify: \(parts[0])"
        onChange?(NowPlaying(isPlaying: parts[0] == "playing", title: parts[1], artist: parts[2], artworkKey: parts[3]))
    }

    func fetchArtwork() async throws -> Data? {
        guard let artworkURL else { return nil }
        return try await URLSession.shared.data(from: artworkURL).0
    }
}

/// Polls a Home Assistant media_player (e.g. the Spotify integration), which
/// also sees playback on phones and speakers, not only this Mac.
@MainActor
final class HomeAssistantSource: NowPlayingSource {
    var onChange: ((NowPlaying) -> Void)?
    private(set) var status = "Not connected"
    private let baseURL: URL?
    private let token: String
    private let entityID: String
    private var pollTask: Task<Void, Never>?
    private var picturePath: String?

    init(baseURL: String, token: String, entityID: String) {
        var trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = URL(string: trimmed)
        self.token = token
        self.entityID = entityID.trimmingCharacters(in: .whitespaces)
    }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() { pollTask?.cancel() }

    private func request(_ path: String) -> URLRequest? {
        guard let baseURL, let url = URL(string: baseURL.absoluteString + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func refresh() async {
        guard !token.isEmpty, let request = request("/api/states/\(entityID)") else {
            status = "Set the Home Assistant URL, token and entity"
            onChange?(NowPlaying())
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = "Home Assistant returned HTTP \(code)"
                onChange?(NowPlaying())
                return
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let state = json["state"] as? String ?? ""
            let attributes = json["attributes"] as? [String: Any] ?? [:]
            picturePath = attributes["entity_picture"] as? String
            status = "\(entityID): \(state)"
            onChange?(NowPlaying(
                isPlaying: state == "playing",
                title: attributes["media_title"] as? String ?? "",
                artist: attributes["media_artist"] as? String ?? "",
                artworkKey: picturePath
            ))
        } catch {
            status = "Home Assistant: \(error.localizedDescription)"
            onChange?(NowPlaying())
        }
    }

    func fetchArtwork() async throws -> Data? {
        guard let picturePath else { return nil }
        let request: URLRequest?
        if picturePath.hasPrefix("http") {
            request = URL(string: picturePath).map { URLRequest(url: $0) }
        } else {
            request = self.request(picturePath)
        }
        guard let request else { return nil }
        return try await URLSession.shared.data(for: request).0
    }
}

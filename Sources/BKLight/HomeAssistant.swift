import CoreGraphics
import Foundation

struct HAState {
    let state: String
    let attributes: [String: Any]
    let lastChanged: Date

    func number(_ key: String) -> Double? {
        if let value = attributes[key] as? Double { return value }
        return (attributes[key] as? String).flatMap(Double.init)
    }
}

/// Polls all Home Assistant states (one request, ~45 KB gzipped) every 10 s while a
/// Home Assistant screen is enabled, and loads entity pictures (e.g. the printer's cover image).
@MainActor
final class HomeAssistantHub {
    private(set) var states: [String: HAState] = [:]
    private(set) var status = "Not set up"
    private(set) var powerHistory: [Double] = []
    private(set) var generation = 0     // bumped on every successful poll
    var onChange: (() -> Void)?

    nonisolated static let powerHistoryLength = 60   // 10 minutes at one poll per 10 s

    private var baseURL: URL?
    private var token = ""
    private var pollTask: Task<Void, Never>?
    private var images: [String: CGImage] = [:]
    private var imageLoads: Set<String> = []

    func update(baseURL: String, token: String, active: Bool) {
        let url = HomeAssistant.normalizedURL(baseURL)
        let changed = url != self.baseURL || token != self.token
        self.baseURL = url
        self.token = token
        if changed {
            states = [:]
            powerHistory = []
            images = [:]
        }
        guard active, url != nil, !token.isEmpty else {
            pollTask?.cancel()
            pollTask = nil
            if url == nil || token.isEmpty { status = "Set the Home Assistant URL and token" }
            return
        }
        guard pollTask == nil || changed else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func request(_ path: String) -> URLRequest? {
        guard let baseURL, let url = URL(string: baseURL.absoluteString + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func poll() async {
        guard let request = request("/api/states") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = code == 401 ? "Home Assistant rejected the token" : "Home Assistant returned HTTP \(code)"
                onChange?()
                return
            }
            states = HomeAssistant.parseStates(data)
            generation += 1
            if let power = HomeAssistant.home(in: states).power {
                powerHistory = Array((powerHistory + [power]).suffix(Self.powerHistoryLength))
            }
            status = "Connected: \(states.count) entities, updated \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            status = "Home Assistant: \(error.localizedDescription)"
        }
        onChange?()
    }

    /// Returns a cached entity picture, loading it in the background the first time.
    func image(path: String) -> CGImage? {
        if let image = images[path] { return image }
        guard !imageLoads.contains(path), let request = request(path) else { return nil }
        imageLoads.insert(path)
        Task { [weak self] in
            let data = try? await URLSession.shared.data(for: request).0
            guard let self else { return }
            self.imageLoads.remove(path)
            if let data, let image = CGImage.decode(data) {
                if self.images.count > 8 { self.images.removeAll() }
                self.images[path] = image
                self.onChange?()
            }
        }
        return nil
    }
}

/// Finds the entities the wall can show by their naming patterns, and interprets their states.
enum HomeAssistant {
    static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed.hasPrefix("http") else { return nil }
        return URL(string: trimmed)
    }

    static func parseStates(_ data: Data) -> [String: HAState] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var result: [String: HAState] = [:]
        for item in list {
            guard let id = item["entity_id"] as? String, let state = item["state"] as? String else { continue }
            let changed = (item["last_changed"] as? String).flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
            result[id] = HAState(state: state, attributes: item["attributes"] as? [String: Any] ?? [:],
                                 lastChanged: changed ?? .distantPast)
        }
        return result
    }

    static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Prefix of the first entity whose id matches `domain.<prefix><suffix>`, preferring available ones.
    private static func prefix(in states: [String: HAState], domain: String, suffix: String,
                               where extra: (String, HAState) -> Bool = { _, _ in true }) -> String? {
        let matches = states.filter { id, state in
            id.hasPrefix(domain + ".") && id.hasSuffix(suffix) && extra(id, state)
        }
        let sorted = matches.sorted { a, b in
            let (ua, ub) = (a.value.state == "unavailable", b.value.state == "unavailable")
            return ua != ub ? !ua : a.key < b.key
        }
        return sorted.first.map { String($0.key.dropFirst(domain.count + 1).dropLast(suffix.count)) }
    }

    // MARK: 3D printer (ha-bambulab)

    struct Printer: Equatable {
        var status: String          // running, pause, prepare, finish, failed, idle, …
        var progress: Double        // 0…1
        var remainingMinutes: Int?
        var coverPath: String?
        var changedAt: Date

        func isShown(at now: Date) -> Bool {
            switch status {
            case "running", "pause", "prepare", "init", "slicing": true
            case "finish", "failed": now.timeIntervalSince(changedAt) < 15 * 60
            default: false
            }
        }
    }

    static func printer(in states: [String: HAState]) -> Printer? {
        guard let p = prefix(in: states, domain: "sensor", suffix: "_print_status"),
              let status = states["sensor.\(p)_print_status"], status.state != "unavailable" else { return nil }
        let remainingHours = states["sensor.\(p)_remaining_time"].flatMap { Double($0.state) }
        let cover = states["image.\(p)_cover_image"]
        return Printer(
            status: status.state,
            progress: (states["sensor.\(p)_print_progress"].flatMap { Double($0.state) } ?? 0) / 100,
            remainingMinutes: remainingHours.map { Int(($0 * 60).rounded()) },
            coverPath: cover?.state == "unavailable" ? nil : cover?.attributes["entity_picture"] as? String,
            changedAt: status.lastChanged
        )
    }

    // MARK: Washing machine (SmartThings-style machine_state / job_state / completion_time)

    struct Washer: Equatable {
        var state: String           // run, pause, stop
        var job: String             // wash, rinse, spin, …
        var completion: Date?

        func isShown(at now: Date) -> Bool {
            if state == "run" || state == "pause" { return true }
            guard let completion else { return false }
            return completion <= now && now.timeIntervalSince(completion) < 30 * 60
        }

        func isDone(at now: Date) -> Bool { state == "stop" && (completion.map { $0 <= now } ?? false) }
    }

    static func washer(in states: [String: HAState]) -> Washer? {
        guard let p = prefix(in: states, domain: "sensor", suffix: "_machine_state", where: { id, state in
            (state.attributes["options"] as? [String])?.contains("run") == true
        }), let machine = states["sensor.\(p)_machine_state"], machine.state != "unavailable" else { return nil }
        return Washer(
            state: machine.state,
            job: states["sensor.\(p)_job_state"]?.state ?? "",
            completion: states["sensor.\(p)_completion_time"].flatMap { timestamp($0.state) }
        )
    }

    // MARK: Bins (afvalbeheer: sensor.afvalbeheer_<app>_vandaag / _morgen)

    struct Bins: Equatable {
        var types: [String]
        var tomorrow: Bool
    }

    /// Tomorrow's bins from 17:00, today's until noon.
    static func bins(in states: [String: HAState], at now: Date, calendar: Calendar = .current) -> Bins? {
        guard let p = prefix(in: states, domain: "sensor", suffix: "_morgen", where: { id, _ in id.hasPrefix("sensor.afvalbeheer") })
        else { return nil }
        let hour = calendar.component(.hour, from: now)
        func types(_ id: String) -> [String] {
            guard let state = states[id]?.state, !["geen", "none", "unavailable", "unknown", ""].contains(state.lowercased())
            else { return [] }
            return state.replacingOccurrences(of: " en ", with: ",").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if hour < 12, case let today = types("sensor.\(p)_vandaag"), !today.isEmpty { return Bins(types: today, tomorrow: false) }
        if hour >= 17, case let tomorrow = types("sensor.\(p)_morgen"), !tomorrow.isEmpty { return Bins(types: tomorrow, tomorrow: true) }
        return nil
    }

    // MARK: Home (P1 meter power, thermostat)

    struct Home: Equatable {
        var power: Double?          // W, negative when exporting
        var indoor: Double?
        var target: Double?
        var humidity: Double?
        var heating = false
    }

    static func home(in states: [String: HAState]) -> Home {
        var home = Home()
        if let p = prefix(in: states, domain: "sensor", suffix: "p1_meter_power") {
            home.power = states["sensor.\(p)p1_meter_power"].flatMap { Double($0.state) }
        }
        if let c = prefix(in: states, domain: "climate", suffix: ""), let climate = states["climate.\(c)"] {
            home.indoor = climate.number("current_temperature")
            home.target = climate.number("temperature")
            home.heating = climate.attributes["hvac_action"] as? String == "heating"
            home.humidity = states["sensor.\(c)_humidity"].flatMap { Double($0.state) }
        }
        return home
    }
}

import Foundation

struct WeatherPlace: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

struct WeatherReport: Equatable {
    var temperature: Double
    var code: Int          // WMO weather code
    var isDay: Bool
    var high: Double
    var low: Double
}

/// Current weather from Open-Meteo (free, no API key), refreshed every 15 minutes while needed.
@MainActor
final class WeatherService {
    private(set) var report: WeatherReport?
    private(set) var status = "Set a place"
    var onChange: (() -> Void)?

    private var place: WeatherPlace?
    private var pollTask: Task<Void, Never>?

    /// Starts or stops polling; a changed place is fetched right away.
    func update(place: WeatherPlace?, active: Bool) {
        let placeChanged = place != self.place
        self.place = place
        if placeChanged {
            report = nil
            status = place == nil ? "Set a place" : "Loading…"
            onChange?()
        }
        guard active, place != nil else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil || placeChanged else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    private func refresh() async {
        guard let place else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard place == self.place else { return }
            report = WeatherReport(
                temperature: response.current.temperature_2m,
                code: response.current.weather_code,
                isDay: response.current.is_day == 1,
                high: response.daily.temperature_2m_max.first ?? response.current.temperature_2m,
                low: response.daily.temperature_2m_min.first ?? response.current.temperature_2m
            )
            status = "\(place.name): updated \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "Weather: \(error.localizedDescription)"
        }
        onChange?()
    }

    /// Looks up a place name with Open-Meteo's geocoding API.
    static func geocode(_ query: String) async throws -> WeatherPlace? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String; let latitude: Double; let longitude: Double
                let admin1: String?; let country_code: String?
            }
            let results: [Result]?
        }
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let result = try JSONDecoder().decode(Response.self, from: data).results?.first else { return nil }
        let name = [result.name, result.admin1, result.country_code].compactMap { $0 }.joined(separator: ", ")
        return WeatherPlace(name: name, latitude: result.latitude, longitude: result.longitude)
    }
}

extension Renderer {
    enum WeatherKind { case clear, partlyCloudy, cloudy, fog, rain, snow, thunder }

    static func weatherKind(code: Int) -> WeatherKind {
        switch code {
        case 0: .clear
        case 1, 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .fog
        case 71...77, 85, 86: .snow
        case 95...99: .thunder
        case 51...67, 80...82: .rain
        default: .cloudy
        }
    }

    /// Weather icon on top, big temperature below, today's high/low at the bottom (64×64).
    /// The 32×32 version drops the high/low line.
    static func weather(_ report: WeatherReport, size: Int) -> Bitmap {
        var bitmap = Bitmap(width: size, height: size)
        let big = size >= 64
        let iconSize = big ? 30 : 16
        drawWeatherIcon(&bitmap, kind: weatherKind(code: report.code), isDay: report.isDay,
                        x: (size - iconSize) / 2, y: big ? 1 : 0, size: iconSize)
        let temperature = "\(Int(report.temperature.rounded()))°"
        bitmap.text(temperature, centeredAt: size / 2 + 1, y: big ? 34 : 18, scale: big ? 3 : 2, .white)
        if big {
            let high = "\(Int(report.high.rounded()))", low = "\(Int(report.low.rounded()))"
            bitmap.text(high, rightAt: size / 2 - 3, y: 55, RGB(r: 255, g: 150, b: 60))
            bitmap.text(low, x: size / 2 + 3, y: 55, .cyan)
        }
        return bitmap
    }

    static func drawWeatherIcon(_ b: inout Bitmap, kind: WeatherKind, isDay: Bool, x: Int, y: Int, size: Int) {
        let s = Double(size), ox = Double(x), oy = Double(y)
        func celestial(cx: Double, cy: Double, r: Double) {
            if isDay {
                b.fillCircle(cx: ox + cx * s, cy: oy + cy * s, r: r * s, .yellow)
                for i in 0..<8 {
                    let angle = Double(i) * .pi / 4
                    let (c, sn) = (cos(angle), sin(angle))
                    b.line(Int(ox + (cx + c * r * 1.45) * s), Int(oy + (cy + sn * r * 1.45) * s),
                           Int(ox + (cx + c * r * 1.85) * s), Int(oy + (cy + sn * r * 1.85) * s), .yellow)
                }
            } else {
                b.fillCircle(cx: ox + cx * s, cy: oy + cy * s, r: r * 1.2 * s, .moon)
                b.fillCircle(cx: ox + (cx + r * 0.7) * s, cy: oy + (cy - r * 0.5) * s, r: r * 1.0 * s, .black)
            }
        }
        /// A cloud whose bounding box starts at (cx, cy) (fractions of the icon) with width w.
        func cloud(_ cx: Double, _ cy: Double, _ w: Double, _ color: RGB) {
            let (bx, by, bw) = (ox + cx * s, oy + cy * s, w * s)
            b.fillCircle(cx: bx + 0.55 * bw, cy: by + 0.32 * bw, r: 0.24 * bw, color)
            b.fillCircle(cx: bx + 0.27 * bw, cy: by + 0.46 * bw, r: 0.17 * bw, color)
            b.fillCircle(cx: bx + 0.78 * bw, cy: by + 0.47 * bw, r: 0.16 * bw, color)
            b.fill(x: Int(bx + 0.27 * bw), y: Int(by + 0.42 * bw), width: Int(0.51 * bw), height: Int(0.21 * bw), color)
        }
        func drops(_ color: RGB, slant: Bool) {
            for (i, fx) in [0.25, 0.5, 0.75].enumerated() {
                let top = oy + (0.68 + (i % 2 == 0 ? 0 : 0.08)) * s
                let x0 = Int(ox + fx * s)
                if slant {
                    b.line(x0, Int(top), x0 - Int(0.06 * s), Int(top + 0.16 * s), color)
                } else {
                    b.fillCircle(cx: Double(x0), cy: top + 0.08 * s, r: max(1, 0.05 * s), color)
                }
            }
        }

        switch kind {
        case .clear:
            celestial(cx: 0.5, cy: 0.5, r: 0.22)
        case .partlyCloudy:
            celestial(cx: 0.64, cy: 0.34, r: 0.16)
            cloud(0.02, 0.3, 0.8, .lightGray)
        case .cloudy:
            cloud(0.22, 0.1, 0.76, .gray)
            cloud(0.0, 0.3, 0.8, .lightGray)
        case .fog:
            for (i, fy) in [0.3, 0.45, 0.6, 0.75].enumerated() {
                let inset = i % 2 == 0 ? 0.08 : 0.18
                b.fill(x: Int(ox + inset * s), y: Int(oy + fy * s), width: Int((0.84 - inset) * s), height: max(1, Int(0.07 * s)), .gray)
            }
        case .rain:
            cloud(0.1, 0.02, 0.8, .gray)
            drops(.blue, slant: true)
        case .snow:
            cloud(0.1, 0.02, 0.8, .lightGray)
            drops(.white, slant: false)
        case .thunder:
            cloud(0.1, 0.02, 0.8, RGB(r: 90, g: 90, b: 100))
            let points = [(0.55, 0.6), (0.42, 0.8), (0.55, 0.8), (0.45, 1.0)]
            for (a, c) in zip(points, points.dropFirst()) {
                b.line(Int(ox + a.0 * s), Int(oy + a.1 * s) - 1, Int(ox + c.0 * s), Int(oy + c.1 * s) - 1, .yellow)
                b.line(Int(ox + a.0 * s) + 1, Int(oy + a.1 * s) - 1, Int(ox + c.0 * s) + 1, Int(oy + c.1 * s) - 1, .yellow)
            }
        }
    }
}

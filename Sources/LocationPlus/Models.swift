import CoreLocation
import Foundation

struct Device: Identifiable, Hashable, Decodable {
    let udid: String
    let name: String
    let model: String
    let osVersion: String
    let connection: String
    let ready: Bool
    let issue: String?

    var id: String { udid }

    enum CodingKeys: String, CodingKey {
        case udid, name, model, connection, ready, issue
        case osVersion = "os_version"
    }

    var subtitle: String {
        [osVersion.isEmpty ? nil : "iOS \(osVersion)", connection.isEmpty ? nil : connection]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var symbol: String { model.hasPrefix("iPad") ? "ipad" : "iphone" }
}

enum PinState: String {
    case connecting, pinned, reconnecting, stopped
}

struct Pin: Equatable {
    var coordinate: CLLocationCoordinate2D
    var state: PinState
    var error: String?

    static func == (a: Pin, b: Pin) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.state == b.state && a.error == b.error
    }
}

struct Place: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var date = Date()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(name: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    func isNear(_ c: CLLocationCoordinate2D) -> Bool {
        abs(latitude - c.latitude) < 0.00005 && abs(longitude - c.longitude) < 0.00005
    }
}

extension CLLocationCoordinate2D {
    var formatted: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    /// Parses "40.7128, -74.0060" (comma and/or whitespace separated).
    init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else {
            return nil
        }
        self.init(latitude: parts[0], longitude: parts[1])
    }
}

/// Saved places and recents, persisted as JSON in UserDefaults.
struct PlaceStore {
    private static let savedKey = "savedPlaces"
    private static let recentKey = "recentPlaces"

    static func load(_ key: String) -> [Place] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let places = try? JSONDecoder().decode([Place].self, from: data) else { return [] }
        return places
    }

    static func save(_ places: [Place], _ key: String) {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static var saved: [Place] {
        get { load(savedKey) }
        set { save(newValue, savedKey) }
    }

    static var recent: [Place] {
        get { load(recentKey) }
        set { save(newValue, recentKey) }
    }
}

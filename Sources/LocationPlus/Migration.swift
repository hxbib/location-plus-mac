import CoreLocation
import Foundation

/// Imports saved locations and history from the original web version
/// (~/.locationplus/), or seeds its preset places on a fresh install.
enum Migration {
    private static let doneKey = "migratedFromWebVersion"

    /// The original app's built-in places, in its order.
    static let presets: [Place] = [
        Place(name: "Times Square", coordinate: .init(latitude: 40.7580, longitude: -73.9855)),
        Place(name: "Central Park", coordinate: .init(latitude: 40.7829, longitude: -73.9654)),
        Place(name: "Brooklyn Bridge", coordinate: .init(latitude: 40.7061, longitude: -73.9969)),
        Place(name: "San Francisco", coordinate: .init(latitude: 37.7749, longitude: -122.4194)),
        Place(name: "London", coordinate: .init(latitude: 51.5074, longitude: -0.1278)),
        Place(name: "Tokyo", coordinate: .init(latitude: 35.6762, longitude: 139.6503)),
        Place(name: "Dubai", coordinate: .init(latitude: 25.2048, longitude: 55.2708)),
    ]

    static var legacyDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".locationplus", isDirectory: true)
    }

    struct Result {
        var saved: [Place]
        var recent: [Place]
        var importedSaved: Int
        var importedRecent: Int
    }

    /// Runs once per install. Returns nil when it has already run.
    static func runIfNeeded(saved: [Place], recent: [Place]) -> Result? {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return nil }
        UserDefaults.standard.set(true, forKey: doneKey)
        var result = importLegacy(into: saved, recent: recent)
        if result.importedSaved == 0 && saved.isEmpty {
            result.saved = presets
        }
        return result
    }

    /// Merges the web version's data, skipping anything already present.
    static func importLegacy(into saved: [Place], recent: [Place]) -> Result {
        var saved = saved
        var recent = recent
        var importedSaved = 0
        var importedRecent = 0

        for entry in loadArray("saved_locations.json") {
            guard let c = coordinate(entry) else { continue }
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.contains(where: { $0.isNear(c) }) else { continue }
            var place = Place(name: (name?.isEmpty == false ? name! : c.formatted), coordinate: c)
            if let created = (entry["created_at"] as? String).flatMap(parseDate) { place.date = created }
            saved.append(place)
            importedSaved += 1
        }

        // History is newest-first; keep the first occurrence of each spot.
        for entry in loadArray("history.json") {
            guard recent.count < PlaceStore.recentLimit, let c = coordinate(entry) else { continue }
            guard !recent.contains(where: { $0.isNear(c) }) else { continue }
            let name = saved.first(where: { $0.isNear(c) })?.name ?? c.formatted
            var place = Place(name: name, coordinate: c)
            if let set = (entry["set_at"] as? String).flatMap(parseDate) { place.date = set }
            recent.append(place)
            importedRecent += 1
        }
        return Result(saved: saved, recent: recent, importedSaved: importedSaved, importedRecent: importedRecent)
    }

    static var hasLegacyData: Bool {
        FileManager.default.fileExists(atPath: legacyDir.appendingPathComponent("saved_locations.json").path)
            || FileManager.default.fileExists(atPath: legacyDir.appendingPathComponent("history.json").path)
    }

    /// Reads a JSON array, falling back to the `.bak` the web version kept.
    private static func loadArray(_ name: String) -> [[String: Any]] {
        for file in [name, name + ".bak"] {
            let url = legacyDir.appendingPathComponent(file)
            if let data = try? Data(contentsOf: url),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return array
            }
        }
        return []
    }

    private static func coordinate(_ entry: [String: Any]) -> CLLocationCoordinate2D? {
        guard let lat = (entry["lat"] as? NSNumber)?.doubleValue,
              let lng = (entry["lng"] as? NSNumber)?.doubleValue,
              (-90...90).contains(lat), (-180...180).contains(lng) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

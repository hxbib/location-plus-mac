import AppKit
import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI

struct ActivePin: Identifiable {
    let udid: String
    let name: String
    let device: Device?
    let pin: Pin
    var id: String { udid }
}

/// App state plus the bridge to the Python engine process.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let setup = Setup()

    // Devices & pins
    var devices: [Device] = []
    var tunnelRunning: Bool?
    var pins: [String: Pin] = [:] { didSet { persistPins() } }
    var selection: Set<String> = []
    var engineRunning = false
    var engineVersion: String?
    var engineFailed = false
    var lastError: String?
    var notice: String?

    // Map target
    var target: CLLocationCoordinate2D?
    var targetName: String?
    var camera: MapCameraPosition = .automatic

    // Places
    var saved: [Place] = PlaceStore.saved { didSet { PlaceStore.saved = saved } }
    var recent: [Place] = PlaceStore.recent { didSet { PlaceStore.recent = recent } }

    /// Pins that were active when the app last quit, offered for resuming.
    var resumable: [SavedPin] = []

    /// Device names survive unplugging so pins keep a readable label.
    private var knownNames: [String: String] = UserDefaults.standard.dictionary(forKey: "knownDeviceNames") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(knownNames, forKey: "knownDeviceNames") }
    }

    private var process: Process?
    private var engineInput: FileHandle?
    private var buffer = Data()
    private var geocodeTask: Task<Void, Never>?
    private var deliberateStop = false
    private var recentCrashes: [Date] = []
    private var didAutoSelect = false

    private static let resumeKey = "pinsAtQuit"

    private init() {
        if let result = Migration.runIfNeeded(saved: saved, recent: recent) {
            saved = result.saved
            recent = result.recent
            if result.importedSaved + result.importedRecent > 0 {
                notice = "Imported \(result.importedSaved) saved places and \(result.importedRecent) recent locations from the previous version."
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.resumeKey),
           let pins = try? JSONDecoder().decode([SavedPin].self, from: data) {
            resumable = pins
        }
        if let last = resumable.first?.coordinate ?? recent.first?.coordinate {
            camera = .region(MKCoordinateRegion(center: last, latitudinalMeters: 4000, longitudinalMeters: 4000))
        }
        if setup.engine.isDone { startEngine() }
        nameUnnamedPlaces()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppModel.shared.send(["cmd": "kick"]) }
        }
    }

    // MARK: Derived state

    var activePins: [ActivePin] {
        pins.filter { $0.value.state != .stopped }
            .sorted { $0.key < $1.key }
            .map { entry in
                ActivePin(udid: entry.key, name: name(for: entry.key),
                          device: devices.first { $0.udid == entry.key }, pin: entry.value)
            }
    }

    var isPinning: Bool { pins.values.contains { $0.state != .stopped } }

    var selectedDevices: [Device] { devices.filter { selection.contains($0.udid) } }

    /// Whether every selected device is already pinned at the current target.
    var selectionPinnedAtTarget: Bool {
        guard let target, !selection.isEmpty else { return false }
        return selection.allSatisfy { udid in
            guard let pin = pins[udid], pin.state != .stopped else { return false }
            return pin.coordinate.isNear(target)
        }
    }

    func name(for udid: String) -> String {
        devices.first(where: { $0.udid == udid })?.name ?? knownNames[udid] ?? "iPhone"
    }

    func placeName(for coordinate: CLLocationCoordinate2D) -> String {
        if let t = target, t.isNear(coordinate), let n = targetName { return n }
        return (saved + recent).first(where: { $0.isNear(coordinate) })?.name ?? coordinate.formatted
    }

    // MARK: Actions

    func setTarget(_ coordinate: CLLocationCoordinate2D, name: String? = nil, moveCamera: Bool = false) {
        target = coordinate
        let known = (saved + recent).first(where: { $0.isNear(coordinate) && !$0.hasPlaceholderName })?.name
        targetName = name ?? known
        if moveCamera {
            withAnimation(.smooth(duration: 0.6)) {
                camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))
            }
        }
        geocodeTask?.cancel()
        guard targetName == nil else { return }
        geocodeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let name = await Geocoder.name(for: coordinate)
            if !Task.isCancelled, self.target?.isNear(coordinate) == true {
                self.targetName = name
            }
        }
    }

    func pinSelection() {
        guard let target, !selection.isEmpty else { return }
        for udid in selection {
            var pin = pins[udid] ?? Pin(coordinate: target, state: .connecting)
            if pin.state == .stopped { pin = Pin(coordinate: target, state: .connecting) }
            pin.coordinate = target
            pin.error = nil
            pins[udid] = pin
            send(["cmd": "set", "udid": udid, "lat": target.latitude, "lng": target.longitude])
        }
        resumable = []
        addRecent(Place(name: targetName ?? target.formatted, coordinate: target))
    }

    func stop(_ udid: String) {
        pins[udid]?.state = .stopped
        send(["cmd": "clear", "udid": udid])
    }

    func stopSelection() {
        for udid in selection { stop(udid) }
    }

    func stopAll() {
        for udid in pins.keys { pins[udid]?.state = .stopped }
        send(["cmd": "clear_all"])
    }

    func resume() {
        for saved in resumable {
            pins[saved.udid] = Pin(coordinate: saved.coordinate, state: .connecting)
            send(["cmd": "set", "udid": saved.udid, "lat": saved.latitude, "lng": saved.longitude])
        }
        if let first = resumable.first { setTarget(first.coordinate, moveCamera: true) }
        resumable = []
    }

    func dismissResume() {
        resumable = []
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
    }

    func showOnMap(_ udid: String) {
        guard let pin = pins[udid], pin.state != .stopped else { return }
        setTarget(pin.coordinate, moveCamera: true)
    }

    func saveTarget() {
        guard let target else { return }
        if let i = saved.firstIndex(where: { $0.isNear(target) }) {
            saved.remove(at: i)
            return
        }
        saved.insert(Place(name: targetName ?? target.formatted, coordinate: target), at: 0)
        if targetName == nil { targetName = saved[0].name }
    }

    var targetIsSaved: Bool {
        guard let target else { return false }
        return saved.contains { $0.isNear(target) }
    }

    func importFromPreviousVersion() {
        let result = Migration.importLegacy(into: saved, recent: recent)
        saved = result.saved
        recent = result.recent
        notice = result.importedSaved + result.importedRecent == 0
            ? "Nothing new to import."
            : "Imported \(result.importedSaved) saved places and \(result.importedRecent) recent locations."
        nameUnnamedPlaces()
    }

    private func addRecent(_ place: Place) {
        recent.removeAll { $0.isNear(place.coordinate) }
        recent.insert(place, at: 0)
        if recent.count > PlaceStore.recentLimit { recent.removeLast(recent.count - PlaceStore.recentLimit) }
        nameUnnamedPlaces()
    }

    /// Replaces coordinate-only names with a reverse-geocoded one, gently (Apple rate-limits geocoding).
    private func nameUnnamedPlaces() {
        let pending = (saved + recent).filter(\.hasPlaceholderName).map(\.coordinate)
        guard !pending.isEmpty else { return }
        Task {
            for c in pending {
                guard let name = await Geocoder.name(for: c) else { continue }
                if let i = saved.firstIndex(where: { $0.isNear(c) && $0.hasPlaceholderName }) { saved[i].name = name }
                if let i = recent.firstIndex(where: { $0.isNear(c) && $0.hasPlaceholderName }) { recent[i].name = name }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    // MARK: Engine process

    func startEngine() {
        guard process == nil, setup.engine.isDone else { return }
        let p = Process()
        p.executableURL = setup.venvPython
        p.arguments = ["-u", Setup.engineScript.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Self.logHandle()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.consume(data) } }
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.engineExited() } }
        }
        do {
            try p.run()
            process = p
            engineInput = inPipe.fileHandleForWriting
            engineRunning = true
            engineFailed = false
            deliberateStop = false
        } catch {
            lastError = "Couldn't start the engine: \(error.localizedDescription)"
            engineFailed = true
        }
    }

    func restartEngine() {
        recentCrashes = []
        engineFailed = false
        if process == nil {
            startEngine()
            return
        }
        deliberateStop = true
        process?.terminate()
    }

    private func engineExited() {
        process = nil
        engineInput = nil
        buffer.removeAll()
        engineRunning = false
        devices = []
        tunnelRunning = nil
        let wasDeliberate = deliberateStop
        deliberateStop = false

        if !wasDeliberate {
            recentCrashes = recentCrashes.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
            if recentCrashes.count >= 4 {
                // Something is structurally wrong (broken venv, missing file). Don't spin.
                engineFailed = true
                setup.refresh()
                for udid in pins.keys { pins[udid]?.state = .stopped }
                return
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(wasDeliberate ? 0.2 : Double(recentCrashes.count)))
            startEngine()
            // Re-assert anything that was pinned when the engine went away.
            for (udid, pin) in pins where pin.state != .stopped {
                pins[udid]?.state = .reconnecting
                send(["cmd": "set", "udid": udid, "lat": pin.coordinate.latitude, "lng": pin.coordinate.longitude])
            }
        }
    }

    /// Called right before the app quits: remembers pins for next launch, then
    /// closes stdin, which makes the engine clear every pin and exit.
    func shutdown() {
        deliberateStop = true
        process?.terminationHandler = nil
        try? engineInput?.close()
        process?.waitUntilExitOrTimeout(5)
    }

    /// Saved continuously (not just at quit) so pins can be resumed after a crash or power loss too.
    private func persistPins() {
        let active = pins.filter { $0.value.state != .stopped }.sorted { $0.key < $1.key }.map {
            SavedPin(udid: $0.key, name: name(for: $0.key),
                     latitude: $0.value.coordinate.latitude, longitude: $0.value.coordinate.longitude)
        }
        guard let data = try? JSONEncoder().encode(active),
              data != UserDefaults.standard.data(forKey: Self.resumeKey) else { return }
        UserDefaults.standard.set(data, forKey: Self.resumeKey)
    }

    private func send(_ message: [String: Any]) {
        guard let engineInput, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        do {
            try engineInput.write(contentsOf: data)
        } catch {
            // Broken pipe: the engine died; engineExited() restarts it and re-pins.
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let msg = try? JSONDecoder().decode(EngineMessage.self, from: line) { handle(msg) }
        }
        if buffer.count > 4_000_000 { buffer.removeAll() }  // never let a bad stream grow unbounded
    }

    private func handle(_ msg: EngineMessage) {
        switch msg.type {
        case "ready":
            engineVersion = msg.version
            recentCrashes = []
        case "devices":
            tunnelRunning = msg.tunnel
            let list = msg.devices ?? []
            if list != devices { devices = list }
            for d in list where knownNames[d.udid] != d.name { knownNames[d.udid] = d.name }
            let ids = Set(list.map(\.udid))
            selection.formIntersection(ids.union(pins.filter { $0.value.state != .stopped }.keys))
            // Auto-select when a device first shows up, but respect a deliberate deselect.
            if list.isEmpty { didAutoSelect = false }
            if selection.isEmpty, !didAutoSelect, let first = list.first(where: \.ready) ?? list.first {
                selection = [first.udid]
                didAutoSelect = true
            }
        case "session":
            guard let udid = msg.udid, let state = msg.state.flatMap(PinState.init(rawValue:)) else { return }
            // Ignore late updates for a pin the user already stopped.
            if pins[udid]?.state == .stopped, state != .stopped { return }
            guard var pin = pins[udid] ?? msg.coordinate.map({ Pin(coordinate: $0, state: state) }) else { return }
            if state == .pinned && pin.state != .pinned { pin.since = Date() }
            pin.state = state
            pin.error = state == .stopped ? nil : msg.error
            pin.detail = msg.detail
            if let c = msg.coordinate { pin.coordinate = c }
            pins[udid] = pin
        case "error":
            lastError = msg.message
        default:
            break
        }
    }

    private static func logHandle() -> FileHandle? {
        let dir = logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("engine.log")
        // Rotate past 5 MB so the log can't grow without bound.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 5_000_000 {
            let old = dir.appendingPathComponent("engine.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        return handle
    }

    static var logDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Location+", isDirectory: true)
    }
}

private struct EngineMessage: Decodable {
    let type: String
    var tunnel: Bool?
    var devices: [Device]?
    var udid: String?
    var state: String?
    var lat: Double?
    var lng: Double?
    var error: String?
    var detail: String?
    var message: String?
    var version: String?

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return .init(latitude: lat, longitude: lng)
    }
}

private extension Process {
    func waitUntilExitOrTimeout(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning && Date() < deadline { usleep(50_000) }
        if isRunning { terminate() }
    }
}

extension CLLocationCoordinate2D {
    func isNear(_ other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 0.00005 && abs(longitude - other.longitude) < 0.00005
    }
}

enum Geocoder {
    static func name(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        var parts: [String] = []
        for p in [placemark.name, placemark.locality ?? placemark.administrativeArea ?? placemark.country]
        where p != nil && !parts.contains(p!) {
            parts.append(p!)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

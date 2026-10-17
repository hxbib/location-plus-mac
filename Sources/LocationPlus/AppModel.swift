import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI

struct ActivePin: Identifiable {
    let udid: String
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
    var pins: [String: Pin] = [:]
    var selection: Set<String> = []
    var engineRunning = false
    var lastError: String?

    // Map target
    var target: CLLocationCoordinate2D?
    var targetName: String?
    var camera: MapCameraPosition = .automatic

    // Places
    var saved: [Place] = PlaceStore.saved { didSet { PlaceStore.saved = saved } }
    var recent: [Place] = PlaceStore.recent { didSet { PlaceStore.recent = recent } }

    private var process: Process?
    private var engineInput: FileHandle?
    private var buffer = Data()
    private var geocodeTask: Task<Void, Never>?
    private var deliberateStop = false

    private init() {
        if let last = recent.first {
            camera = .region(MKCoordinateRegion(center: last.coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000))
        }
        if setup.engine.isDone { startEngine() }
    }

    // MARK: Derived state

    var activePins: [ActivePin] {
        pins.filter { $0.value.state != .stopped }
            .sorted { $0.key < $1.key }
            .map { entry in
                ActivePin(udid: entry.key, device: devices.first { $0.udid == entry.key }, pin: entry.value)
            }
    }

    var isPinning: Bool { !activePins.isEmpty }

    var selectedDevices: [Device] { devices.filter { selection.contains($0.udid) } }

    /// Whether every selected device is already pinned at the current target.
    var selectionPinnedAtTarget: Bool {
        guard let target, !selection.isEmpty else { return false }
        return selection.allSatisfy { udid in
            guard let pin = pins[udid], pin.state != .stopped else { return false }
            return Place(name: "", coordinate: pin.coordinate).isNear(target)
        }
    }

    func name(for udid: String) -> String {
        devices.first(where: { $0.udid == udid })?.name ?? "iPhone"
    }

    // MARK: Actions

    func setTarget(_ coordinate: CLLocationCoordinate2D, name: String? = nil, moveCamera: Bool = false) {
        target = coordinate
        targetName = name ?? saved.first(where: { $0.isNear(coordinate) })?.name
        if moveCamera {
            camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))
        }
        geocodeTask?.cancel()
        guard targetName == nil else { return }
        geocodeTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let name = await Geocoder.name(for: coordinate)
            if !Task.isCancelled, self.target.map({ Place(name: "", coordinate: $0).isNear(coordinate) }) == true {
                self.targetName = name
            }
        }
    }

    func pinSelection() {
        guard let target, !selection.isEmpty else { return }
        for udid in selection {
            var pin = pins[udid] ?? Pin(coordinate: target, state: .connecting)
            if pin.state == .stopped { pin.state = .connecting }
            pin.coordinate = target
            pin.error = nil
            pins[udid] = pin
            send(["cmd": "set", "udid": udid, "lat": target.latitude, "lng": target.longitude])
        }
        addRecent(Place(name: targetName ?? target.formatted, coordinate: target))
    }

    func stop(_ udid: String) {
        pins[udid]?.state = .stopped
        send(["cmd": "clear", "udid": udid])
    }

    func stopSelection() {
        selection.forEach(stop)
    }

    func stopAll() {
        for udid in pins.keys { pins[udid]?.state = .stopped }
        send(["cmd": "clear_all"])
    }

    func saveTarget(as name: String? = nil) {
        guard let target else { return }
        if let i = saved.firstIndex(where: { $0.isNear(target) }) {
            saved.remove(at: i)
            return
        }
        saved.insert(Place(name: name ?? targetName ?? target.formatted, coordinate: target), at: 0)
        targetName = saved[0].name
    }

    var targetIsSaved: Bool {
        guard let target else { return false }
        return saved.contains { $0.isNear(target) }
    }

    private func addRecent(_ place: Place) {
        recent.removeAll { $0.isNear(place.coordinate) }
        recent.insert(place, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
    }

    // MARK: Engine process

    func startEngine() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = setup.venvPython
        p.arguments = ["-u", Setup.engineScript.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Self.logHandle()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
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
            deliberateStop = false
        } catch {
            lastError = "Couldn't start the engine: \(error.localizedDescription)"
        }
    }

    func restartEngine() {
        deliberateStop = true
        process?.terminate()
    }

    private func engineExited() {
        process = nil
        engineInput = nil
        buffer.removeAll()
        engineRunning = false
        devices = []
        let wasDeliberate = deliberateStop
        Task {
            try? await Task.sleep(for: .seconds(wasDeliberate ? 0.2 : 1.5))
            startEngine()
            // Re-assert anything that was pinned when the engine went away.
            for (udid, pin) in pins where pin.state != .stopped {
                pins[udid]?.state = .reconnecting
                send(["cmd": "set", "udid": udid, "lat": pin.coordinate.latitude, "lng": pin.coordinate.longitude])
            }
        }
    }

    /// Called right before the app quits: closing stdin makes the engine clear every pin.
    func shutdown() {
        deliberateStop = true
        process?.terminationHandler = nil
        try? engineInput?.close()
        process?.waitUntilExitOrTimeout(4)
    }

    private func send(_ message: [String: Any]) {
        guard let engineInput, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? engineInput.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let msg = try? JSONDecoder().decode(EngineMessage.self, from: line) { handle(msg) }
        }
    }

    private func handle(_ msg: EngineMessage) {
        switch msg.type {
        case "devices":
            tunnelRunning = msg.tunnel
            devices = msg.devices ?? []
            let ids = Set(devices.map(\.udid))
            selection.formIntersection(ids.union(pins.keys))
            if selection.isEmpty, devices.count == 1 { selection = [devices[0].udid] }
        case "session":
            guard let udid = msg.udid, let state = msg.state.flatMap(PinState.init(rawValue:)) else { return }
            // Ignore late updates for a pin the user already stopped.
            if pins[udid]?.state == .stopped, state != .stopped { return }
            var pin = pins[udid] ?? Pin(coordinate: target ?? .init(), state: state)
            pin.state = state
            if state == .pinned || msg.error != nil || state == .connecting { pin.error = msg.error }
            if let lat = msg.lat, let lng = msg.lng { pin.coordinate = .init(latitude: lat, longitude: lng) }
            pins[udid] = pin
        case "error":
            lastError = msg.message
        default:
            break
        }
    }

    private static func logHandle() -> FileHandle? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Location+", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("engine.log")
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
    var message: String?
}

private extension Process {
    func waitUntilExitOrTimeout(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning && Date() < deadline { usleep(50_000) }
        if isRunning { terminate() }
    }
}

enum Geocoder {
    static func name(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let parts = [placemark.name, placemark.locality].compactMap { $0 }
        var unique: [String] = []
        for p in parts where !unique.contains(p) { unique.append(p) }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}

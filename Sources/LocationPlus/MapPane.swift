import AppKit
import MapKit
import SwiftUI

struct MapPane: View {
    @Environment(AppModel.self) private var model
    @State private var search = PlaceSearch()
    @AppStorage("mapStyle") private var mapStyle = MapStyleChoice.standard

    var body: some View {
        @Bindable var model = model
        MapReader { proxy in
            Map(position: $model.camera) {
                ForEach(model.activePins) { item in
                    if model.target?.isNear(item.pin.coordinate) != true {
                        Annotation(item.name, coordinate: item.pin.coordinate, anchor: .center) {
                            DeviceMarker(state: item.pin.state)
                                .onTapGesture { model.setTarget(item.pin.coordinate) }
                        }
                    }
                }
                if let target = model.target {
                    Annotation(model.targetName ?? "", coordinate: target, anchor: .bottom) {
                        TargetMarker(pinned: model.activePins.contains {
                            $0.pin.state == .pinned && $0.pin.coordinate.isNear(target)
                        })
                    }
                }
            }
            .mapStyle(mapStyle.style)
            .mapControls {
                MapCompass()
                MapPitchToggle()
                MapZoomStepper()
                MapScaleView()
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    withAnimation(.snappy(duration: 0.25)) { model.setTarget(coordinate) }
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                search.setRegion(context.region)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            PinCard()
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .overlay(alignment: .top) {
            Banners()
                .padding(.top, 12)
                .padding(.horizontal, 24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Map Style", selection: $mapStyle) {
                    ForEach(MapStyleChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Map style")
            }
        }
        .searchable(text: $search.query, placement: .toolbar, prompt: "Search places or paste coordinates")
        .searchSuggestions {
            if let coordinate = CLLocationCoordinate2D(parsing: search.query) {
                Button {
                    go(to: coordinate, name: nil)
                } label: {
                    Label("Go to \(coordinate.formatted)", systemImage: "scope")
                }
            }
            ForEach(search.results, id: \.self) { completion in
                Button {
                    Task {
                        if let result = await search.resolve(completion) {
                            go(to: result.coordinate, name: result.name)
                        }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(completion.title)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onSubmit(of: .search) {
            if let coordinate = CLLocationCoordinate2D(parsing: search.query) {
                go(to: coordinate, name: nil)
            } else if let first = search.results.first {
                Task {
                    if let result = await search.resolve(first) { go(to: result.coordinate, name: result.name) }
                }
            } else {
                Task {
                    if let result = await search.searchDirectly() { go(to: result.coordinate, name: result.name) }
                }
            }
        }
        .onChange(of: search.query) { search.update() }
    }

    private func go(to coordinate: CLLocationCoordinate2D, name: String?) {
        model.setTarget(coordinate, name: name, moveCamera: true)
        search.query = ""
    }
}

enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard, satellite

    var id: String { rawValue }
    var title: String { self == .standard ? "Map" : "Satellite" }
    var style: MapStyle {
        self == .standard ? .standard(elevation: .realistic) : .hybrid(elevation: .realistic)
    }
}

// MARK: - Markers

struct TargetMarker: View {
    let pinned: Bool
    @State private var dropped = false

    var body: some View {
        let color = pinned ? Color.green : Color.accentColor
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
                Image(systemName: pinned ? "location.fill" : "mappin")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            Triangle()
                .fill(color)
                .frame(width: 10, height: 7)
                .offset(y: -1)
        }
        .scaleEffect(dropped ? 1 : 0.4, anchor: .bottom)
        .offset(y: dropped ? 0 : -14)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: dropped)
        .animation(.snappy, value: pinned)
        .onAppear { dropped = true }
        .accessibilityLabel(pinned ? "Pinned location" : "Selected location")
    }
}

struct DeviceMarker: View {
    let state: PinState

    var body: some View {
        let color = state == .pinned ? Color.green : Color.orange
        ZStack {
            Circle().fill(color.opacity(0.25)).frame(width: 30, height: 30)
            Circle().fill(color).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .accessibilityLabel(state == .pinned ? "Pinned device" : "Reconnecting device")
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - Bottom card

struct PinCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let target = model.target {
                card(target)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Label("Click the map or search to choose a location", systemImage: "hand.point.up.left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: model.target == nil)
    }

    private var subtitle: String {
        let names = model.selectedDevices.map(\.name)
        if model.selectionPinnedAtTarget {
            return names.count == 1 ? "Pinned on \(names[0])" : "Pinned on \(names.count) devices"
        }
        switch names.count {
        case 0: return "No device selected"
        case 1: return "Will pin \(names[0])"
        default: return "Will pin \(names.count) devices"
        }
    }

    private func card(_ target: CLLocationCoordinate2D) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.targetName ?? "Dropped Pin")
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    HStack(spacing: 6) {
                        Text(target.formatted)
                            .font(.caption.monospacedDigit())
                            .textSelection(.enabled)
                        Text("·")
                        Text(subtitle).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.formatted, forType: .string)
                    model.notice = "Coordinates copied."
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Copy coordinates")
                .accessibilityLabel("Copy coordinates")

                Button {
                    withAnimation(.snappy) { model.saveTarget() }
                } label: {
                    Image(systemName: model.targetIsSaved ? "star.fill" : "star")
                        .foregroundStyle(model.targetIsSaved ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.primary))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(model.targetIsSaved ? "Remove from Places (⌘D)" : "Save to Places (⌘D)")
                .accessibilityLabel(model.targetIsSaved ? "Remove from Places" : "Save to Places")

                primaryButton
            }
            .controlSize(.large)
            .padding(.leading, 20)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: 640)
    }

    @ViewBuilder private var primaryButton: some View {
        let count = model.selection.count
        if count == 0 {
            Button("Select a Device") {}
                .buttonStyle(.glass)
                .disabled(true)
        } else if model.selectionPinnedAtTarget {
            Button {
                withAnimation(.snappy) { model.stopSelection() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .help("Restore real location")
        } else {
            Button {
                withAnimation(.snappy) { model.pinSelection() }
            } label: {
                Label(count == 1 ? "Pin Here" : "Pin \(count) Devices", systemImage: "location.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .help("Pin selected devices here (⌘↩)")
        }
    }
}

// MARK: - Banners

struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if model.engineFailed {
                Banner(text: "The engine keeps stopping. Reinstalling it usually fixes this.",
                       systemImage: "exclamationmark.octagon.fill", tint: .red) {
                    Button("Reinstall") {
                        Task {
                            await model.setup.installEngine()
                            model.restartEngine()
                        }
                    }
                    .disabled(model.setup.engine.isWorking)
                }
            } else if model.tunnelRunning == false {
                Banner(text: "The tunnel service isn't running, so iPhones can't connect.",
                       systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Button("Restart") { Task { await model.setup.restartTunnel() } }
                }
            }

            if !model.resumable.isEmpty {
                let names = Set(model.resumable.map(\.name)).sorted().joined(separator: ", ")
                Banner(text: "Resume pinning \(names) at \(model.placeName(for: model.resumable[0].coordinate))?",
                       systemImage: "arrow.clockwise.circle.fill", tint: .accentColor) {
                    Button("Resume") { withAnimation(.snappy) { model.resume() } }
                    Button {
                        withAnimation(.snappy) { model.dismissResume() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss")
                }
            }

            if let error = model.lastError {
                Banner(text: error, systemImage: "exclamationmark.circle.fill", tint: .red) {
                    Button {
                        withAnimation(.snappy) { model.lastError = nil }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss")
                }
                .task(id: error) {
                    try? await Task.sleep(for: .seconds(10))
                    withAnimation(.snappy) { if model.lastError == error { model.lastError = nil } }
                }
            }

            if let notice = model.notice {
                Banner(text: notice, systemImage: "checkmark.circle.fill", tint: .green) {
                    EmptyView()
                }
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(notice.count > 30 ? 6 : 2))
                    withAnimation(.snappy) { if model.notice == notice { model.notice = nil } }
                }
            }
        }
        .frame(maxWidth: 640)
        .animation(.snappy, value: model.tunnelRunning)
        .animation(.snappy, value: model.engineFailed)
        .animation(.snappy, value: model.notice)
        .animation(.snappy, value: model.lastError)
    }
}

struct Banner<Actions: View>: View {
    let text: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) { actions() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Search

@MainActor @Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = ""
    var results: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var region: MKCoordinateRegion?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func setRegion(_ region: MKCoordinateRegion) {
        self.region = region
        completer.region = region
    }

    func update() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || CLLocationCoordinate2D(parsing: q) != nil {
            completer.cancel()
            results = []
        } else {
            completer.queryFragment = q
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> (coordinate: CLLocationCoordinate2D, name: String)? {
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response?.mapItems.first else { return nil }
        return (item.placemark.coordinate, item.name ?? completion.title)
    }

    /// Plain search for when the user presses Return before suggestions arrive.
    func searchDirectly() async -> (coordinate: CLLocationCoordinate2D, name: String)? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let region { request.region = region }
        let response = try? await MKLocalSearch(request: request).start()
        guard let item = response?.mapItems.first else { return nil }
        return (item.placemark.coordinate, item.name ?? q)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = Array(completer.results.prefix(8))
        MainActor.assumeIsolated { self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

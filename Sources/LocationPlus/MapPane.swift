import AppKit
import MapKit
import SwiftUI

struct MapPane: View {
    @Environment(AppModel.self) private var model
    @State private var search = PlaceSearch()

    var body: some View {
        @Bindable var model = model
        MapReader { proxy in
            Map(position: $model.camera) {
                ForEach(model.activePins) { item in
                    if model.target.map({ Place(name: "", coordinate: item.pin.coordinate).isNear($0) }) != true {
                        Annotation(item.device?.name ?? "iPhone", coordinate: item.pin.coordinate, anchor: .center) {
                            DeviceMarker(state: item.pin.state)
                        }
                    }
                }
                if let target = model.target {
                    Annotation(model.targetName ?? "", coordinate: target, anchor: .bottom) {
                        TargetMarker(pinned: model.activePins.contains {
                            $0.pin.state == .pinned && Place(name: "", coordinate: $0.pin.coordinate).isNear(target)
                        })
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapPitchToggle()
                MapZoomStepper()
                MapScaleView()
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    withAnimation(.snappy) { model.setTarget(coordinate) }
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
            StatusBanner()
                .padding(.top, 12)
        }
        .searchable(text: $search.query, placement: .toolbar, prompt: "Search or paste coordinates")
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
            }
        }
        .onChange(of: search.query) { search.update() }
    }

    private func go(to coordinate: CLLocationCoordinate2D, name: String?) {
        withAnimation(.smooth) { model.setTarget(coordinate, name: name, moveCamera: true) }
        search.query = ""
    }
}

// MARK: - Markers

struct TargetMarker: View {
    let pinned: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(pinned ? Color.green : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                Image(systemName: pinned ? "location.fill" : "mappin")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            Triangle()
                .fill(pinned ? Color.green : Color.accentColor)
                .frame(width: 10, height: 7)
                .offset(y: -1)
        }
        .animation(.snappy, value: pinned)
    }
}

struct DeviceMarker: View {
    let state: PinState

    var body: some View {
        ZStack {
            Circle()
                .fill(state == .pinned ? Color.green : .orange)
                .frame(width: 18, height: 18)
            Circle().stroke(.white, lineWidth: 2.5).frame(width: 18, height: 18)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
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
            } else {
                Label("Click the map or search to choose a location", systemImage: "hand.tap")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .animation(.snappy, value: model.target == nil)
    }

    private func card(_ target: CLLocationCoordinate2D) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.targetName ?? "Dropped Pin")
                        .font(.headline)
                        .lineLimit(1)
                    Text(target.formatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.formatted, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Copy coordinates")

                Button {
                    withAnimation(.snappy) { model.saveTarget() }
                } label: {
                    Image(systemName: model.targetIsSaved ? "star.fill" : "star")
                        .foregroundStyle(model.targetIsSaved ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.primary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(model.targetIsSaved ? "Remove from Places (⌘D)" : "Save to Places (⌘D)")

                primaryButton
            }
            .controlSize(.large)
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: 620)
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
            .help("Restore real location (⌘.)")
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

// MARK: - Status banner

struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.tunnelRunning == false {
                banner("Tunnel service isn't running", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Button("Restart") { Task { await model.setup.restartTunnel() } }
                }
            } else if let error = model.lastError {
                banner(error, systemImage: "exclamationmark.circle.fill", tint: .red) {
                    Button("Dismiss") { model.lastError = nil }
                }
            }
        }
        .animation(.snappy, value: model.tunnelRunning)
    }

    private func banner(_ text: String, systemImage: String, tint: Color,
                        @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(2)
            action()
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
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

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func setRegion(_ region: MKCoordinateRegion) {
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

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = Array(completer.results.prefix(8))
        MainActor.assumeIsolated { self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

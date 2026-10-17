import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.setup.isComplete {
                MainView()
                    .transition(.opacity)
            } else {
                SetupView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: model.setup.isComplete)
    }
}

struct MainView: View {
    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 380)
        } detail: {
            MapPane()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Place?
    @State private var newName = ""

    /// Connected devices plus any pinned device that's currently disconnected.
    private var rows: [Device] {
        let offline = model.activePins
            .filter { pin in !model.devices.contains { $0.udid == pin.udid } }
            .map { Device.offline(udid: $0.udid, name: $0.name) }
        return model.devices + offline
    }

    var body: some View {
        List {
            Section("Devices") {
                if rows.isEmpty {
                    EmptyDevices()
                }
                ForEach(rows) { device in
                    DeviceRow(device: device)
                }
            }

            Section("Places") {
                if model.saved.isEmpty {
                    Text("Press ☆ on a location to save it here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.saved) { place in
                    PlaceRow(place: place, symbol: "star.fill", tint: .yellow)
                        .contextMenu {
                            Button("Rename…") {
                                newName = place.name
                                renaming = place
                            }
                            copyButton(place)
                            Divider()
                            Button("Remove", role: .destructive) {
                                withAnimation { model.saved.removeAll { $0.id == place.id } }
                            }
                        }
                }
                .onMove { model.saved.move(fromOffsets: $0, toOffset: $1) }
            }

            if !model.recent.isEmpty {
                Section {
                    ForEach(model.recent) { place in
                        PlaceRow(place: place, symbol: "clock.arrow.circlepath", tint: .secondary)
                            .contextMenu {
                                if !model.saved.contains(where: { $0.isNear(place.coordinate) }) {
                                    Button("Save to Places") {
                                        withAnimation {
                                            model.saved.insert(Place(name: place.name, coordinate: place.coordinate), at: 0)
                                        }
                                    }
                                }
                                copyButton(place)
                                Divider()
                                Button("Remove", role: .destructive) {
                                    withAnimation { model.recent.removeAll { $0.id == place.id } }
                                }
                                Button("Clear Recents", role: .destructive) {
                                    withAnimation { model.recent.removeAll() }
                                }
                            }
                    }
                } header: {
                    Text("Recent")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
        .alert("Rename Place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renaming?.id, let i = model.saved.firstIndex(where: { $0.id == id }), !name.isEmpty {
                    model.saved[i].name = name
                    if model.target.map(model.saved[i].isNear) == true { model.targetName = name }
                }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func copyButton(_ place: Place) -> some View {
        Button("Copy Coordinates") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(place.coordinate.formatted, forType: .string)
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if model.engineFailed || model.tunnelRunning == false { return .orange }
        return model.engineRunning && model.tunnelRunning == true ? .green : .secondary
    }

    private var text: String {
        if model.engineFailed { return "Engine stopped" }
        if !model.engineRunning { return "Starting engine…" }
        switch model.tunnelRunning {
        case true?: return "Ready"
        case false?: return "Tunnel service not running"
        case nil: return "Connecting to tunnel…"
        }
    }
}

private struct EmptyDevices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.engineRunning ? "No iPhone connected" : "Starting…")
                .foregroundStyle(.secondary)
            if model.engineRunning {
                Text("Connect your iPhone with a cable, unlock it, and tap Trust if asked.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

extension Device {
    static func offline(udid: String, name: String) -> Device {
        Device(udid: udid, name: name, model: "", osVersion: "", connection: "", ready: false,
               issue: "Disconnected. Will re-pin when it's back.")
    }
}

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: Device

    private var selected: Bool { model.selection.contains(device.udid) }
    private var pin: Pin? {
        guard let p = model.pins[device.udid], p.state != .stopped else { return nil }
        return p
    }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if selected { model.selection.remove(device.udid) } else { model.selection.insert(device.udid) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))

                Image(systemName: device.symbol)
                    .font(.title2)
                    .frame(width: 26)
                    .foregroundStyle(device.ready || pin != nil ? .primary : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).fontWeight(.medium).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let pin {
                    StatusBadge(state: pin.state)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pin?.error ?? device.issue ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(selected ? "Selected for pinning" : "Select for pinning")
        .contextMenu {
            if pin != nil {
                Button("Show on Map") { model.showOnMap(device.udid) }
                Button("Stop") { model.stop(device.udid) }
                Divider()
            }
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.udid, forType: .string)
            }
        }
    }

    private var detail: String {
        if let pin {
            if let error = pin.error { return error }
            if let detail = pin.detail { return detail }
            if pin.state == .pinned { return "At \(model.placeName(for: pin.coordinate))" }
        }
        if let issue = device.issue { return issue }
        return device.subtitle
    }

    private var detailIsWarning: Bool {
        if let pin { return pin.error != nil }
        return device.issue != nil
    }
}

struct StatusBadge: View {
    let state: PinState

    var body: some View {
        let color = state == .pinned ? Color.green : Color.orange
        HStack(spacing: 4) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting")
            case .pinned:
                Circle().fill(color).frame(width: 6, height: 6)
                Text("Pinned")
            case .reconnecting:
                ProgressView().controlSize(.mini)
                Text("Reconnecting")
            case .stopped:
                EmptyView()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct PlaceRow: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let symbol: String
    let tint: Color

    var body: some View {
        let isTarget = model.target.map(place.isNear) == true
        Button {
            model.setTarget(place.coordinate, name: place.hasPlaceholderName ? nil : place.name, moveCamera: true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name).lineLimit(1)
                    Text(place.coordinate.formatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isTarget {
                    Image(systemName: "mappin")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show on map")
    }
}

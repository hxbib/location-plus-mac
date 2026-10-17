import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.setup.isComplete {
            MainView()
        } else {
            SetupView()
        }
    }
}

struct MainView: View {
    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
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

    var body: some View {
        List {
            Section("Devices") {
                if model.devices.isEmpty {
                    EmptyDevices()
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
                }
            }

            if !model.saved.isEmpty {
                Section("Places") {
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
                                    model.saved.removeAll { $0.id == place.id }
                                }
                            }
                    }
                    .onMove { model.saved.move(fromOffsets: $0, toOffset: $1) }
                }
            }

            if !model.recent.isEmpty {
                Section("Recent") {
                    ForEach(model.recent) { place in
                        PlaceRow(place: place, symbol: "clock.arrow.circlepath", tint: .secondary)
                            .contextMenu {
                                Button("Save to Places") {
                                    model.saved.insert(Place(name: place.name, coordinate: place.coordinate), at: 0)
                                }
                                copyButton(place)
                                Divider()
                                Button("Remove", role: .destructive) {
                                    model.recent.removeAll { $0.id == place.id }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("Rename Place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let id = renaming?.id, let i = model.saved.firstIndex(where: { $0.id == id }),
                   !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.saved[i].name = newName
                }
                renaming = nil
            }
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

private struct EmptyDevices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.engineRunning ? "No devices connected" : "Starting…")
                .foregroundStyle(.secondary)
            if model.engineRunning {
                Text("Connect your iPhone with a cable and keep it unlocked.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
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
            if selected { model.selection.remove(device.udid) } else { model.selection.insert(device.udid) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))

                Image(systemName: device.symbol)
                    .font(.title2)
                    .frame(width: 26)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).fontWeight(.medium).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
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
        .contextMenu {
            if pin != nil {
                Button("Stop") { model.stop(device.udid) }
            }
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.udid, forType: .string)
            }
        }
    }

    private var detail: String {
        if let error = pin?.error { return error }
        if pin == nil, let issue = device.issue { return issue }
        return device.subtitle
    }

    private var detailIsWarning: Bool { pin?.error != nil || (pin == nil && device.issue != nil) }
}

struct StatusBadge: View {
    let state: PinState

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting")
            case .pinned:
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Pinned")
            case .reconnecting:
                ProgressView().controlSize(.mini)
                Text("Reconnecting")
            case .stopped:
                EmptyView()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(state == .pinned ? Color.green : Color.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((state == .pinned ? Color.green : .orange).opacity(0.14), in: .capsule)
    }
}

struct PlaceRow: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let symbol: String
    let tint: Color

    var body: some View {
        Button {
            model.setTarget(place.coordinate, name: place.name, moveCamera: true)
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
                if model.target.map(place.isNear) == true {
                    Image(systemName: "mappin")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

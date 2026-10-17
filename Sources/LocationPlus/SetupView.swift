import AppKit
import ServiceManagement
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var running = false

    private var setup: Setup { model.setup }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Text("Welcome to Location+")
                    .font(.largeTitle.weight(.semibold))
                Text("Pin your iPhone's location from your Mac.\nOne-time setup takes about a minute.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                StepRow(number: 1, title: "Install the engine",
                        detail: "Downloads a private copy of Python and pymobiledevice3. Needs internet.",
                        status: setup.engine)
                Divider().padding(.leading, 52)
                StepRow(number: 2, title: "Install the tunnel service",
                        detail: "Lets your Mac talk to iOS 17 and later. You'll enter your Mac password once.",
                        status: setup.tunnel)
                Divider().padding(.leading, 52)
                StepRow(number: 3, title: "Prepare your iPhone",
                        detail: "Turn on Developer Mode in Settings › Privacy & Security, connect it with a cable, unlock it and tap Trust.",
                        status: nil)
            }
            .padding(.vertical, 6)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator, lineWidth: 0.5))
            .frame(maxWidth: 540)

            Button {
                Task { await runSetup() }
            } label: {
                Text(buttonTitle)
                    .frame(minWidth: 170)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(running)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buttonTitle: String {
        if running { return "Setting Up…" }
        if case .failed = setup.engine { return "Try Again" }
        if case .failed = setup.tunnel { return "Try Again" }
        return setup.engine.isDone ? "Continue" : "Set Up"
    }

    private func runSetup() async {
        running = true
        defer { running = false }
        if !setup.engine.isDone {
            await setup.installEngine()
            guard setup.engine.isDone else { return }
        }
        model.startEngine()
        if !setup.tunnel.isDone {
            await setup.installTunnel()
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String
    let status: Setup.Status?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            indicator
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch status ?? .pending {
                case .working(let message):
                    Text(message).font(.callout).foregroundStyle(Color.accentColor)
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.snappy, value: status)
    }

    @ViewBuilder private var indicator: some View {
        switch status ?? .pending {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .working:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.title2).foregroundStyle(.red)
        default:
            Text(status == nil ? "" : "\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: .circle)
                .overlay {
                    if status == nil {
                        Image(systemName: "iphone").font(.caption).foregroundStyle(.secondary)
                    }
                }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Location+").font(.headline)
                Spacer()
                if model.isPinning {
                    Text("\(model.activePins.count) pinned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.activePins.isEmpty {
                Text(model.devices.isEmpty ? "No iPhone connected" : "Not pinning any devices")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.activePins) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.device?.symbol ?? "iphone")
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.pin.error ?? model.placeName(for: item.pin.coordinate))
                                    .font(.caption)
                                    .foregroundStyle(item.pin.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                                    .lineLimit(1)
                            }
                            Spacer()
                            StatusBadge(state: item.pin.state)
                            Button {
                                model.stop(item.udid)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Stop")
                            .accessibilityLabel("Stop \(item.name)")
                        }
                    }
                }
            }

            if model.tunnelRunning == false || model.engineFailed {
                Label(model.engineFailed ? "Engine stopped. Open Location+ to fix." : "Tunnel service isn't running.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Button("Open Location+") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                if model.isPinning {
                    Button("Stop All", role: .destructive) { model.stopAll() }
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Location+")
                .accessibilityLabel("Quit Location+")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 310)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.lastError = "Couldn't change login item: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Location+ lives in the menu bar, so closing the window keeps your pins active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tunnel Service") {
                LabeledContent("Status") {
                    Text(tunnelStatus).foregroundStyle(model.tunnelRunning == true ? Color.green : Color.secondary)
                }
                HStack {
                    Button("Restart") { run { await model.setup.restartTunnel() } }
                    Button("Reinstall") { run { await model.setup.installTunnel() } }
                    Spacer()
                    Button("Uninstall", role: .destructive) { run { await model.setup.uninstallTunnel() } }
                }
                .disabled(busy)
            }

            Section("Engine") {
                LabeledContent("pymobiledevice3") { Text(model.engineVersion ?? "—").monospacedDigit() }
                HStack {
                    Button("Restart Engine") { model.restartEngine() }
                    Button("Reinstall Engine") {
                        run {
                            await model.setup.installEngine()
                            model.restartEngine()
                        }
                    }
                    Spacer()
                    Button("Show Logs") { NSWorkspace.shared.open(AppModel.logDirectory) }
                }
                .disabled(busy)
                if case .working(let message) = model.setup.engine {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else if case .failed(let message) = model.setup.engine {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Places") {
                HStack {
                    Button("Import from Previous Version") { model.importFromPreviousVersion() }
                        .disabled(!Migration.hasLegacyData)
                    Button("Add Original Presets") {
                        for preset in Migration.presets where !model.saved.contains(where: { $0.isNear(preset.coordinate) }) {
                            model.saved.append(preset)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tunnelStatus: String {
        switch model.tunnelRunning {
        case true?: return "Running"
        case false?: return model.setup.tunnel.isDone ? "Not running" : "Not installed"
        case nil: return "Checking…"
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

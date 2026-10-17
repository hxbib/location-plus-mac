import AppKit
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
                    .frame(width: 88, height: 88)
                Text("Welcome to Location+")
                    .font(.largeTitle.weight(.semibold))
                Text("Pin your iPhone's location from your Mac. Two quick steps and you're set.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                StepRow(number: 1, title: "Install the engine",
                        detail: "Sets up pymobiledevice3 in a private Python environment.",
                        status: mergedEngineStatus)
                Divider().padding(.leading, 52)
                StepRow(number: 2, title: "Install the tunnel service",
                        detail: "Lets your Mac talk to your iPhone. You'll enter your password once.",
                        status: setup.tunnel)
                Divider().padding(.leading, 52)
                StepRow(number: 3, title: "Prepare your iPhone",
                        detail: "Turn on Developer Mode in Settings › Privacy & Security, connect it with a cable, and tap Trust.",
                        status: nil)
            }
            .padding(.vertical, 6)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            .frame(maxWidth: 520)

            Button {
                Task { await runSetup() }
            } label: {
                Text(running ? "Setting Up…" : "Set Up")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(running)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Python lookup failures surface on the engine step.
    private var mergedEngineStatus: Setup.Status {
        if case .failed = setup.python { return setup.python }
        if case .working = setup.python { return setup.python }
        return setup.engine
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
                switch status ?? .pending {
                case .working(let message):
                    Text(message).font(.callout).foregroundStyle(Color.accentColor)
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var indicator: some View {
        switch status ?? .pending {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .working:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.title2).foregroundStyle(.red)
        default:
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: .circle)
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
                Text("Not pinning any devices")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.activePins) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.device?.symbol ?? "iphone")
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.device?.name ?? "iPhone").lineLimit(1)
                                Text(placeName(item.pin))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        }
                    }
                }
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
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func placeName(_ pin: Pin) -> String {
        (model.saved + model.recent).first(where: { $0.isNear(pin.coordinate) })?.name ?? pin.coordinate.formatted
    }
}

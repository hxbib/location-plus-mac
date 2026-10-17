import AppKit
import SwiftUI

@main
struct LocationPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Location+", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Location") {
                Button("Pin Selected Devices") { model.pinSelection() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.target == nil || model.selection.isEmpty)
                Button("Stop All") { model.stopAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isPinning)
                Divider()
                Button(model.targetIsSaved ? "Remove from Places" : "Save to Places") { model.saveTarget() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.target == nil)
            }
            CommandGroup(after: .appSettings) {
                Button("Restart Tunnel Service…") { Task { await model.setup.restartTunnel() } }
                Button("Reinstall Engine…") {
                    Task {
                        await model.setup.installEngine()
                        model.restartEngine()
                    }
                }
                Button("Show Logs") { NSWorkspace.shared.open(AppModel.logDirectory) }
                Divider()
                Button("Uninstall Tunnel Service…") { Task { await model.setup.uninstallTunnel() } }
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.isPinning ? "location.fill" : "location")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            if model.isPinning {
                let alert = NSAlert()
                alert.messageText = "Quit Location+?"
                alert.informativeText = "Your pinned devices will go back to their real location."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            model.shutdown()
            return .terminateNow
        }
    }
}

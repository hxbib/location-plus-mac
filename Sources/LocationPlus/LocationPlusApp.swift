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
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Location") {
                Button("Pin Selected Devices Here") { model.pinSelection() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.target == nil || model.selection.isEmpty)
                Button("Stop Selected Devices") { model.stopSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!model.selection.contains { model.pins[$0].map { $0.state != .stopped } ?? false })
                Button("Stop All") { model.stopAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isPinning)
                Divider()
                Button(model.targetIsSaved ? "Remove from Places" : "Save to Places") { model.saveTarget() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.target == nil)
                Button("Copy Coordinates") {
                    if let t = model.target {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t.formatted, forType: .string)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.target == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Show Logs") { NSWorkspace.shared.open(AppModel.logDirectory) }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.isPinning ? "location.fill" : "location")
                .accessibilityLabel(model.isPinning ? "Location+ — pinning" : "Location+")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would fight over the same devices; hand off to the running one.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if let other = others.first {
            other.activate()
            exit(0)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            // Reopen the main window when the Dock icon is clicked.
            for window in sender.windows where window.identifier?.rawValue.contains("main") == true {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            if model.isPinning {
                let alert = NSAlert()
                alert.messageText = "Quit Location+?"
                alert.informativeText = "Pinned devices will go back to their real location. You can resume next time you open the app."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            model.shutdown()
            return .terminateNow
        }
    }
}

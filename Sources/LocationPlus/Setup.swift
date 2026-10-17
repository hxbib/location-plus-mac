import AppKit
import Foundation
import Observation

/// Owns everything the engine needs on disk: a Python, a venv with
/// pymobiledevice3, and the root launchd job that runs `tunneld`.
@MainActor @Observable
final class Setup {
    enum Status: Equatable {
        case pending, working(String), done, failed(String)

        var isDone: Bool { self == .done }
        var isWorking: Bool { if case .working = self { return true } else { return false } }
    }

    static let daemonLabel = "com.hxbib.locationplus.tunneld"
    static let daemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(daemonLabel).plist")

    var python: Status = .pending
    var engine: Status = .pending
    var tunnel: Status = .pending

    private(set) var pythonPath: String?

    var isComplete: Bool { engine.isDone && tunnel.isDone }

    let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Location+", isDirectory: true)
    }()

    var venvDir: URL { supportDir.appendingPathComponent("venv", isDirectory: true) }
    var venvPython: URL { venvDir.appendingPathComponent("bin/python3") }
    private var marker: URL { supportDir.appendingPathComponent("engine-requirements.txt") }

    static func resource(_ name: String, _ ext: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        // `swift run` from a checkout: Sources/LocationPlus/Setup.swift -> engine/
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/\(name).\(ext)")
    }

    static var engineScript: URL { resource("engine", "py") }
    static var requirements: URL { resource("requirements", "txt") }

    init() {
        refresh()
    }

    /// Cheap checks only; safe to call at launch.
    func refresh() {
        let wanted = try? String(contentsOf: Self.requirements, encoding: .utf8)
        let installed = try? String(contentsOf: marker, encoding: .utf8)
        if FileManager.default.isExecutableFile(atPath: venvPython.path), wanted != nil, wanted == installed {
            engine = .done
            python = .done
        }
        tunnel = FileManager.default.fileExists(atPath: Self.daemonPlist.path) ? .done : .pending
    }

    // MARK: Python

    private static let pythonCandidates: [String] = {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin",
                    "/Library/Frameworks/Python.framework/Versions/Current/bin"]
        let names = ["python3.14", "python3.13", "python3.12", "python3.11", "python3"]
        return dirs.flatMap { d in names.map { "\(d)/\($0)" } }
    }()

    func findPython() async -> String? {
        python = .working("Looking for Python…")
        for path in Self.pythonCandidates where FileManager.default.isExecutableFile(atPath: path) {
            let r = await Shell.run(path, ["-c", "import sys; print(sys.version_info[0] * 100 + sys.version_info[1])"])
            if r.status == 0, let v = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 311 {
                pythonPath = path
                python = .done
                return path
            }
        }
        python = .failed("Python 3.11 or newer is needed. Install it with: brew install python@3.13")
        return nil
    }

    // MARK: Engine venv

    func installEngine() async {
        guard let py = await findPython() else { return }
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        } catch {
            engine = .failed(error.localizedDescription)
            return
        }
        engine = .working("Creating environment…")
        var r = await Shell.run(py, ["-m", "venv", "--clear", venvDir.path])
        guard r.status == 0 else { engine = .failed(r.lastLine); return }

        engine = .working("Installing pymobiledevice3… this takes a minute")
        r = await Shell.run(venvPython.path, ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check",
                                              "-r", Self.requirements.path])
        guard r.status == 0 else { engine = .failed(r.lastLine); return }

        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.copyItem(at: Self.requirements, to: marker)
        engine = .done
    }

    // MARK: Tunnel launchd job

    private var daemonPlistData: Data {
        let plist: [String: Any] = [
            "Label": Self.daemonLabel,
            "ProgramArguments": [venvPython.path, "-m", "pymobiledevice3", "remote", "tunneld"],
            "EnvironmentVariables": ["PYTHONDONTWRITEBYTECODE": "1"],  // no root-owned .pyc in the user's venv
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "/Library/Logs/LocationPlus-tunneld.log",
            "StandardErrorPath": "/Library/Logs/LocationPlus-tunneld.log",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    func installTunnel() async {
        tunnel = .working("Waiting for your password…")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.daemonLabel).plist")
        do {
            try daemonPlistData.write(to: tmp)
        } catch {
            tunnel = .failed(error.localizedDescription)
            return
        }
        let dest = Self.daemonPlist.path
        let script = """
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null; \
        cp '\(tmp.path)' '\(dest)' && chown root:wheel '\(dest)' && chmod 644 '\(dest)' && \
        launchctl bootstrap system '\(dest)'
        """
        if let error = await Self.runAsAdmin(script, prompt: "Location+ needs to install its device tunnel service.") {
            tunnel = .failed(error)
        } else {
            tunnel = .done
        }
    }

    func uninstallTunnel() async {
        let script = "launchctl bootout system/\(Self.daemonLabel) 2>/dev/null; rm -f '\(Self.daemonPlist.path)'"
        if await Self.runAsAdmin(script, prompt: "Location+ will remove its device tunnel service.") == nil {
            tunnel = .pending
        }
    }

    func restartTunnel() async {
        _ = await Self.runAsAdmin("launchctl kickstart -k system/\(Self.daemonLabel)",
                                  prompt: "Location+ will restart its device tunnel service.")
    }

    /// Runs a shell command as root via the standard macOS password dialog.
    /// Returns nil on success, or an error message.
    private static func runAsAdmin(_ command: String, prompt: String) async -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        return await Task.detached { () -> String? in
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return nil }
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
            return error[NSAppleScript.errorMessage] as? String ?? "Couldn't get administrator access."
        }.value
    }
}

enum Shell {
    struct Output {
        let status: Int32
        let output: String
        var lastLine: String {
            output.split(separator: "\n").last.map(String.init) ?? "Exited with status \(status)"
        }
    }

    static func run(_ executable: String, _ args: [String]) async -> Output {
        await Task.detached { () -> Output in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return Output(status: -1, output: error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Output(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

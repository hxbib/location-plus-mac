import AppKit
import CryptoKit
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
    static let tunnelLog = "/Library/Logs/LocationPlus-tunneld.log"

    var engine: Status = .pending
    var tunnel: Status = .pending

    var isComplete: Bool { engine.isDone && tunnel.isDone }

    let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Location+", isDirectory: true)
    }()

    var pythonDir: URL { supportDir.appendingPathComponent("python", isDirectory: true) }
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
        // isExecutableFile follows the venv's symlink, so a deleted base Python reads as not installed.
        let ok = FileManager.default.isExecutableFile(atPath: venvPython.path) && wanted != nil && wanted == installed
        if ok { engine = .done } else if engine.isDone { engine = .pending }
        tunnel = daemonMatches ? .done : .pending
    }

    /// The launchd job exists and points at this user's engine Python.
    private var daemonMatches: Bool {
        guard let data = try? Data(contentsOf: Self.daemonPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return false }
        return args.first == venvPython.path
    }

    // MARK: Python

    private struct PythonBuild {
        let url: URL
        let sha256: String
    }

    private static let pythonRelease = "https://github.com/astral-sh/python-build-standalone/releases/download/20261013"

    private static var pythonBuild: PythonBuild {
        if isAppleSilicon {
            return PythonBuild(
                url: URL(string: "\(pythonRelease)/cpython-3.13.16%2B20261013-aarch64-apple-darwin-install_only_stripped.tar.gz")!,
                sha256: "16a5332fb0dcb77f163fc8f8cbccd95be1644cc53e68e5d2a79f50afd6680a0e")
        }
        return PythonBuild(
            url: URL(string: "\(pythonRelease)/cpython-3.13.16%2B20261013-x86_64-apple-darwin-install_only_stripped.tar.gz")!,
            sha256: "f507ae04eb7747cd97cb484e8c5d83936cbfc52d9b08a1f35c00b47c707b1ae1")
    }

    /// True on Apple silicon even when this process runs under Rosetta.
    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// A private, pinned CPython in Application Support; falls back to a system Python 3.11+.
    private func provisionPython() async throws -> String {
        let managed = pythonDir.appendingPathComponent("bin/python3")
        if await Self.pythonVersion(managed.path) != nil { return managed.path }

        engine = .working("Downloading Python…")
        do {
            let build = Self.pythonBuild
            let (file, response) = try await URLSession.shared.download(from: build.url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SetupError("Download failed.") }
            let digest = try SHA256.hash(data: Data(contentsOf: file, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == build.sha256 else { throw SetupError("Python download was corrupted. Try again.") }

            engine = .working("Unpacking Python…")
            try? FileManager.default.removeItem(at: pythonDir)
            let r = await Shell.run("/usr/bin/tar", ["-xzf", file.path, "-C", supportDir.path])
            guard r.status == 0, await Self.pythonVersion(managed.path) != nil else { throw SetupError(r.lastLine) }
            return managed.path
        } catch {
            if let system = await Self.systemPython() { return system }
            throw SetupError("Couldn't download Python. Check your internet connection and try again. (\(error.localizedDescription))")
        }
    }

    private static func systemPython() async -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/Library/Frameworks/Python.framework/Versions/Current/bin"]
        let names = ["python3.14", "python3.13", "python3.12", "python3.11", "python3"]
        for path in dirs.flatMap({ d in names.map { "\(d)/\($0)" } }) {
            if let v = await pythonVersion(path), v >= 311 { return path }
        }
        return nil
    }

    /// e.g. 313 for Python 3.13, or nil if it doesn't run.
    private static func pythonVersion(_ path: String) async -> Int? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let r = await Shell.run(path, ["-c", "import sys; print(sys.version_info[0] * 100 + sys.version_info[1])"])
        return r.status == 0 ? Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    // MARK: Engine venv

    func installEngine() async {
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let python = try await provisionPython()

            engine = .working("Creating environment…")
            var r = await Shell.run(python, ["-m", "venv", "--clear", venvDir.path])
            guard r.status == 0 else { throw SetupError(r.lastLine) }

            engine = .working("Installing pymobiledevice3… this takes a minute")
            try? FileManager.default.removeItem(at: marker)
            r = await Shell.run(venvPython.path, ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check",
                                                  "--no-input", "-r", Self.requirements.path])
            guard r.status == 0 else {
                let offline = r.output.contains("NewConnectionError") || r.output.contains("Temporary failure")
                throw SetupError(offline ? "No internet connection. Connect and try again." : r.lastLine)
            }

            engine = .working("Checking…")
            r = await Shell.run(venvPython.path, ["-c", "import pymobiledevice3.services.dvt.instruments.location_simulation"])
            guard r.status == 0 else { throw SetupError(r.lastLine) }

            try FileManager.default.copyItem(at: Self.requirements, to: marker)
            engine = .done
            // A changed venv path means the tunnel job must be rewritten.
            if !daemonMatches { tunnel = .pending }
        } catch {
            engine = .failed((error as? SetupError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: Tunnel launchd job

    private var daemonPlistData: Data {
        let plist: [String: Any] = [
            "Label": Self.daemonLabel,
            "ProgramArguments": [venvPython.path, "-m", "pymobiledevice3", "remote", "tunneld"],
            "EnvironmentVariables": ["PYTHONDONTWRITEBYTECODE": "1"],  // no root-owned .pyc in the user's venv
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "StandardOutPath": Self.tunnelLog,
            "StandardErrorPath": Self.tunnelLog,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    func installTunnel() async {
        tunnel = .working("Waiting for your password…")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.daemonLabel).plist")
        do {
            try daemonPlistData.write(to: tmp, options: .atomic)
        } catch {
            tunnel = .failed(error.localizedDescription)
            return
        }
        let dest = Self.daemonPlist.path
        let log = Self.tunnelLog
        // Truncate an oversized log so it can't grow without bound across reinstalls.
        let script = """
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null; \
        cp '\(tmp.path)' '\(dest)' && chown root:wheel '\(dest)' && chmod 644 '\(dest)' && \
        { [ ! -f '\(log)' ] || [ $(stat -f %z '\(log)') -lt 10000000 ] || : > '\(log)'; } && \
        launchctl bootstrap system '\(dest)'
        """
        if let error = await Self.runAsAdmin(script, prompt: "Location+ needs to install its device tunnel service.") {
            tunnel = .failed(error)
        } else {
            tunnel = .done
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func uninstallTunnel() async {
        let script = "launchctl bootout system/\(Self.daemonLabel) 2>/dev/null; rm -f '\(Self.daemonPlist.path)'"
        if await Self.runAsAdmin(script, prompt: "Location+ will remove its device tunnel service.") == nil {
            tunnel = .pending
        }
    }

    func restartTunnel() async {
        guard daemonMatches else {
            await installTunnel()
            return
        }
        let script = """
        launchctl kickstart -k system/\(Self.daemonLabel) 2>/dev/null || \
        launchctl bootstrap system '\(Self.daemonPlist.path)'
        """
        _ = await Self.runAsAdmin(script, prompt: "Location+ will restart its device tunnel service.")
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

struct SetupError: Error {
    let message: String
    init(_ message: String) { self.message = message }
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
            var env = ProcessInfo.processInfo.environment
            env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
            env.removeValue(forKey: "PYTHONPATH")
            env.removeValue(forKey: "PYTHONHOME")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return Output(status: -1, output: error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Output(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

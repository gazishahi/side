import Foundation
import SideAgents

/// What Side proposes to debug when a project doesn't say (SIDE_RFC_DEBUGGER.md, Q3), and the
/// adapter that debugs it. Step 1: a Swift package's executables under lldb-dap.
enum DebugLaunch {
    /// lldb-dap, from the selected Xcode or Command Line Tools (nil without either).
    nonisolated static func lldbDAP() -> URL? {
        if let cached = cachedAdapter.withLock({ $0 }) { return cached }
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "lldb-dap"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        cachedAdapter.withLock { $0 = url }
        return url
    }
    nonisolated private static let cachedAdapter = DebugLockedBox<URL?>(nil)
    nonisolated static func forgetLLDBDAP() { cachedAdapter.withLock { $0 = nil } }

    enum Failure: Error, LocalizedError {
        case notAPackage
        case noExecutable
        case noAdapter
        case describe(String)
        var errorDescription: String? {
            switch self {
            case .notAPackage: return "Debugging needs a Swift package here (a Package.swift at the project's root)."
            case .noExecutable: return "The package has no executable product to debug."
            case .noAdapter: return "lldb-dap wasn't found. Install Xcode or its Command Line Tools."
            case .describe(let message): return "Couldn't read the package: \(message)"
            }
        }
    }

    /// The package's executable products, in the order it declares them.
    nonisolated static func swiftExecutables(in root: URL) async throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else { throw Failure.notAPackage }
        let (status, output) = await DebugSession.run("swift package describe --type json 2>/dev/null", in: root.path)
        guard status == 0, let start = output.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any] else {
            throw Failure.describe(output.split(separator: "\n").last.map(String.init) ?? "exit \(status)")
        }
        return executables(inDescription: object)
    }

    /// From `swift package describe --type json`: products whose type is executable.
    nonisolated static func executables(inDescription object: [String: Any]) -> [String] {
        (object["products"] as? [[String: Any]] ?? []).compactMap { product in
            guard let name = product["name"] as? String, let type = product["type"] as? [String: Any], type["executable"] != nil else { return nil }
            return name
        }
    }

    /// A debug build of the product, then the binary it made.
    nonisolated static func swiftConfiguration(product: String, root: URL) -> DebugConfiguration {
        let quoted = "'" + product.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return DebugConfiguration(
            name: product,
            program: root.appendingPathComponent(".build/debug").appendingPathComponent(product).path,
            directory: root.path,
            build: "swift build --product \(quoted)"
        )
    }
}

// MARK: - What Side proposes (SIDE_RFC_DEBUGGER.md, Q3)

extension DebugLaunch {
    /// What the project and the open file can be debugged as, the open file's language first:
    /// a Swift package's or a Cargo project's executables, the current JavaScript, TypeScript or
    /// Python file, `npm run` scripts, and a Go main package.
    nonisolated static func proposals(root: URL, currentFile: URL?) async -> [DebugConfiguration] {
        var list: [(configuration: DebugConfiguration, language: String)] = []
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: root.appendingPathComponent(name).path) }

        if exists("Package.swift"), let products = try? await swiftExecutables(in: root) {
            list += products.map { (swiftConfiguration(product: $0, root: root), "swift") }
        }
        if exists("Cargo.toml") {
            list += await cargoBinaries(in: root).map { (cargoConfiguration(binary: $0, root: root), "rust") }
        }
        if let file = currentFile {
            switch file.pathExtension.lowercased() {
            case "js", "mjs", "cjs", "ts", "mts", "cts": list.append((nodeFile(file, root: root), "typescript"))
            case "py": list.append((pythonFile(file, root: root), "python"))
            default: break
            }
        }
        if exists("package.json") {
            list += npmScripts(in: root).map { (npmScript($0, root: root), "typescript") }
        }
        if exists("go.mod") {
            let directory = currentFile.flatMap { $0.pathExtension == "go" ? $0.deletingLastPathComponent() : nil } ?? root
            list.append((goPackage(directory, root: root), "go"))
        }
        let language = currentFile.flatMap { LanguageSettings.preset(forExtension: $0.pathExtension)?.id }
        // Stable: the open file's language first, otherwise as found.
        return list.enumerated().sorted { a, b in
            let aFirst = a.element.language == language, bFirst = b.element.language == language
            return aFirst != bFirst ? aFirst : a.offset < b.offset
        }.map(\.element.configuration)
    }

    // Rust: `cargo metadata`'s bin targets, built with `cargo build`.
    nonisolated static func cargoBinaries(in root: URL) async -> [String] {
        let (status, output) = await DebugSession.run("cargo metadata --no-deps --format-version 1 2>/dev/null", in: root.path)
        guard status == 0, let start = output.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any] else { return [] }
        return (object["packages"] as? [[String: Any]] ?? []).flatMap { package in
            (package["targets"] as? [[String: Any]] ?? []).compactMap { target in
                (target["kind"] as? [String])?.contains("bin") == true ? target["name"] as? String : nil
            }
        }
    }

    nonisolated static func cargoConfiguration(binary: String, root: URL) -> DebugConfiguration {
        DebugConfiguration(name: binary, program: root.appendingPathComponent("target/debug").appendingPathComponent(binary).path,
                           directory: root.path, build: "cargo build --bin " + shellQuoted(binary))
    }

    /// A JavaScript or TypeScript file under Node (Node runs TypeScript as it can; js-debug maps
    /// source maps for what's compiled).
    nonisolated static func nodeFile(_ file: URL, root: URL) -> DebugConfiguration {
        DebugConfiguration(name: file.lastPathComponent, adapter: DebugAdapters.jsDebug.id, launchArguments: [
            "type": "pwa-node", "request": "launch", "name": .string(file.lastPathComponent),
            "program": .string(file.path), "cwd": .string(root.path), "console": "integratedTerminal",
        ].merging(nodeQuiet(root)) { $1 }, directory: root.path)
    }

    /// Source maps looked for in the project only, and Node's own code stepped over: under `npm
    /// run`, js-debug debugs npm itself, and said "Could not read source map" for each of its
    /// files (2026-10-01, side-demo-repo).
    nonisolated static func nodeQuiet(_ root: URL) -> [String: LSPValue] {
        ["resolveSourceMapLocations": [.string(root.path + "/**"), "!**/node_modules/**"], "skipFiles": ["<node_internals>/**"]]
    }

    nonisolated static func npmScripts(in root: URL) -> [String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        return scripts.keys.sorted()
    }

    nonisolated static func npmScript(_ script: String, root: URL) -> DebugConfiguration {
        DebugConfiguration(name: "npm run \(script)", adapter: DebugAdapters.jsDebug.id, launchArguments: [
            "type": "pwa-node", "request": "launch", "name": .string("npm run \(script)"),
            "runtimeExecutable": "npm", "runtimeArgs": ["run", .string(script)], "cwd": .string(root.path), "console": "integratedTerminal",
        ].merging(nodeQuiet(root)) { $1 }, directory: root.path)
    }

    /// A Python file with the project's interpreter: its `.venv` or `venv`, else `python3`.
    nonisolated static func pythonFile(_ file: URL, root: URL) -> DebugConfiguration {
        let python = [".venv/bin/python", "venv/bin/python"].map { root.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python3"
        return DebugConfiguration(name: file.lastPathComponent, adapter: DebugAdapters.debugpy.id, launchArguments: [
            "type": "python", "request": "launch", "name": .string(file.lastPathComponent),
            "program": .string(file.path), "cwd": .string(root.path), "console": "integratedTerminal",
            "python": .string(python), "justMyCode": true,
        ], directory: root.path)
    }

    /// A Go main package, built by Delve (`mode: debug`).
    nonisolated static func goPackage(_ directory: URL, root: URL) -> DebugConfiguration {
        let relative = directory.standardizedFileURL.path == root.standardizedFileURL.path ? "." : "./" + directory.path.dropFirst(root.path.count + 1)
        return DebugConfiguration(name: "go run \(relative)", adapter: DebugAdapters.delve.id, launchArguments: [
            "request": "launch", "mode": "debug", "program": .string(directory.path), "cwd": .string(root.path),
            // The program's output as output events (Delve otherwise writes it to its own stdout).
            "outputMode": "remote",
        ], directory: root.path)
    }

    nonisolated static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// A path as the file system has it, symlinks resolved (`/tmp` → `/private/tmp`): what a
/// compiler records and a debugger matches breakpoints against. Foundation's
/// `resolvingSymlinksInPath` strips `/private` again, so it isn't that.
nonisolated func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A value behind a lock, for the few statics read off the main thread.
final class DebugLockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

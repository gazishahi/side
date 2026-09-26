import Foundation

/// What Side proposes to debug when a project doesn't say (SIDE_RFC_DEBUGGER.md, Q3), and the
/// adapter that debugs it. Step 1: a Swift package's executables under lldb-dap.
enum DebugLaunch {
    /// lldb-dap, from the selected Xcode or Command Line Tools (nil without either).
    nonisolated static func lldbDAP() -> URL? {
        if let cached = cachedAdapter.withLock({ $0 }) { return cached }
        let process = Process()
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

import Foundation

/// A debug adapter Side knows how to run (SIDE_RFC_DEBUGGER.md, D2), as language servers are
/// presets: which languages it debugs, how it's found and started, and how it's installed.
struct DebugAdapterPreset: Sendable, Equatable {
    let id: String
    let name: String
    /// What `initialize` calls it (`adapterID`).
    let adapterID: String
    /// `LanguagePreset.id`s it debugs.
    let languages: [String]
    /// What runs, for Settings (the real command is resolved when a session starts).
    let command: String
    let install: LanguageInstall?
    /// Where it's documented, for Settings' detail.
    let note: String

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

enum DebugAdapters {
    /// Where Side keeps the adapters it installs itself (js-debug, debugpy's environment):
    /// `~/Library/Application Support/Side/Debuggers`.
    /// `SIDE_DEBUGGERS_FOLDER` stands in for it (tests, and trying an install without touching
    /// the real one).
    nonisolated static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["SIDE_DEBUGGERS_FOLDER"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Side/Debuggers", isDirectory: true)
    }

    nonisolated static var jsDebugServer: URL { folder.appendingPathComponent("js-debug/src/dapDebugServer.js") }
    nonisolated static var debugpyPython: URL { folder.appendingPathComponent("debugpy/bin/python") }

    /// The shell's quoting of a path (for install commands).
    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static let lldb = DebugAdapterPreset(
        id: "lldb-dap", name: "LLDB (with Xcode)", adapterID: "lldb-dap", languages: ["swift", "c", "rust"],
        command: "xcrun lldb-dap", install: nil, note: "Comes with Xcode and its Command Line Tools.")

    static let jsDebug = DebugAdapterPreset(
        id: "js-debug", name: "JavaScript Debugger (js-debug)", adapterID: "pwa-node", languages: ["typescript"],
        command: "node dapDebugServer.js", install: .script(
            command: "set -e; d=\(quoted(folder.path)); mkdir -p \"$d\"; "
                + "url=$(curl -fsSL https://api.github.com/repos/microsoft/vscode-js-debug/releases/latest | grep -o 'https://[^\"]*js-debug-dap-v[^\"]*\\.tar\\.gz' | head -1); "
                + "test -n \"$url\"; rm -rf \"$d/js-debug\"; curl -fsSL \"$url\" | tar -xz -C \"$d\"",
            tool: "the js-debug release on GitHub", requires: "node", hint: "Node.js (brew install node)"),
        note: "VS Code's own Node debugger, fetched into Side's folder. TypeScript runs as Node runs it.")

    static let debugpy = DebugAdapterPreset(
        id: "debugpy", name: "debugpy", adapterID: "debugpy", languages: ["python"],
        command: "python -m debugpy.adapter", install: .script(
            command: "set -e; d=\(quoted(folder.appendingPathComponent("debugpy").path)); rm -rf \"$d\"; python3 -m venv \"$d\"; \"$d/bin/python\" -m pip install --quiet debugpy",
            tool: "pip, in an environment of Side's own", requires: "python3", hint: "Python 3 (brew install python)"),
        note: "In an environment of Side's own; your programs run with your Python (the project's .venv if it has one).")

    static let delve = DebugAdapterPreset(
        id: "delve", name: "Delve", adapterID: "go", languages: ["go"],
        command: "dlv dap", install: .go("github.com/go-delve/delve/cmd/dlv"),
        note: "The first session may ask for Developer Tools Access (your password), as macOS does for any debugger.")

    static let presets: [DebugAdapterPreset] = [lldb, jsDebug, debugpy, delve]

    static func preset(_ id: String) -> DebugAdapterPreset? { presets.first { $0.id == id } }

    static func preset(forLanguage language: String) -> DebugAdapterPreset? { presets.first { $0.languages.contains(language) } }

    /// How to start an adapter, if it's installed. Blocking (it may ask a login shell): call
    /// off the main thread.
    nonisolated static func connection(for preset: DebugAdapterPreset) -> DAPConnection? {
        switch preset.id {
        case lldb.id:
            return DebugLaunch.lldbDAP().map { .stdio(executable: $0, arguments: []) }
        case jsDebug.id:
            guard FileManager.default.fileExists(atPath: jsDebugServer.path),
                  let node = LanguageServerRegistry.resolveExecutable(named: "node") else { return nil }
            return .server(executable: node, arguments: [jsDebugServer.path, "{port}", "127.0.0.1"])
        case debugpy.id:
            guard FileManager.default.isExecutableFile(atPath: debugpyPython.path) else { return nil }
            return .stdio(executable: debugpyPython, arguments: ["-m", "debugpy.adapter"])
        case delve.id:
            // `SIDE_DLV`: a Delve of one's own (tests use a scratch build).
            let dlv = ProcessInfo.processInfo.environment["SIDE_DLV"].map(URL.init(fileURLWithPath:)) ?? LanguageServerRegistry.resolveExecutable(named: "dlv")
            return dlv.map { .server(executable: $0, arguments: ["dap", "--listen", "127.0.0.1:{port}"]) }
        default:
            return nil
        }
    }

    /// Whether it's there, for Settings.
    nonisolated static func isInstalled(_ preset: DebugAdapterPreset) -> Bool { connection(for: preset) != nil }

    /// Forgets where a binary was found, after an install.
    nonisolated static func invalidate(_ preset: DebugAdapterPreset) {
        for binary in ["node", "dlv"] { LanguageServerRegistry.invalidateResolution(for: binary) }
        if preset.id == lldb.id { DebugLaunch.forgetLLDBDAP() }
    }
}

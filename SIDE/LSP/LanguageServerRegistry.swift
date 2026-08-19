import Foundation

/// Maps file extensions to language server launch commands, and resolves
/// those binaries on disk.
enum LanguageServerRegistry {
    struct Entry {
        let languageId: String
        let binaryName: String
        let arguments: [String]
        /// A Homebrew formula to offer installing when `binaryName` isn't found on PATH — nil
        /// for servers that aren't independently installable (sourcekit-lsp ships with Xcode).
        let installFormula: String?
    }

    private static let entriesByExtension: [String: Entry] = [
        "py": Entry(languageId: "python", binaryName: "pyright-langserver", arguments: ["--stdio"], installFormula: "pyright"),
        "ts": Entry(languageId: "typescript", binaryName: "typescript-language-server", arguments: ["--stdio"], installFormula: "typescript-language-server"),
        "tsx": Entry(languageId: "typescriptreact", binaryName: "typescript-language-server", arguments: ["--stdio"], installFormula: "typescript-language-server"),
        "js": Entry(languageId: "javascript", binaryName: "typescript-language-server", arguments: ["--stdio"], installFormula: "typescript-language-server"),
        "jsx": Entry(languageId: "javascriptreact", binaryName: "typescript-language-server", arguments: ["--stdio"], installFormula: "typescript-language-server"),
        "swift": Entry(languageId: "swift", binaryName: "sourcekit-lsp", arguments: [], installFormula: nil),
        "rs": Entry(languageId: "rust", binaryName: "rust-analyzer", arguments: [], installFormula: "rust-analyzer"),
        "go": Entry(languageId: "go", binaryName: "gopls", arguments: [], installFormula: "gopls"),
        "lua": Entry(languageId: "lua", binaryName: "lua-language-server", arguments: [], installFormula: "lua-language-server"),
        "c": Entry(languageId: "c", binaryName: "clangd", arguments: [], installFormula: "llvm"),
        "h": Entry(languageId: "c", binaryName: "clangd", arguments: [], installFormula: "llvm"),
        "cpp": Entry(languageId: "cpp", binaryName: "clangd", arguments: [], installFormula: "llvm"),
        "cc": Entry(languageId: "cpp", binaryName: "clangd", arguments: [], installFormula: "llvm"),
        "cxx": Entry(languageId: "cpp", binaryName: "clangd", arguments: [], installFormula: "llvm"),
        "hpp": Entry(languageId: "cpp", binaryName: "clangd", arguments: [], installFormula: "llvm"),
    ]

    static func entry(forExtension ext: String) -> Entry? {
        entriesByExtension[ext.lowercased()]
    }

    /// typescript-language-server resolves the "typescript" package the same way Node itself
    /// would — from the project's own node_modules — and fails its *entire* initialize
    /// request (not just a degraded mode) if a project doesn't vendor one, even if
    /// "typescript" is installed globally. Returns a global install's tsserver.js to pass via
    /// initializationOptions.tsserver.path as a fallback, but only when the project doesn't
    /// already have its own (a project pinning a specific TypeScript version should keep
    /// using that one). Also refuses a global install that turns out to be TypeScript 7 (the
    /// new Go-based rewrite) — it has no tsserver.js at all, so it's silently unusable here.
    static func tsserverPathOverride(for entry: Entry, projectRoot: URL) -> String? {
        guard entry.binaryName == "typescript-language-server" else { return nil }
        let localTsserver = projectRoot.appendingPathComponent("node_modules/typescript/lib/tsserver.js")
        guard !FileManager.default.fileExists(atPath: localTsserver.path) else { return nil }
        guard let globalRoot = resolveGlobalNpmRoot() else { return nil }
        let globalTsserver = URL(fileURLWithPath: globalRoot).appendingPathComponent("typescript/lib/tsserver.js")
        guard FileManager.default.fileExists(atPath: globalTsserver.path) else { return nil }
        return globalTsserver.path
    }

    private nonisolated(unsafe) static var globalNpmRootCache: String??

    private static func resolveGlobalNpmRoot() -> String? {
        if let cached = globalNpmRootCache { return cached }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "npm root -g"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                globalNpmRootCache = .some(nil)
                return nil
            }
            globalNpmRootCache = .some(output)
            return output
        } catch {
            globalNpmRootCache = .some(nil)
            return nil
        }
    }

    private nonisolated(unsafe) static var loginShellPATHCache: String??

    /// Node-based servers (typescript-language-server, pyright's own tsserver-adjacent shims)
    /// are launched via a `#!/usr/bin/env node`-style shebang — resolving the *binary itself*
    /// via the login shell (resolveExecutable) isn't enough, because the shebang interpreter
    /// is looked up using whatever PATH the *spawned process's own environment* carries. A GUI
    /// app's environment (ProcessInfo.processInfo.environment) has launchd's bare minimum PATH
    /// (no Homebrew, no nvm, etc.), so `env: node: No such file or directory` kills the server
    /// immediately after spawn — which surfaces here only as a generic "notRunning" failure,
    /// not the underlying reason. Build a spawn environment with the login shell's real PATH
    /// merged in so the shebang line actually resolves.
    static func environmentForSpawning() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = resolveLoginShellPATH() {
            environment["PATH"] = path
        }
        return environment
    }

    private static func resolveLoginShellPATH() -> String? {
        if let cached = loginShellPATHCache { return cached }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "echo $PATH"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                loginShellPATHCache = .some(nil)
                return nil
            }
            loginShellPATHCache = .some(output)
            return output
        } catch {
            loginShellPATHCache = .some(nil)
            return nil
        }
    }

    private enum Resolution {
        case found(URL)
        case notFound
    }

    /// Callers (LSPManager) are expected to serialize access to this registry, so a plain
    /// static cache is fine — see the note on resolveExecutable(named:).
    private nonisolated(unsafe) static var resolutionCache: [String: Resolution] = [:]

    /// GUI apps on macOS don't inherit the user's login-shell PATH (no .zshrc/.zprofile
    /// sourcing), so a language server installed via npm/pip/homebrew won't be found by a
    /// plain `Process` launch. Resolve it by asking the user's actual shell, the same way
    /// TerminalViewController spawns $SHELL for the integrated terminal.
    ///
    /// `installFormula`, when given, backs a second attempt via `brew --prefix <formula>` —
    /// covers keg-only formulas (clangd's `llvm`, notably) that Homebrew deliberately doesn't
    /// symlink onto PATH at all, so a plain `which` can never find them regardless of shell
    /// setup. Harmless to pass for non-keg-only formulas too: it just never gets reached since
    /// the plain `which` already succeeds first.
    ///
    /// Not thread-safe on its own — callers (LSPManager) are expected to serialize access.
    static func resolveExecutable(named binaryName: String, installFormula: String? = nil) -> URL? {
        if let cached = resolutionCache[binaryName] {
            switch cached {
            case .found(let url): return url
            case .notFound: return nil
            }
        }
        if let url = runShell("which \(binaryName)").flatMap(URL.init(fileURLWithPath:)) {
            resolutionCache[binaryName] = .found(url)
            return url
        }
        if let formula = installFormula, let prefix = runShell("brew --prefix \(formula)") {
            let candidate = URL(fileURLWithPath: prefix).appendingPathComponent("bin/\(binaryName)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                resolutionCache[binaryName] = .found(candidate)
                return candidate
            }
        }
        resolutionCache[binaryName] = .notFound
        return nil
    }

    /// Runs a command through the user's actual login shell and returns trimmed stdout, or nil
    /// on any non-zero exit / empty output / launch failure.
    private static func runShell(_ command: String) -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", command]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }
            return output
        } catch {
            return nil
        }
    }

    /// Called after an install completes so the next spawn attempt re-checks PATH instead of
    /// trusting a stale `.notFound` cached from before the binary existed.
    static func invalidateResolution(for binaryName: String) {
        resolutionCache[binaryName] = nil
    }
}

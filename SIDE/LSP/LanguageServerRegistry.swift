import Foundation

/// Maps file extensions to language server launch commands, and resolves
/// those binaries on disk.
enum LanguageServerRegistry {
    struct Entry {
        let languageId: String
        let binaryName: String
        let arguments: [String]
    }

    private static let entriesByExtension: [String: Entry] = [
        "py": Entry(languageId: "python", binaryName: "pyright-langserver", arguments: ["--stdio"]),
        "ts": Entry(languageId: "typescript", binaryName: "typescript-language-server", arguments: ["--stdio"]),
        "tsx": Entry(languageId: "typescriptreact", binaryName: "typescript-language-server", arguments: ["--stdio"]),
        "js": Entry(languageId: "javascript", binaryName: "typescript-language-server", arguments: ["--stdio"]),
        "jsx": Entry(languageId: "javascriptreact", binaryName: "typescript-language-server", arguments: ["--stdio"]),
        "swift": Entry(languageId: "swift", binaryName: "sourcekit-lsp", arguments: []),
    ]

    static func entry(forExtension ext: String) -> Entry? {
        entriesByExtension[ext.lowercased()]
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
    /// Not thread-safe on its own — callers (LSPManager) are expected to serialize access.
    static func resolveExecutable(named binaryName: String) -> URL? {
        if let cached = resolutionCache[binaryName] {
            switch cached {
            case .found(let url): return url
            case .notFound: return nil
            }
        }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "which \(binaryName)"]
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
                resolutionCache[binaryName] = .notFound
                return nil
            }
            let url = URL(fileURLWithPath: output)
            resolutionCache[binaryName] = .found(url)
            return url
        } catch {
            resolutionCache[binaryName] = .notFound
            return nil
        }
    }
}

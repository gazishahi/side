import Foundation
import SideAgents

/// Maps file extensions to language server launch commands, and resolves
/// those binaries on disk.
enum LanguageServerRegistry {
    struct Entry: Sendable {
        let languageId: String
        let binaryName: String
        let arguments: [String]
        /// How to install it when `binaryName` isn't found; nil for servers that aren't
        /// installable on their own (sourcekit-lsp ships with Xcode) or a person's own command.
        let install: LanguageInstall?
        /// The language it's for (`LanguagePreset.id` or a custom language's), for its settings.
        let languageKey: String
        /// Whether a missing server shows "not installed" on the file's chip.
        let asksToInstall: Bool

        /// Homebrew's name, for finding keg-only formulas (clangd's `llvm`).
        var installFormula: String? { install?.brewFormula }
    }

    /// The server for an extension, as Settings → Languages has it: a preset, the person's
    /// choice of server or their own command; nil when the language is off or unknown.
    static func entry(forExtension ext: String) -> Entry? {
        LanguageSettings.shared.entry(forExtension: ext)
    }

    /// typescript-language-server resolves the "typescript" package the same way Node itself
    /// would — from the project's own node_modules — and fails its *entire* initialize
    /// request (not just a degraded mode) if a project doesn't vendor one, even if
    /// "typescript" is installed globally. Returns a global install's tsserver.js to pass via
    /// initializationOptions.tsserver.path as a fallback, but only when the project doesn't
    /// already have its own (a project pinning a specific TypeScript version should keep
    /// using that one). Also refuses a global install that turns out to be TypeScript 7 (the
    /// new Go-based rewrite) — it has no tsserver.js at all, so it's silently unusable here.
    ///
    /// A project's own TypeScript is code from the project: it runs only once the project is
    /// trusted (`ProjectTrust`); before that the global one does, or nothing (2026-09-30 audit,
    /// SEC-11: opening a cloned repository's .ts file ran its node_modules/typescript).
    enum TSServerChoice: Equatable { case projectDefault, global(String), refuse }

    static func tsserverPathOverride(for entry: Entry, projectRoot: URL, trusted: Bool = true) -> TSServerChoice {
        guard entry.binaryName == "typescript-language-server" else { return .projectDefault }
        let localTsserver = projectRoot.appendingPathComponent("node_modules/typescript/lib/tsserver.js")
        let hasLocal = FileManager.default.fileExists(atPath: localTsserver.path)
        if hasLocal, trusted { return .projectDefault }
        let global = resolveGlobalNpmRoot().map { URL(fileURLWithPath: $0).appendingPathComponent("typescript/lib/tsserver.js").path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if let global { return .global(global) }
        return hasLocal ? .refuse : .projectDefault
    }

    /// One lock for the three process-global caches below.
    ///
    /// They used to be bare `nonisolated(unsafe) static var`s with a comment claiming callers
    /// serialized access. They did not: `LSPManager` resolves on a *concurrent* global queue
    /// while `XcodeBuildServerSetup` resolves on main and `retryAfterInstall` invalidates on
    /// main — opening a `.swift` and a `.ts` back to back mutated one `Dictionary` from two
    /// threads. The 2026-09-01 audit confirmed it live. The shell spawns stay *outside* the lock
    /// (they take hundreds of milliseconds); only the dictionary reads and writes are guarded,
    /// so two threads may both miss and both resolve — harmless, they write the same answer.
    private static let cacheLock = NSLock()

    private nonisolated(unsafe) static var globalNpmRootCache: String??

    private static func resolveGlobalNpmRoot() -> String? {
        if let cached = cacheLock.withLock({ globalNpmRootCache }) { return cached }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "npm root -g"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Read before waiting — waiting first deadlocks once the pipe buffer fills
            // (see GitPaths.runGit).
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                cacheLock.withLock { globalNpmRootCache = .some(nil) }
                return nil
            }
            cacheLock.withLock { globalNpmRootCache = .some(output) }
            return output
        } catch {
            cacheLock.withLock { globalNpmRootCache = .some(nil) }
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
    /// merged in so the shebang line actually resolves. Without secrets (`SpawnEnvironment`).
    static func environmentForSpawning(keeping: Set<String> = []) -> [String: String] {
        var environment = SpawnEnvironment.current(keeping: keeping)
        if let path = resolveLoginShellPATH() {
            environment["PATH"] = path
        }
        return environment
    }

    private static func resolveLoginShellPATH() -> String? {
        if let cached = cacheLock.withLock({ loginShellPATHCache }) { return cached }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "echo $PATH"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Read before waiting — waiting first deadlocks once the pipe buffer fills
            // (see GitPaths.runGit).
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                cacheLock.withLock { loginShellPATHCache = .some(nil) }
                return nil
            }
            cacheLock.withLock { loginShellPATHCache = .some(output) }
            return output
        } catch {
            cacheLock.withLock { loginShellPATHCache = .some(nil) }
            return nil
        }
    }

    private enum Resolution {
        case found(URL)
        case notFound
    }

    /// Guarded by `cacheLock` — see its note.
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
    /// Safe to call from any thread.
    static func resolveExecutable(named binaryName: String, installFormula: String? = nil) -> URL? {
        if let cached = cacheLock.withLock({ resolutionCache[binaryName] }) {
            switch cached {
            case .found(let url): return url
            case .notFound: return nil
            }
        }
        // A path of the person's own (Settings → Languages): that file, if it runs.
        if binaryName.contains("/") {
            let path = (binaryName as NSString).expandingTildeInPath
            let found = FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
            cacheLock.withLock { resolutionCache[binaryName] = found.map { .found($0) } ?? .notFound }
            return found
        }
        if let url = runShell("which \(binaryName)").flatMap(URL.init(fileURLWithPath:)) {
            cacheLock.withLock { resolutionCache[binaryName] = .found(url) }
            return url
        }
        // Where `go install` and `dotnet tool install -g` put binaries, often not on PATH.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["go/bin", ".dotnet/tools"] {
            let candidate = home.appendingPathComponent(folder).appendingPathComponent(binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                cacheLock.withLock { resolutionCache[binaryName] = .found(candidate) }
                return candidate
            }
        }
        if let formula = installFormula, let prefix = runShell("brew --prefix \(formula)") {
            let candidate = URL(fileURLWithPath: prefix).appendingPathComponent("bin/\(binaryName)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                cacheLock.withLock { resolutionCache[binaryName] = .found(candidate) }
                return candidate
            }
        }
        cacheLock.withLock { resolutionCache[binaryName] = .notFound }
        return nil
    }

    /// Runs a command through the user's actual login shell and returns trimmed stdout, or nil
    /// on any non-zero exit / empty output / launch failure.
    private static func runShell(_ command: String) -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.environment = SpawnEnvironment.current()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", command]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Read before waiting — waiting first deadlocks once the pipe buffer fills
            // (see GitPaths.runGit).
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
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
        cacheLock.withLock { resolutionCache[binaryName] = nil }
    }
}


/// Whether a project's own code may run when its files are opened or saved: its TypeScript,
/// its formatter (a local Prettier, or a JavaScript Prettier config), its Rust build scripts and
/// procedural macros. Until the person trusts the project, Side uses its own or the global
/// tools and turns those off (2026-09-30 audit, SEC-11). Kept per repository: a track's worktree
/// is its project's.
enum ProjectTrust {
    static let didChangeNotification = Notification.Name("SideProjectTrustDidChange")
    private static let key = "SideTrustedProjects"

    /// The repository a root belongs to, from its `.git` (a worktree's file names its repository's).
    static func projectKey(_ root: URL) -> String {
        let path = realPath(root.path)
        let dotGit = URL(fileURLWithPath: path).appendingPathComponent(".git")
        if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") {
            // ".../repo/.git/worktrees/<name>": the repository is above ".git".
            let gitDir = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = gitDir.range(of: "/.git/worktrees/") { return realPath(String(gitDir[gitDir.startIndex..<range.lowerBound])) }
        }
        return path
    }

    static func isTrusted(_ root: URL) -> Bool {
        HeronDefaults.store.stringArray(forKey: key)?.contains(projectKey(root)) ?? false
    }

    static func trust(_ root: URL) {
        var trusted = HeronDefaults.store.stringArray(forKey: key) ?? []
        let project = projectKey(root)
        guard !trusted.contains(project) else { return }
        trusted.append(project)
        HeronDefaults.store.set(trusted, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: ["project": project])
    }

    /// What of the project's own would run, in words, for the banner that asks.
    static func projectCode(in root: URL) -> [String] {
        var found: [String] = []
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules/typescript/lib/tsserver.js").path) { found.append("its TypeScript") }
        if hasLocalPrettier(root) || hasCodePrettierConfig(root) { found.append("its formatter") }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path) { found.append("its Rust build scripts and macros") }
        if hasSvelteProjectCode(root) { found.append("its Svelte setup") }
        if hasLaTeXProjectCode(root) { found.append("its latexmkrc") }
        return found
    }

    /// A latexmkrc is Perl, and runs whenever latexmk does: when texlab asks it where the
    /// output goes, and when the document is built.
    static func hasLaTeXProjectCode(_ root: URL) -> Bool {
        ["latexmkrc", ".latexmkrc"].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    /// Svelte's server runs the project's svelte.config (preprocessors) and its own Svelte.
    static func hasSvelteProjectCode(_ root: URL) -> Bool {
        let names = ["svelte.config.js", "svelte.config.cjs", "svelte.config.mjs", "svelte.config.ts", "node_modules/svelte/package.json"]
        return names.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    static func hasLocalPrettier(_ root: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("node_modules/.bin/prettier").path)
    }

    /// A Prettier config that's a program (or names a package, which is one).
    static func hasCodePrettierConfig(_ root: URL) -> Bool {
        let names = ["prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", "prettier.config.ts",
                     ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs", ".prettierrc.ts"]
        if names.contains(where: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) { return true }
        // Plugins are packages, so code, whatever format names them.
        for name in [".prettierrc", ".prettierrc.json", ".prettierrc.json5", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.toml"] {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8), text.contains("plugins") { return true }
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if object["prettier"] is String { return true }
        return (object["prettier"] as? [String: Any])?["plugins"] != nil
    }

    /// rust-analyzer without running the project's code: no build scripts, no proc macros.
    static let rustAnalyzerUntrusted: LSPValue = ["cargo": ["buildScripts": ["enable": false]], "procMacro": ["enable": false]]
}

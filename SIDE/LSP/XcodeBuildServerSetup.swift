import Foundation

/// Detects an Xcode project/workspace directly inside a project root and, if
/// `xcode-build-server` is on PATH and no buildServer.json exists yet, generates one so
/// sourcekit-lsp gets real cross-file build context instead of analyzing each Swift file in
/// isolation (which produces false "cannot find X in scope" diagnostics and empty
/// go-to-definition results). No-ops quickly for non-Xcode projects or when the binary isn't
/// installed — Swift diagnostics just stay degraded rather than anything failing loudly.
enum XcodeBuildServerSetup {
    /// Always calls `completion` on the main thread, whether or not anything was done.
    static func ensureConfigured(projectRoot: URL, completion: @escaping @Sendable () -> Void) {
        let buildServerPath = projectRoot.appendingPathComponent("buildServer.json").path
        guard !FileManager.default.fileExists(atPath: buildServerPath) else {
            DispatchQueue.main.async { completion() }
            return
        }
        guard let container = try? FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            DispatchQueue.main.async { completion() }
            return
        }
        let workspace = container.first { $0.pathExtension == "xcworkspace" }
        let project = container.first { $0.pathExtension == "xcodeproj" }
        guard workspace != nil || project != nil else {
            DispatchQueue.main.async { completion() }
            return
        }
        guard let serverBinary = LanguageServerRegistry.resolveExecutable(named: "xcode-build-server") else {
            print("[LSP] xcode-build-server not found on PATH — Swift diagnostics will run without full build context (install via `brew install xcode-build-server`)")
            DispatchQueue.main.async { completion() }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let projectFlag: [String]
            let name: String
            if let workspace {
                projectFlag = ["-workspace", workspace.lastPathComponent]
                name = workspace.deletingPathExtension().lastPathComponent
            } else if let project {
                projectFlag = ["-project", project.lastPathComponent]
                name = project.deletingPathExtension().lastPathComponent
            } else {
                DispatchQueue.main.async { completion() }
                return
            }
            guard let scheme = resolveScheme(preferring: name, projectFlag: projectFlag, cwd: projectRoot) else {
                print("[LSP] couldn't determine an Xcode scheme for \(name) — skipping build server setup")
                DispatchQueue.main.async { completion() }
                return
            }
            let process = Process()
            process.executableURL = serverBinary
            process.arguments = ["config"] + projectFlag + ["-scheme", scheme]
            process.currentDirectoryURL = projectRoot
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                print(process.terminationStatus == 0
                    ? "[LSP] generated buildServer.json for \(name) (scheme: \(scheme))"
                    : "[LSP] xcode-build-server config failed for \(name)")
            } catch {
                print("[LSP] failed to run xcode-build-server config: \(error)")
            }
            DispatchQueue.main.async { completion() }
        }
    }

    private static func resolveScheme(preferring name: String, projectFlag: [String], cwd: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = projectFlag + ["-list", "-json"]
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Read before waiting — waiting first deadlocks once the pipe buffer fills
        // (see GitPaths.runGit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let info = (json["project"] as? [String: Any]) ?? (json["workspace"] as? [String: Any])
        guard let schemes = info?["schemes"] as? [String], !schemes.isEmpty else { return nil }
        if let match = schemes.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        return schemes.first
    }
}

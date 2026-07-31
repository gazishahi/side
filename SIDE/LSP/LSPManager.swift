import Foundation

/// Owns at most one LSPClient per server *binary* (not per language — several extensions,
/// e.g. .ts/.tsx/.js/.jsx, can share a single typescript-language-server process) for a
/// single project root, spawned lazily on first matching file open. Routes diagnostics back
/// to the caller keyed by file URL. All public methods are expected to be called on the main
/// thread; `onDiagnostics` fires on the main thread too.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main
/// thread — every entry point below and the diagnostics callback dispatch onto it.
final class LSPManager: @unchecked Sendable {
    private let projectRoot: URL
    private var clients: [String: LSPClient] = [:]
    private var startingServers: Set<String> = []
    private var documentVersions: [URL: Int] = [:]
    private var buildServerSetup: BuildServerSetupState = .notStarted

    private enum BuildServerSetupState {
        case notStarted
        case inProgress([@Sendable () -> Void])
        case done
    }

    var onDiagnostics: ((URL, [LSPDiagnostic]) -> Void)?

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    func opened(url: URL, content: String) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        documentVersions[url] = 1
        withClient(for: entry) { client in
            guard let client else { return }
            Task { try? await client.didOpen(uri: url.absoluteString, languageId: entry.languageId, text: content, version: 1) }
        }
    }

    func changed(url: URL, content: String) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        let version = (documentVersions[url] ?? 1) + 1
        documentVersions[url] = version
        withClient(for: entry) { client in
            guard let client else { return }
            Task { try? await client.didChange(uri: url.absoluteString, text: content, version: version) }
        }
    }

    func closed(url: URL) {
        documentVersions[url] = nil
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension),
              let client = clients[entry.binaryName] else { return }
        Task { try? await client.didClose(uri: url.absoluteString) }
    }

    func definition(url: URL, position: LSPPosition, completion: @escaping @Sendable ([LSPLocation]) -> Void) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension),
              let client = clients[entry.binaryName] else { completion([]); return }
        Task {
            let locations: [LSPLocation]
            if let data = try? await client.definition(uri: url.absoluteString, position: position) {
                locations = Self.decodeLocations(from: data)
            } else {
                locations = []
            }
            DispatchQueue.main.async { completion(locations) }
        }
    }

    private static func decodeLocations(from data: Data) -> [LSPLocation] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"], !(result is NSNull),
              let resultData = try? JSONSerialization.data(withJSONObject: result) else { return [] }
        if let locations = try? JSONDecoder().decode([LSPLocation].self, from: resultData) { return locations }
        if let location = try? JSONDecoder().decode(LSPLocation.self, from: resultData) { return [location] }
        if let links = try? JSONDecoder().decode([LSPLocationLink].self, from: resultData) {
            return links.map { LSPLocation(uri: $0.targetUri, range: $0.targetRange) }
        }
        if let link = try? JSONDecoder().decode(LSPLocationLink.self, from: resultData) {
            return [LSPLocation(uri: link.targetUri, range: link.targetRange)]
        }
        return []
    }

    /// Best-effort: terminates every running language server. Fire-and-forget since this is
    /// called from the same synchronous window/app-quit cleanup path as
    /// TerminalViewController.prepareForClose(), which cannot await actor hops.
    func prepareForClose() {
        for (_, client) in clients {
            Task { await client.stop() }
        }
        clients.removeAll()
        startingServers.removeAll()
    }

    // MARK: - Client lifecycle

    private func withClient(for entry: LanguageServerRegistry.Entry, completion: @escaping @Sendable (LSPClient?) -> Void) {
        guard clients[entry.binaryName] == nil else {
            completion(clients[entry.binaryName])
            return
        }
        ensureBuildServerConfigured { [weak self] in
            self?.spawnOrReuseClient(for: entry, completion: completion)
        }
    }

    /// Runs once per project: generates buildServer.json first (if applicable) so the very
    /// first client we spawn — sourcekit-lsp in particular — sees it at its own startup,
    /// since that's the only point it checks. Later callers just queue behind it.
    private func ensureBuildServerConfigured(then: @escaping @Sendable () -> Void) {
        switch buildServerSetup {
        case .done:
            then()
        case .inProgress(let callbacks):
            buildServerSetup = .inProgress(callbacks + [then])
        case .notStarted:
            buildServerSetup = .inProgress([then])
            XcodeBuildServerSetup.ensureConfigured(projectRoot: projectRoot) { [weak self] in
                guard let self else { return }
                guard case .inProgress(let callbacks) = self.buildServerSetup else { return }
                self.buildServerSetup = .done
                callbacks.forEach { $0() }
            }
        }
    }

    private func spawnOrReuseClient(for entry: LanguageServerRegistry.Entry, completion: @escaping @Sendable (LSPClient?) -> Void) {
        if let existing = clients[entry.binaryName] {
            completion(existing)
            return
        }
        guard !startingServers.contains(entry.binaryName) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.spawnOrReuseClient(for: entry, completion: completion)
            }
            return
        }
        guard let executable = LanguageServerRegistry.resolveExecutable(named: entry.binaryName) else {
            print("[LSP] \(entry.binaryName) not found on PATH — diagnostics disabled for \(entry.languageId)")
            completion(nil)
            return
        }
        startingServers.insert(entry.binaryName)
        let client = LSPClient(executableURL: executable, arguments: entry.arguments, environment: ProcessInfo.processInfo.environment, currentDirectory: projectRoot)
        let rootURI = projectRoot.absoluteString
        Task { @MainActor [weak self] in
            do {
                try await client.start(rootURI: rootURI)
                await client.setOnDiagnostics { [weak self] params in
                    guard let url = URL(string: params.uri) else { return }
                    DispatchQueue.main.async { self?.onDiagnostics?(url, params.diagnostics) }
                }
                guard let self else { return }
                self.clients[entry.binaryName] = client
                self.startingServers.remove(entry.binaryName)
                completion(client)
            } catch {
                print("[LSP] failed to start \(entry.binaryName): \(error)")
                self?.startingServers.remove(entry.binaryName)
                completion(nil)
            }
        }
    }
}

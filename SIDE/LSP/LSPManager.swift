import Foundation

/// Owns at most one LSPClient per language for a single project root, spawned lazily on
/// first matching file open, and routes diagnostics back to the caller keyed by file URL.
/// All public methods are expected to be called on the main thread; `onDiagnostics` fires
/// on the main thread too.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main
/// thread — every entry point below and the diagnostics callback dispatch onto it.
final class LSPManager: @unchecked Sendable {
    private let projectRoot: URL
    private var clients: [String: LSPClient] = [:]
    private var startingLanguages: Set<String> = []
    private var documentVersions: [URL: Int] = [:]

    var onDiagnostics: ((URL, [LSPDiagnostic]) -> Void)?

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    func opened(url: URL, content: String) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        documentVersions[url] = 1
        withClient(for: entry) { client in
            guard let client else { return }
            Task { try? await client.didOpen(uri: url.absoluteString, text: content, version: 1) }
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
              let client = clients[entry.languageId] else { return }
        Task { try? await client.didClose(uri: url.absoluteString) }
    }

    /// Best-effort: terminates every running language server. Fire-and-forget since this is
    /// called from the same synchronous window/app-quit cleanup path as
    /// TerminalViewController.prepareForClose(), which cannot await actor hops.
    func prepareForClose() {
        for (_, client) in clients {
            Task { await client.stop() }
        }
        clients.removeAll()
        startingLanguages.removeAll()
    }

    // MARK: - Client lifecycle

    private func withClient(for entry: LanguageServerRegistry.Entry, completion: @escaping @Sendable (LSPClient?) -> Void) {
        if let existing = clients[entry.languageId] {
            completion(existing)
            return
        }
        guard !startingLanguages.contains(entry.languageId) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.withClient(for: entry, completion: completion)
            }
            return
        }
        guard let executable = LanguageServerRegistry.resolveExecutable(named: entry.binaryName) else {
            print("[LSP] \(entry.binaryName) not found on PATH — diagnostics disabled for \(entry.languageId)")
            completion(nil)
            return
        }
        startingLanguages.insert(entry.languageId)
        let client = LSPClient(languageId: entry.languageId, executableURL: executable, arguments: entry.arguments, environment: ProcessInfo.processInfo.environment, currentDirectory: projectRoot)
        let rootURI = projectRoot.absoluteString
        Task { @MainActor [weak self] in
            do {
                try await client.start(rootURI: rootURI)
                await client.setOnDiagnostics { [weak self] params in
                    guard let url = URL(string: params.uri) else { return }
                    DispatchQueue.main.async { self?.onDiagnostics?(url, params.diagnostics) }
                }
                guard let self else { return }
                self.clients[entry.languageId] = client
                self.startingLanguages.remove(entry.languageId)
                completion(client)
            } catch {
                print("[LSP] failed to start \(entry.binaryName): \(error)")
                self?.startingLanguages.remove(entry.languageId)
                completion(nil)
            }
        }
    }
}

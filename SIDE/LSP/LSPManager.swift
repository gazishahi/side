import Foundation
import Heron

/// Owns at most one LSPClient per server *binary* (not per language — several extensions,
/// e.g. .ts/.tsx/.js/.jsx, can share a single typescript-language-server process) for a
/// single project root, spawned lazily on first matching file open. Routes diagnostics back
/// to the caller keyed by file URL. All public methods are expected to be called on the main
/// thread; `onDiagnostics` fires on the main thread too.
/// Marked unchecked-Sendable because it's deliberately only ever touched from the main
/// thread — every entry point below and the diagnostics callback dispatch onto it.
final class LSPManager: @unchecked Sendable {
    private let projectRoot: URL
    private var clients: [String: LSPClient] = [:] { didSet { announceStateChange() } }
    private var startingServers: Set<String> = [] { didSet { announceStateChange() } }
    private var documentVersions: [URL: Int] = [:]
    /// The text of every open document, so a respawned server can be given `didOpen` for each.
    /// A server that crashed and came back used to receive a bare `didChange` for a URI it had
    /// never opened; strict servers (pyright) drop everything after that, silently, for the rest
    /// of the session. The text is already sent on every keystroke, so holding it costs nothing new.
    private var openDocuments: [URL: (languageId: String, text: String)] = [:]
    /// One ordered outbound queue per server binary — see `LSPOutboundQueue`.
    private var queues: [String: LSPOutboundQueue] = [:]
    /// Binaries whose server died since it was last spawned; the next spawn replays `didOpen`.
    private var crashedBinaries: Set<String> = []
    private var buildServerSetup: BuildServerSetupState = .notStarted
    /// Binaries that failed to resolve on PATH at least once this session — drives the Make
    /// stage's missing-LSP indicator. Cleared for a binary once `retryAfterInstall` succeeds.
    private(set) var unavailableBinaries: Set<String> = []

    private enum BuildServerSetupState {
        case notStarted
        case inProgress([@Sendable () -> Void])
        case done
    }

    var onDiagnostics: ((URL, [LSPDiagnostic]) -> Void)?
    /// Fires whenever `unavailableBinaries` changes, so the UI can re-check whether the
    /// currently active file's language server is missing.
    var onAvailabilityChanged: (() -> Void)?

    /// What Make's tab-strip indicator says about the active file's server (§4.5).
    enum ServerState: Equatable { case none, starting, running, unavailable, stopped }

    func serverState(forExtension ext: String) -> ServerState {
        guard let entry = LanguageServerRegistry.entry(forExtension: ext) else { return .none }
        let binary = entry.binaryName
        if unavailableBinaries.contains(binary) { return .unavailable }
        if clients[binary] != nil { return .running }
        if startingServers.contains(binary) { return .starting }
        if crashedBinaries.contains(binary) { return .stopped }
        return .none
    }

    /// Coalesced onto the next main-loop turn: spawn bookkeeping mutates both sets in a row, and
    /// the indicator only needs the settled state.
    private var stateChangeScheduled = false
    private func announceStateChange() {
        guard !stateChangeScheduled else { return }
        stateChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateChangeScheduled = false
            self.onAvailabilityChanged?()
        }
    }

    func isUnavailable(forExtension ext: String) -> Bool {
        guard let entry = LanguageServerRegistry.entry(forExtension: ext) else { return false }
        return unavailableBinaries.contains(entry.binaryName)
    }

    /// Call after an install completes for `binaryName` — clears the cached PATH miss and the
    /// unavailable flag so the next `opened(url:content:)` for that language spawns for real.
    func retryAfterInstall(binaryName: String) {
        LanguageServerRegistry.invalidateResolution(for: binaryName)
        guard unavailableBinaries.remove(binaryName) != nil else { return }
        onAvailabilityChanged?()
    }

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    func opened(url: URL, content: String) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        documentVersions[url] = 1
        openDocuments[url] = (entry.languageId, content)
        onQueue(for: entry) { $0.enqueue(.didOpen(uri: url.absoluteString, languageId: entry.languageId, text: content, version: 1)) }
        ensureClient(for: entry)
    }

    func changed(url: URL, content: String) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        let version = (documentVersions[url] ?? 1) + 1
        documentVersions[url] = version
        if openDocuments[url] != nil { openDocuments[url]?.text = content }
        onQueue(for: entry) { $0.enqueue(.didChange(uri: url.absoluteString, text: content, version: version)) }
        ensureClient(for: entry)
    }

    func closed(url: URL) {
        documentVersions[url] = nil
        openDocuments[url] = nil
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        onQueue(for: entry) { $0.enqueue(.didClose(uri: url.absoluteString)) }
    }

    func definition(url: URL, position: LSPPosition, completion: @escaping @Sendable ([LSPLocation]) -> Void) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { completion([]); return }
        onQueue(for: entry) {
            $0.enqueue(.definition(uri: url.absoluteString, position: position) { data in
                let locations = data.map { Self.decodeLocations(from: $0) } ?? []
                DispatchQueue.main.async { completion(locations) }
            })
        }
        ensureClient(for: entry)
    }

    /// Flushes an immediate (non-debounced) didChange with the current buffer before asking
    /// for completions — otherwise, if this fires faster than the ~0.3s diagnostics debounce,
    /// the server would answer against stale content that doesn't include what was just typed.
    /// Both go through the same queue, so the request cannot overtake the flush.
    func completion(url: URL, content: String, position: LSPPosition, completion: @escaping @Sendable ([LSPCompletionItem]) -> Void) {
        changed(url: url, content: content)
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { completion([]); return }
        onQueue(for: entry) {
            $0.enqueue(.completion(uri: url.absoluteString, position: position) { data in
                let items = data.map { Self.decodeCompletionItems(from: $0) } ?? []
                DispatchQueue.main.async { completion(items) }
            })
        }
    }

    /// The manager is main-confined by convention (see the class note); the queue is main-confined
    /// by type. `assumeIsolated` is where the convention is asserted rather than assumed — it
    /// traps if any caller ever breaks it, which is better than a silent race.
    private func onQueue(for entry: LanguageServerRegistry.Entry, _ body: @MainActor (LSPOutboundQueue) -> Void) {
        MainActor.assumeIsolated { body(queue(for: entry)) }
    }

    @MainActor
    private func queue(for entry: LanguageServerRegistry.Entry) -> LSPOutboundQueue {
        if let existing = queues[entry.binaryName] { return existing }
        let binaryName = entry.binaryName
        let queue = LSPOutboundQueue { [weak self] op in
            // Resolved per op, on main: the client for this binary right now. A missing client
            // means the server died between enqueue and send — fail the op rather than block.
            let client = await MainActor.run { self?.clients[binaryName] }
            guard let client else { op.fail(); return }
            await client.apply(op)
        }
        queues[binaryName] = queue
        return queue
    }

    /// Spawns the server if it isn't running or starting, and resumes its queue once it is.
    private func ensureClient(for entry: LanguageServerRegistry.Entry) {
        guard clients[entry.binaryName] == nil, !startingServers.contains(entry.binaryName) else { return }
        withClient(for: entry) { _ in }
    }

    /// What to send a server that has just come back after dying, given what the editor still has
    /// open and what had queued up while it was down.
    ///
    /// `didOpen` for every open document first, each carrying its *current* text at version 1 —
    /// that supersedes any buffered `didOpen`/`didChange`/`didClose` for the same documents, which
    /// are dropped. Requests (completion, definition) are kept, after the opens, so a completion
    /// asked for during the outage still gets an answer from the new server rather than a silent
    /// `nil`.
    static func respawnOps(openDocuments: [(uri: String, languageId: String, text: String)], pending: [LSPOutboundOp]) -> [LSPOutboundOp] {
        var ops: [LSPOutboundOp] = openDocuments.map { .didOpen(uri: $0.uri, languageId: $0.languageId, text: $0.text, version: 1) }
        ops += pending.filter { !$0.isDocumentSync }
        return ops
    }

    private static func decodeCompletionItems(from data: Data) -> [LSPCompletionItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"], !(result is NSNull),
              let resultData = try? JSONSerialization.data(withJSONObject: result) else { return [] }
        if let items = try? JSONDecoder().decode([LSPCompletionItem].self, from: resultData) { return items }
        if let list = try? JSONDecoder().decode(LSPCompletionList.self, from: resultData) { return list.items }
        return []
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
        MainActor.assumeIsolated { for (_, queue) in queues { queue.close() } }
        queues.removeAll()
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
        // These three each run `$SHELL -lic "…"`, which sources the user's full profile — with
        // nvm or rbenv that is routinely hundreds of milliseconds to seconds *each*, and they
        // ran back to back on the main thread the first time a file of a given language was
        // opened. Results are cached statically, so this is a first-open cost, but it was the
        // first thing the user felt. Resolved off-main; the spawn hops back.
        startingServers.insert(entry.binaryName)
        let projectRoot = self.projectRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let executable = LanguageServerRegistry.resolveExecutable(named: entry.binaryName, installFormula: entry.installFormula)
            let environment = LanguageServerRegistry.environmentForSpawning()
            let tsserverPath = LanguageServerRegistry.tsserverPathOverride(for: entry, projectRoot: projectRoot)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let executable else {
                    print("[LSP] \(entry.binaryName) not found on PATH; diagnostics disabled for \(entry.languageId)")
                    self.startingServers.remove(entry.binaryName)
                    if self.unavailableBinaries.insert(entry.binaryName).inserted { self.onAvailabilityChanged?() }
                    completion(nil)
                    return
                }
                self.finishSpawn(entry: entry, executable: executable, environment: environment, tsserverPath: tsserverPath, completion: completion)
            }
        }
    }

    /// Resumes a binary's queue now that its server is running — after a crash, with the open
    /// documents re-announced in front of whatever had queued up.
    @MainActor
    private func bringQueueUp(for entry: LanguageServerRegistry.Entry) {
        let queue = queue(for: entry)
        if crashedBinaries.remove(entry.binaryName) != nil {
            let mine = openDocuments
                .filter { LanguageServerRegistry.entry(forExtension: $0.key.pathExtension)?.binaryName == entry.binaryName }
                .sorted { $0.key.path < $1.key.path }
            for (url, _) in mine { documentVersions[url] = 1 }
            let replay = Self.respawnOps(
                openDocuments: mine.map { ($0.key.absoluteString, $0.value.languageId, $0.value.text) },
                pending: queue.takePending()
            )
            for op in replay { queue.enqueue(op) }
        }
        queue.resume()
    }

    private func finishSpawn(entry: LanguageServerRegistry.Entry, executable: URL, environment: [String: String], tsserverPath: String?, completion: @escaping @Sendable (LSPClient?) -> Void) {
        let client = LSPClient(executableURL: executable, arguments: entry.arguments, environment: environment, currentDirectory: projectRoot)
        let rootURI = projectRoot.absoluteString
        Task { @MainActor [weak self] in
            do {
                if let tsserverPath {
                    try await client.start(rootURI: rootURI, tsserverPath: tsserverPath)
                } else {
                    try await client.start(rootURI: rootURI)
                }
                await client.setOnDiagnostics { [weak self] params in
                    guard let url = URL(string: params.uri) else { return }
                    DispatchQueue.main.async { self?.onDiagnostics?(url, params.diagnostics) }
                }
                // Without this, a crashed server stays in `clients` forever — every subsequent
                // didOpen/didChange/completion/definition call finds this same dead client and
                // silently no-ops against it (`try?` swallowing `ClientError.notRunning`),
                // permanently disabling diagnostics/autocomplete for the language for the rest
                // of the session. Evicting it here means the next call to `withClient` finds
                // nothing cached and transparently spawns a fresh server instead.
                await client.setOnTerminate { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.clients[entry.binaryName] === client else { return }
                        self.clients[entry.binaryName] = nil
                        // Freeze the queue and remember the death: the next spawn replays
                        // didOpen for every open document before anything else reaches it.
                        MainActor.assumeIsolated { self.queues[entry.binaryName]?.pause() }
                        self.crashedBinaries.insert(entry.binaryName)
                    }
                }
                guard let self else { return }
                self.clients[entry.binaryName] = client
                self.startingServers.remove(entry.binaryName)
                self.bringQueueUp(for: entry)
                completion(client)
            } catch {
                print("[LSP] failed to start \(entry.binaryName): \(error)")
                self?.startingServers.remove(entry.binaryName)
                completion(nil)
            }
        }
    }
}

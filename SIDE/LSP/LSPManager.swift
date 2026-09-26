import AlloyCore
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
    /// Every open document as the server has it (a rope, sharing its storage with the editor's):
    /// what the next edits' positions are counted in, and what a respawned server is given in
    /// `didOpen`. A server that crashed and came back used to receive a bare `didChange` for a
    /// URI it had never opened; strict servers (pyright) drop everything after that, silently.
    private var openDocuments: [URL: (languageId: String, text: Rope)] = [:]
    /// Edits not yet sent, and the text after them. Sent together a moment after typing stops,
    /// or at once before a request.
    private var pendingEdits: [URL: (edits: [AppliedEdit], text: Rope)] = [:]
    private var flushWorkItem: DispatchWorkItem?
    /// How long edits wait to go out together when nothing asks for them sooner.
    static let syncDelay: TimeInterval = 0.2
    /// What each running server said it does.
    private var serverCapabilities: [String: LSPServerCapabilities] = [:]
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

    func opened(url: URL, text: Rope) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        documentVersions[url] = 1
        openDocuments[url] = (entry.languageId, text)
        pendingEdits[url] = nil
        let string = text.string
        onQueue(for: entry) { $0.enqueue(.didOpen(uri: url.absoluteString, languageId: entry.languageId, text: string, version: 1)) }
        ensureClient(for: entry)
    }

    /// Edits to an open document, in the order they were applied, and its text after them.
    /// Nothing is copied or sent here: they go out a moment later, or before the next request.
    func edited(url: URL, edits: [AppliedEdit], text: Rope) {
        guard openDocuments[url] != nil, !edits.isEmpty else { return }
        pendingEdits[url, default: ([], text)].edits += edits
        pendingEdits[url]?.text = text
        guard flushWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flushWorkItem = nil
            for url in Array(self.pendingEdits.keys) { self.flush(url: url) }
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.syncDelay, execute: work)
    }

    /// Sends an open document's waiting edits as one `didChange`.
    func flush(url: URL) {
        guard let pending = pendingEdits.removeValue(forKey: url), let document = openDocuments[url],
              let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        let changes = Self.contentChanges(for: pending.edits, from: document.text)
        // The editor's rope, not the one the changes were counted on: the same text, and its
        // storage is the editor's own.
        openDocuments[url]?.text = pending.text
        let version = (documentVersions[url] ?? 1) + 1
        documentVersions[url] = version
        onQueue(for: entry) { $0.enqueue(.didChange(uri: url.absoluteString, changes: changes, text: pending.text, version: version)) }
        ensureClient(for: entry)
    }

    /// Edits as LSP content changes, each range counted in the text as it was just before that
    /// edit (the rope follows along, O(log n) an edit; nothing walks the text).
    static func contentChanges(for edits: [AppliedEdit], from text: Rope) -> [TextDocumentContentChangeEvent] {
        var text = text
        return edits.map { edit in
            let start = text.position(of: edit.range.lowerBound), end = text.position(of: edit.range.upperBound)
            text.replace(edit.range, with: edit.newText)
            return TextDocumentContentChangeEvent(
                range: LSPRange(start: LSPPosition(line: start.line, character: start.column), end: LSPPosition(line: end.line, character: end.column)),
                text: edit.newText)
        }
    }

    func saved(url: URL) {
        guard openDocuments[url] != nil, let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        flush(url: url)
        onQueue(for: entry) { $0.enqueue(.didSave(uri: url.absoluteString)) }
    }

    func closed(url: URL) {
        documentVersions[url] = nil
        openDocuments[url] = nil
        pendingEdits[url] = nil
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        onQueue(for: entry) { $0.enqueue(.didClose(uri: url.absoluteString)) }
    }

    /// The characters after which this file's server offers completions by itself (`.`, `::`…);
    /// empty until it's running.
    func completionTriggers(forExtension ext: String) -> Set<String> {
        guard let entry = LanguageServerRegistry.entry(forExtension: ext) else { return [] }
        return serverCapabilities[entry.binaryName]?.completionTriggers ?? []
    }

    func definition(url: URL, position: LSPPosition, completion: @escaping @Sendable ([LSPLocation]) -> Void) {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { completion([]); return }
        flush(url: url)
        onQueue(for: entry) {
            $0.enqueue(.definition(uri: url.absoluteString, position: position) { result in
                let locations = Self.decodeLocations(from: result)
                DispatchQueue.main.async { completion(locations) }
            })
        }
        ensureClient(for: entry)
    }

    /// Asks for completions at `position`, after sending what was typed, so the server answers
    /// the text as it is (both go through the same queue; the request can't overtake it). The
    /// reply is read off the main thread; `nil` if there was none. Cancel with the token when
    /// the answer stops mattering.
    @discardableResult
    func completion(url: URL, position: LSPPosition, context: CompletionContext, token: LSPRequestToken = LSPRequestToken(), completion: @escaping @Sendable (LSPCompletionList?) -> Void) -> LSPRequestToken {
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { completion(nil); return token }
        flush(url: url)
        onQueue(for: entry) {
            $0.enqueue(.completion(uri: url.absoluteString, position: position, context: context, token: token) { result in
                let list = result.map { LSPCompletionList($0) }
                DispatchQueue.main.async { completion(token.isCancelled ? nil : list) }
            })
        }
        ensureClient(for: entry)
        return token
    }

    /// The rest of one item (documentation, and for some servers its edits), if its server
    /// resolves items; `nil` otherwise.
    @discardableResult
    func resolve(_ item: LSPCompletionItem, url: URL, completion: @escaping @Sendable (LSPCompletionItem?) -> Void) -> LSPRequestToken {
        let token = LSPRequestToken()
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension),
              serverCapabilities[entry.binaryName]?.completionResolves == true else { completion(nil); return token }
        onQueue(for: entry) {
            $0.enqueue(.resolve(item: item.raw, uri: url.absoluteString, token: token) { result in
                var resolved = item
                guard let object = result?.object else { return DispatchQueue.main.async { completion(nil) } }
                resolved.merge(object)
                DispatchQueue.main.async { completion(token.isCancelled ? nil : resolved) }
            })
        }
        return token
    }

    func cancel(_ token: LSPRequestToken, url: URL) {
        guard !token.isCancelled else { return }
        token.cancel()
        guard let entry = LanguageServerRegistry.entry(forExtension: url.pathExtension) else { return }
        onQueue(for: entry) { $0.enqueue(.cancel(token, uri: url.absoluteString)) }
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

    private static func decodeLocations(from result: LSPResult?) -> [LSPLocation] {
        guard let result, !result.isNull else { return [] }
        if let locations = result.decode([LSPLocation].self) { return locations }
        if let location = result.decode(LSPLocation.self) { return [location] }
        if let links = result.decode([LSPLocationLink].self) {
            return links.map { LSPLocation(uri: $0.targetUri, range: $0.targetRange) }
        }
        if let link = result.decode(LSPLocationLink.self) {
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
        flushWorkItem?.cancel()
        flushWorkItem = nil
        pendingEdits.removeAll()
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
                openDocuments: mine.map { ($0.key.absoluteString, $0.value.languageId, $0.value.text.string) },
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
                let capabilities = if let tsserverPath {
                    try await client.start(rootURI: rootURI, tsserverPath: tsserverPath)
                } else {
                    try await client.start(rootURI: rootURI)
                }
                self?.serverCapabilities[entry.binaryName] = capabilities
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

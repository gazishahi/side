import AlloyCore
import Foundation
import Heron

/// One running language server process, speaking JSON-RPC 2.0 / LSP over stdio.
actor LSPClient {
    enum ClientError: Error {
        case serverError(code: Int, message: String)
        case notRunning
    }

    private let transport: JSONRPCTransport
    private var nextRequestID = 1
    /// Callbacks rather than continuations, so a request's *send* can complete independently of
    /// its reply — `LSPOutboundQueue` awaits the write to preserve ordering, and must not wait on
    /// the server's answer or one slow completion would stall every keystroke behind it.
    private var pendingRequests: [Int: @Sendable (Result<LSPResult, Error>) -> Void] = [:]
    private(set) var isRunning = false
    /// What the server said it does, from its `initialize` reply.
    private(set) var capabilities = LSPServerCapabilities()

    private var onDiagnostics: (@Sendable (PublishDiagnosticsParams) -> Void)?
    /// A server asking for edits (after a command it ran): true once they're applied.
    private var onApplyEdit: (@Sendable (LSPWorkspaceEdit) async -> Bool)?

    func setOnApplyEdit(_ handler: @escaping @Sendable (LSPWorkspaceEdit) async -> Bool) {
        onApplyEdit = handler
    }
    private var onTerminate: (@Sendable () -> Void)?

    init(executableURL: URL, arguments: [String], environment: [String: String]?, currentDirectory: URL?) {
        transport = JSONRPCTransport(executableURL: executableURL, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
    }

    func setOnDiagnostics(_ handler: @escaping @Sendable (PublishDiagnosticsParams) -> Void) {
        onDiagnostics = handler
    }

    func setOnTerminate(_ handler: @escaping @Sendable () -> Void) {
        onTerminate = handler
    }

    @discardableResult
    func start(rootURI: String) async throws -> LSPServerCapabilities {
        try await startInternal(rootURI: rootURI, initializationOptions: Optional<NoInitializationOptions>.none)
    }

    /// typescript-language-server only resolves "typescript" from the workspace's own
    /// node_modules by default — this is how a global npm install gets used as a fallback.
    @discardableResult
    func start(rootURI: String, tsserverPath: String) async throws -> LSPServerCapabilities {
        try await startInternal(rootURI: rootURI, initializationOptions: TSServerInitializationOptions(tsserver: TSServerPathOption(path: tsserverPath)))
    }

    private func startInternal<Options: Encodable>(rootURI: String, initializationOptions: Options?) async throws -> LSPServerCapabilities {
        await transport.setHandlers(
            onMessage: { data in Task { await self.handleMessage(data) } },
            onTerminate: { Task { await self.handleTermination() } }
        )
        try await transport.start()
        isRunning = true
        let result = try await request(method: "initialize", params: InitializeParams(processId: Int(ProcessInfo.processInfo.processIdentifier), rootUri: rootURI, initializationOptions: initializationOptions))
        capabilities = LSPServerCapabilities(initializeResult: result)
        try await notify(method: "initialized", params: [String: String]())
        return capabilities
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        await transport.stop()
        await transport.clearHandlers()
        failAllPending(with: ClientError.notRunning)
    }

    func didOpen(uri: String, languageId: String, text: String, version: Int) async throws {
        try await notify(method: "textDocument/didOpen", params: DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(uri: uri, languageId: languageId, version: version, text: text)))
    }

    /// Just the edits to a server that syncs incrementally; the whole text to one that asked for
    /// it; nothing to one that doesn't want changes.
    func didChange(uri: String, changes: [TextDocumentContentChangeEvent], text: Rope, version: Int) async throws {
        let contentChanges: [TextDocumentContentChangeEvent]
        switch capabilities.syncKind {
        case 2: contentChanges = changes
        case 1: contentChanges = [TextDocumentContentChangeEvent(range: nil, text: text.string)]
        default: return
        }
        try await notify(method: "textDocument/didChange", params: DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: contentChanges))
    }

    func didClose(uri: String) async throws {
        try await notify(method: "textDocument/didClose", params: DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri)))
    }

    /// Sends one queued op. Returns once the bytes are written — for a request, before the reply.
    func apply(_ op: LSPOutboundOp) async {
        switch op {
        case .didOpen(let uri, let languageId, let text, let version):
            try? await didOpen(uri: uri, languageId: languageId, text: text, version: version)
        case .didChange(let uri, let changes, let text, let version):
            try? await didChange(uri: uri, changes: changes, text: text, version: version)
        case .didSave(let uri):
            try? await notify(method: "textDocument/didSave", params: DidSaveTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri)))
        case .didClose(let uri):
            try? await didClose(uri: uri)
        case .completion(let uri, let position, let context, let token, let reply):
            await sendRequest(method: "textDocument/completion",
                              params: CompletionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position, context: context),
                              token: token) { reply(try? $0.get()) }
        case .resolve(let item, _, let token, let reply):
            guard capabilities.completionResolves else { return reply(nil) }
            await sendRequest(method: "completionItem/resolve", params: item, token: token) { reply(try? $0.get()) }
        case .definition(let uri, let position, let reply):
            await sendRequest(method: "textDocument/definition",
                              params: DefinitionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position)) { reply(try? $0.get()) }
        case .formatting(let uri, let tabSize, let insertSpaces, let reply):
            guard capabilities.formats else { return reply(nil) }
            let params: LSPValue = ["textDocument": ["uri": .string(uri)], "options": ["tabSize": .int(tabSize), "insertSpaces": .bool(insertSpaces)]]
            await sendRequest(method: "textDocument/formatting", params: params) { reply(try? $0.get()) }
        case .signatureHelp(let uri, let position, let context, let token, let reply):
            guard capabilities.signatureHelp != nil else { return reply(nil) }
            let params: LSPValue = ["textDocument": ["uri": .string(uri)], "position": ["line": .int(position.line), "character": .int(position.character)], "context": context]
            await sendRequest(method: "textDocument/signatureHelp", params: params, token: token) { reply(try? $0.get()) }
        case .hover(let uri, let position, let token, let reply):
            guard capabilities.hovers else { return reply(nil) }
            let params: LSPValue = ["textDocument": ["uri": .string(uri)], "position": ["line": .int(position.line), "character": .int(position.character)]]
            await sendRequest(method: "textDocument/hover", params: params, token: token) { reply(try? $0.get()) }
        case .request(let method, _, let params, let token, let reply):
            await sendRequest(method: method, params: params, token: token) { reply(try? $0.get()) }
        case .cancel(let token, _):
            guard let id = token.id, let reply = pendingRequests.removeValue(forKey: id) else { return }
            reply(.failure(ClientError.notRunning))
            try? await notify(method: "$/cancelRequest", params: CancelParams(id: id))
        }
    }

    // MARK: - JSON-RPC plumbing

    /// Writes a request and registers its reply handler; returns once the write is done.
    private func sendRequest<Params: Encodable>(method: String, params: Params, token: LSPRequestToken? = nil, reply: @escaping @Sendable (Result<LSPResult, Error>) -> Void) async {
        guard isRunning else { return reply(.failure(ClientError.notRunning)) }
        let id = nextRequestID
        nextRequestID += 1
        token?.id = id
        let data: Data
        do { data = try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params)) }
        catch { return reply(.failure(error)) }
        pendingRequests[id] = reply
        await transport.send(data)
    }

    private func request<Params: Encodable>(method: String, params: Params) async throws -> LSPResult {
        try await withCheckedThrowingContinuation { continuation in
            Task { await sendRequest(method: method, params: params) { continuation.resume(with: $0) } }
        }
    }

    /// Awaited to the write, deliberately — sending from a detached `Task` is what let two
    /// notifications reach the server in the wrong order.
    private func notify<Params: Encodable>(method: String, params: Params) async throws {
        guard isRunning else { return }
        let data = try JSONEncoder().encode(NotificationEnvelope(method: method, params: params))
        await transport.send(data)
    }

    /// Every message is parsed once, here; a reply's `result` goes to its caller as parsed.
    private func handleMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let method = object["method"] as? String
        if let method, let id = object["id"] {
            return answerServerRequest(method: method, id: LSPValue(any: id), params: object["params"])
        }
        if let idNumber = object["id"] as? Int {
            guard let reply = pendingRequests.removeValue(forKey: idNumber) else { return }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown LSP error"
                let code = error["code"] as? Int ?? -1
                reply(.failure(ClientError.serverError(code: code, message: message)))
            } else {
                reply(.success(LSPResult(value: object["result"] ?? NSNull())))
            }
            return
        }
        switch method {
        case "textDocument/publishDiagnostics":
            guard var params = LSPResult(value: object["params"] ?? NSNull()).decode(PublishDiagnosticsParams.self) else { return }
            // Each diagnostic's own object, for asking about its fixes later.
            if let raw = (object["params"] as? [String: Any])?["diagnostics"] as? [Any], raw.count == params.diagnostics.count {
                for index in raw.indices { params.diagnostics[index].raw = LSPValue(any: raw[index]) }
            }
            onDiagnostics?(params)
        default:
            break
        }
    }

    /// A server asking the client something. Unanswered, some servers wait forever (settings
    /// asked for with `workspace/configuration` before they'll check a file).
    private func answerServerRequest(method: String, id: LSPValue, params: Any?) {
        let result: LSPValue
        switch method {
        case "workspace/configuration":
            // One value per item asked about; none are set yet (Settings → Languages, step 5).
            let items = (params as? [String: Any])?["items"] as? [Any] ?? []
            result = .array(items.map { _ in .null })
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create",
             "window/showMessageRequest", "workspace/codeLens/refresh", "workspace/semanticTokens/refresh",
             "workspace/inlayHint/refresh", "workspace/diagnostic/refresh", "workspace/workspaceFolders":
            result = .null
        case "workspace/applyEdit":
            let edit = LSPWorkspaceEdit((params as? [String: Any])?["edit"])
            guard let edit, let onApplyEdit else { result = ["applied": false]; break }
            Task {
                let applied = await onApplyEdit(edit)
                self.respond(id: id, result: ["applied": .bool(applied)])
            }
            return
        default:
            return respond(id: id, error: ["code": -32601, "message": .string("\(method) is not supported")])
        }
        respond(id: id, result: result)
    }

    private func respond(id: LSPValue, result: LSPValue? = nil, error: LSPValue? = nil) {
        guard isRunning, let data = try? JSONEncoder().encode(ResponseEnvelope(id: id, result: result, error: error)) else { return }
        Task { await transport.send(data) }
    }

    private func handleTermination() {
        isRunning = false
        failAllPending(with: ClientError.notRunning)
        let callback = onTerminate
        Task { await transport.clearHandlers() }
        callback?()
    }

    private func failAllPending(with error: Error) {
        for (_, reply) in pendingRequests { reply(.failure(error)) }
        pendingRequests.removeAll()
    }
}

private struct NoInitializationOptions: Encodable {}

private struct RequestEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

private struct ResponseEnvelope: Encodable {
    let jsonrpc = "2.0"
    let id: LSPValue
    let result: LSPValue?
    let error: LSPValue?

    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        if let error { try container.encode(error, forKey: .error) } else { try container.encode(result ?? .null, forKey: .result) }
    }
}

private struct NotificationEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

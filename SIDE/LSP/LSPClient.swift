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
    private var pendingRequests: [Int: @Sendable (Result<Data, Error>) -> Void] = [:]
    private(set) var isRunning = false

    private var onDiagnostics: (@Sendable (PublishDiagnosticsParams) -> Void)?
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

    func start(rootURI: String) async throws {
        try await startInternal(rootURI: rootURI, initializationOptions: Optional<NoInitializationOptions>.none)
    }

    /// typescript-language-server only resolves "typescript" from the workspace's own
    /// node_modules by default — this is how a global npm install gets used as a fallback.
    func start(rootURI: String, tsserverPath: String) async throws {
        try await startInternal(rootURI: rootURI, initializationOptions: TSServerInitializationOptions(tsserver: TSServerPathOption(path: tsserverPath)))
    }

    private func startInternal<Options: Encodable>(rootURI: String, initializationOptions: Options?) async throws {
        await transport.setHandlers(
            onMessage: { data in Task { await self.handleMessage(data) } },
            onTerminate: { Task { await self.handleTermination() } }
        )
        try await transport.start()
        isRunning = true
        _ = try await request(method: "initialize", params: InitializeParams(processId: Int(ProcessInfo.processInfo.processIdentifier), rootUri: rootURI, initializationOptions: initializationOptions))
        try await notify(method: "initialized", params: [String: String]())
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

    func didChange(uri: String, text: String, version: Int) async throws {
        try await notify(method: "textDocument/didChange", params: DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: [TextDocumentContentChangeEvent(text: text)]))
    }

    func didClose(uri: String) async throws {
        try await notify(method: "textDocument/didClose", params: DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri)))
    }

    /// Sends one queued op. Returns once the bytes are written — for a request, before the reply.
    func apply(_ op: LSPOutboundOp) async {
        switch op {
        case .didOpen(let uri, let languageId, let text, let version):
            try? await didOpen(uri: uri, languageId: languageId, text: text, version: version)
        case .didChange(let uri, let text, let version):
            try? await didChange(uri: uri, text: text, version: version)
        case .didClose(let uri):
            try? await didClose(uri: uri)
        case .completion(let uri, let position, let reply):
            await sendRequest(method: "textDocument/completion",
                              params: CompletionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position)) { reply(try? $0.get()) }
        case .definition(let uri, let position, let reply):
            await sendRequest(method: "textDocument/definition",
                              params: DefinitionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position)) { reply(try? $0.get()) }
        }
    }

    /// Returns the raw JSON-RPC response body; the shape of `result` (Location vs
    /// Location[] vs LocationLink[]) varies by server, so the caller decodes it.
    func definition(uri: String, position: LSPPosition) async throws -> Data {
        try await request(method: "textDocument/definition", params: DefinitionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position))
    }

    func completion(uri: String, position: LSPPosition) async throws -> Data {
        try await request(method: "textDocument/completion", params: CompletionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position))
    }

    // MARK: - JSON-RPC plumbing

    /// Writes a request and registers its reply handler; returns once the write is done.
    private func sendRequest<Params: Encodable>(method: String, params: Params, reply: @escaping @Sendable (Result<Data, Error>) -> Void) async {
        guard isRunning else { return reply(.failure(ClientError.notRunning)) }
        let id = nextRequestID
        nextRequestID += 1
        let data: Data
        do { data = try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params)) }
        catch { return reply(.failure(error)) }
        pendingRequests[id] = reply
        await transport.send(data)
    }

    private func request<Params: Encodable>(method: String, params: Params) async throws -> Data {
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

    private func handleMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let idNumber = object["id"] as? Int {
            guard let reply = pendingRequests.removeValue(forKey: idNumber) else { return }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown LSP error"
                let code = error["code"] as? Int ?? -1
                reply(.failure(ClientError.serverError(code: code, message: message)))
            } else {
                reply(.success(data))
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let paramsObject = object["params"],
                  let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
                  let params = try? JSONDecoder().decode(PublishDiagnosticsParams.self, from: paramsData) else { return }
            onDiagnostics?(params)
        default:
            break
        }
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

private struct NotificationEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

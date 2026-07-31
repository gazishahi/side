import Foundation

/// One running language server process, speaking JSON-RPC 2.0 / LSP over stdio.
actor LSPClient {
    enum ClientError: Error {
        case serverError(code: Int, message: String)
        case notRunning
    }

    private let transport: JSONRPCTransport
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
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
        await transport.setHandlers(
            onMessage: { data in Task { await self.handleMessage(data) } },
            onTerminate: { Task { await self.handleTermination() } }
        )
        try await transport.start()
        isRunning = true
        _ = try await request(method: "initialize", params: InitializeParams(processId: Int(ProcessInfo.processInfo.processIdentifier), rootUri: rootURI))
        try notify(method: "initialized", params: [String: String]())
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        await transport.stop()
        await transport.clearHandlers()
        failAllPending(with: ClientError.notRunning)
    }

    func didOpen(uri: String, languageId: String, text: String, version: Int) throws {
        try notify(method: "textDocument/didOpen", params: DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(uri: uri, languageId: languageId, version: version, text: text)))
    }

    func didChange(uri: String, text: String, version: Int) throws {
        try notify(method: "textDocument/didChange", params: DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: [TextDocumentContentChangeEvent(text: text)]))
    }

    func didClose(uri: String) throws {
        try notify(method: "textDocument/didClose", params: DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: uri)))
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

    private func request<Params: Encodable>(method: String, params: Params) async throws -> Data {
        guard isRunning else { throw ClientError.notRunning }
        let id = nextRequestID
        nextRequestID += 1
        let data = try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            Task { await transport.send(data) }
        }
    }

    private func notify<Params: Encodable>(method: String, params: Params) throws {
        guard isRunning else { return }
        let data = try JSONEncoder().encode(NotificationEnvelope(method: method, params: params))
        Task { await transport.send(data) }
    }

    private func handleMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let idNumber = object["id"] as? Int {
            guard let continuation = pendingRequests.removeValue(forKey: idNumber) else { return }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown LSP error"
                let code = error["code"] as? Int ?? -1
                continuation.resume(throwing: ClientError.serverError(code: code, message: message))
            } else {
                continuation.resume(returning: data)
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
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }
}

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

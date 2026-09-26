import Foundation

/// One debug adapter process, speaking the Debug Adapter Protocol over stdio
/// (SIDE_RFC_DEBUGGER.md, D1). The framing is LSP's (`Content-Length`), so it rides the same
/// transport; the messages are DAP's: requests and responses paired by `seq`, and events.
actor DAPClient {
    enum DAPError: Error, LocalizedError {
        case failed(command: String, message: String)
        case notRunning
        var errorDescription: String? {
            switch self {
            case .failed(let command, let message): return "\(command): \(message)"
            case .notRunning: return "The debugger isn't running."
            }
        }
    }

    private let transport: JSONRPCTransport
    private var nextSeq = 1
    private var pending: [Int: (command: String, reply: @Sendable (Result<LSPResult, DAPError>) -> Void)] = [:]
    private var onEvent: (@Sendable (String, LSPResult) -> Void)?
    private var onTerminate: (@Sendable () -> Void)?
    /// The adapter asking the client (`runInTerminal`): the reply's body, or an error message.
    typealias ReverseRequestHandler = @Sendable (String, LSPResult) async -> Result<LSPValue, DAPError>
    private var onReverseRequest: ReverseRequestHandler?
    private(set) var isRunning = false

    init(executableURL: URL, arguments: [String], environment: [String: String]?, currentDirectory: URL?) {
        transport = JSONRPCTransport(executableURL: executableURL, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
    }

    func setHandlers(onEvent: @escaping @Sendable (String, LSPResult) -> Void, onTerminate: @escaping @Sendable () -> Void,
                     onReverseRequest: ReverseRequestHandler? = nil) {
        self.onEvent = onEvent
        self.onTerminate = onTerminate
        self.onReverseRequest = onReverseRequest
    }

    func start() async throws {
        await transport.setHandlers(
            onMessage: { data in Task { await self.handle(data) } },
            onTerminate: { Task { await self.terminated() } }
        )
        try await transport.start()
        isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        await transport.stop()
        await transport.clearHandlers()
        fail(.notRunning)
    }

    /// A request and its response's `body` (an empty object when there's none).
    @discardableResult
    func request(_ command: String, _ arguments: LSPValue = [:]) async throws -> LSPResult {
        try await withCheckedThrowingContinuation { continuation in
            Task { await self.send(command, arguments) { continuation.resume(with: $0) } }
        }
    }

    /// Writes a request; `reply` hears its response. Returns once written.
    func send(_ command: String, _ arguments: LSPValue, reply: @escaping @Sendable (Result<LSPResult, DAPError>) -> Void) async {
        guard isRunning else { return reply(.failure(.notRunning)) }
        let seq = nextSeq
        nextSeq += 1
        let message: LSPValue = ["seq": .int(seq), "type": "request", "command": .string(command), "arguments": arguments]
        guard let data = try? JSONEncoder().encode(message) else { return reply(.failure(.failed(command: command, message: "unencodable"))) }
        pending[seq] = (command, reply)
        Self.log("→ " + String(decoding: data, as: UTF8.self))
        await transport.send(data)
    }

    /// SIDE_DAP_LOG=<file>: every message, both ways (for diagnosing an adapter).
    private static let logPath = ProcessInfo.processInfo.environment["SIDE_DAP_LOG"]
    private static func log(_ line: String) {
        guard let logPath, let handle = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)
        }() else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line.prefix(2000) + "\n").utf8))
        try? handle.close()
    }

    private func handle(_ data: Data) {
        Self.log("← " + String(decoding: data, as: UTF8.self))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { return }
        switch type {
        case "response":
            guard let seq = object["request_seq"] as? Int, let entry = pending.removeValue(forKey: seq) else { return }
            if object["success"] as? Bool ?? false {
                entry.reply(.success(LSPResult(value: object["body"] ?? [String: Any]())))
            } else {
                let message = (object["body"] as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["format"] as? String }
                    ?? object["message"] as? String ?? "failed"
                entry.reply(.failure(.failed(command: entry.command, message: message)))
            }
        case "event":
            guard let event = object["event"] as? String else { return }
            onEvent?(event, LSPResult(value: object["body"] ?? [String: Any]()))
        case "request":
            // The adapter asking the client (`runInTerminal`); what has no handler is refused.
            guard let seq = object["seq"] as? Int, let command = object["command"] as? String else { return }
            let arguments = LSPResult(value: object["arguments"] ?? [String: Any]())
            let handler = onReverseRequest
            Task {
                let result = await handler?(command, arguments) ?? .failure(.failed(command: command, message: "\(command) isn't supported"))
                self.answer(seq: seq, command: command, result)
            }
        default:
            break
        }
    }

    private func answer(seq: Int, command: String, _ result: Result<LSPValue, DAPError>) {
        var reply: [String: LSPValue] = ["seq": .int(nextSeq), "type": "response", "request_seq": .int(seq), "command": .string(command)]
        nextSeq += 1
        switch result {
        case .success(let body): reply["success"] = true; reply["body"] = body
        case .failure(let error): reply["success"] = false; reply["message"] = .string(error.localizedDescription)
        }
        guard isRunning, let data = try? JSONEncoder().encode(LSPValue.object(reply)) else { return }
        Self.log("→ " + String(decoding: data, as: UTF8.self))
        Task { await transport.send(data) }
    }

    private func terminated() {
        isRunning = false
        fail(.notRunning)
        onTerminate?()
    }

    private func fail(_ error: DAPError) {
        for (_, entry) in pending { entry.reply(.failure(error)) }
        pending.removeAll()
    }
}

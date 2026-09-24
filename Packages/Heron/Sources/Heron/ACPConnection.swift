import Foundation

/// JSON-RPC 2.0 with an agent over its stdio, as the Agent Client Protocol frames it: one JSON
/// message per line, no embedded newlines; the agent's stderr is logging, kept as a short tail
/// for error messages. Requests out get a completion; requests *in* (permission prompts, and
/// later file and terminal calls) go to `onRequest`, which answers through `respond`.
@MainActor
public final class ACPConnection {
    public struct RemoteError: Error, LocalizedError {
        public let code: Int
        public let message: String
        public var errorDescription: String? { message }
    }

    /// (method, params) for notifications from the agent.
    public var onNotification: ((String, [String: Any]) -> Void)?
    /// (id, method, params) for requests from the agent; answer with `respond` or `respondError`.
    public var onRequest: ((Any, String, [String: Any]) -> Void)?
    /// The process ended (message includes the stderr tail).
    public var onExit: ((String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var nextId = 1
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var buffer = Data()
    private var stderrTail = ""
    private var exited = false

    public init(launch: ACPLaunch, cwd: URL) throws {
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Both pipes are drained continuously — a full pipe blocks the agent (ProcessHygiene).
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveLog(data) } }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didExit(status: status) } }
        }
        try process.run()
    }

    public var isRunning: Bool { !exited && process.isRunning }

    public func request(_ method: String, params: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        let id = nextId
        nextId += 1
        pending[id] = completion
        guard write(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
            pending.removeValue(forKey: id)
            completion(.failure(RemoteError(code: -32000, message: "The agent isn't running.")))
            return
        }
    }

    public func notify(_ method: String, params: [String: Any]) {
        _ = write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    public func respond(id: Any, result: [String: Any]) {
        _ = write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    public func respondError(id: Any, code: Int, message: String) {
        _ = write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    public func terminate() {
        guard !exited else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        exited = true
        failPending("The agent was stopped.")
    }

    // MARK: - Framing

    @discardableResult
    private func write(_ message: [String: Any]) -> Bool {
        guard !exited, process.isRunning,
              var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return false }
        // JSONSerialization never emits raw newlines (it escapes them in strings); one message, one line.
        data.append(0x0A)
        stdinPipe.fileHandleForWriting.write(data)
        return true
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: [String: Any]) {
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if let method {
            if let id = message["id"] { onRequest?(id, method, params) } else { onNotification?(method, params) }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue, let completion = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            completion(.failure(RemoteError(code: (error["code"] as? NSNumber)?.intValue ?? -32000,
                                            message: error["message"] as? String ?? "The agent returned an error.")))
        } else {
            completion(.success(message["result"] ?? [String: Any]()))
        }
    }

    private func receiveLog(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        stderrTail = String((stderrTail + text).suffix(2_000))
    }

    private func didExit(status: Int32) {
        guard !exited else { return }
        exited = true
        failPending("The agent exited (status \(status)).")
        // The last of its error output can still be in flight when the exit is noticed (the two
        // arrive on different threads), and it's usually the part that says why. Report once
        // it's had a moment to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                self.onExit?("The agent exited (status \(status))" + (tail.isEmpty ? "." : ": \(String(tail.suffix(400)))"))
            }
        }
    }

    private func failPending(_ message: String) {
        let waiting = pending
        pending.removeAll()
        for completion in waiting.values { completion(.failure(RemoteError(code: -32000, message: message))) }
    }
}

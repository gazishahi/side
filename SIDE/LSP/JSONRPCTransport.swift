import Foundation
import Heron

/// Frames JSON-RPC messages over a language server's stdin/stdout using the
/// `Content-Length: N\r\n\r\n<json>` framing required by the LSP spec.
actor JSONRPCTransport {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var framing = JSONRPCFraming()
    /// Raw stdout chunks, in arrival order. The readability handler used to spawn one detached
    /// `Task` per chunk, and detached tasks have no ordering — two chunks could be consumed
    /// transposed, splicing one message's bytes into another. Same class as the outbound race
    /// fixed in `LSPOutboundQueue`, on the receiving side. `yield` from the handler is synchronous
    /// and ordered; one drain loop consumes in that order.
    private var chunkContinuation: AsyncStream<Data>.Continuation?

    private var onMessage: (@Sendable (Data) -> Void)?
    private var onTerminate: (@Sendable () -> Void)?
    private let logLabel: String

    func setHandlers(onMessage: @escaping @Sendable (Data) -> Void, onTerminate: @escaping @Sendable () -> Void) {
        self.onMessage = onMessage
        self.onTerminate = onTerminate
    }

    /// Breaks the retain cycle formed by these closures capturing the owning LSPClient.
    func clearHandlers() {
        onMessage = nil
        onTerminate = nil
    }

    init(executableURL: URL, arguments: [String], environment: [String: String]?, currentDirectory: URL?) {
        logLabel = executableURL.lastPathComponent
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        chunkContinuation = continuation
        Task { [weak self] in
            for await chunk in chunks { await self?.consume(chunk) }
        }
        // Empty data is end of file: the handler goes then, or it's called with nothing about
        // 400,000 times a second until Side quits (2026-09-30 audit, H7: a server that crashed
        // left a core spinning, since `stop()` does nothing once the process has ended).
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
        // Previously discarded entirely — when a server process dies right after spawn (e.g.
        // a shebang interpreter it needs isn't resolvable), this stderr output is the only
        // place the real reason ever appears; without it every such failure just looked like
        // a generic "notRunning".
        let label = logLabel
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            print("[LSP][\(label) stderr] \(text)")
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }
        try process.run()
    }

    func stop() {
        chunkContinuation?.finish()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    func send(_ data: Data) {
        guard process.isRunning else { return }
        var framed = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)!
        framed.append(data)
        // A server that crashed after the `isRunning` check mustn't take Side with it.
        if !PipeWriting.write(framed, to: stdinPipe.fileHandleForWriting) {
            print("[LSP][\(logLabel)] the server stopped reading; dropped \(data.count) bytes")
        }
    }

    private func consume(_ data: Data) {
        let (messages, problems) = framing.feed(data)
        for problem in problems { print("[LSP][\(logLabel)] malformed frame: \(problem)") }
        for message in messages { onMessage?(message) }
    }

    private func handleTermination() {
        onTerminate?()
    }
}

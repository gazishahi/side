import Foundation

/// Frames JSON-RPC messages over a language server's stdin/stdout using the
/// `Content-Length: N\r\n\r\n<json>` framing required by the LSP spec.
actor JSONRPCTransport {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var buffer = Data()
    private var expectedContentLength: Int?

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
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        // Previously discarded entirely — when a server process dies right after spawn (e.g.
        // a shebang interpreter it needs isn't resolvable), this stderr output is the only
        // place the real reason ever appears; without it every such failure just looked like
        // a generic "notRunning".
        let label = logLabel
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            print("[LSP][\(label) stderr] \(text)")
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }
        try process.run()
    }

    func stop() {
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
        stdinPipe.fileHandleForWriting.write(framed)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while true {
            if expectedContentLength == nil {
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    buffer.removeAll()
                    return
                }
                var length: Int?
                for line in headerString.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let value = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
                        length = value.flatMap(Int.init)
                    }
                }
                guard let length else {
                    buffer.removeAll()
                    return
                }
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                expectedContentLength = length
            }
            guard let length = expectedContentLength, buffer.count >= length else { return }
            let messageEnd = buffer.index(buffer.startIndex, offsetBy: length)
            let messageData = buffer.subdata(in: buffer.startIndex..<messageEnd)
            buffer.removeSubrange(buffer.startIndex..<messageEnd)
            expectedContentLength = nil
            onMessage?(messageData)
        }
    }

    private func handleTermination() {
        onTerminate?()
    }
}

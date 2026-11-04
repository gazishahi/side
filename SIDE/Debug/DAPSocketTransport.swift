import Foundation

/// How Side reaches a debug adapter (SIDE_RFC_DEBUGGER.md, D1).
enum DAPConnection: Sendable, Equatable {
    /// A process speaking DAP on its stdin and stdout (lldb-dap, debugpy).
    case stdio(executable: URL, arguments: [String])
    /// A process serving DAP on a port Side picks: `{port}` in its arguments is replaced with it
    /// (js-debug, Delve). Side connects once it listens.
    case server(executable: URL, arguments: [String])
    /// Another connection to a server a session already runs (js-debug's child sessions).
    case socket(port: UInt16)
}

/// What a DAP client reads and writes messages through: a process's pipes, or a socket.
protocol DAPTransport: Actor {
    func setHandlers(onMessage: @escaping @Sendable (Data) -> Void, onTerminate: @escaping @Sendable () -> Void)
    func clearHandlers()
    func start() async throws
    func stop()
    func send(_ data: Data)
}

extension JSONRPCTransport: DAPTransport {}

/// DAP over TCP on the loopback interface, with the server process it started (if any).
actor DAPSocketTransport: DAPTransport {
    enum Failure: Error, LocalizedError {
        case noPort
        case couldNotConnect(UInt16, String)
        var errorDescription: String? {
            switch self {
            case .noPort: return "No free port for the debugger."
            case .couldNotConnect(let port, let log): return "The debugger didn't listen on port \(port)." + (log.isEmpty ? "" : " It said: \(log)")
            }
        }
    }

    /// The port it's connected to (a child session connects to the same one).
    let port: UInt16
    private let server: Process?
    private var serverLog = ""
    private var socket: Int32 = -1
    private var handle: FileHandle?
    private var framing = JSONRPCFraming()
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onTerminate: (@Sendable () -> Void)?
    private var terminated = false

    /// A server to start on a free port (its arguments' `{port}` filled in), or just a port.
    init(server executable: URL?, arguments: [String] = [], environment: [String: String]? = nil, currentDirectory: URL? = nil, port: UInt16) {
        self.port = port
        if let executable {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments.map { $0.replacingOccurrences(of: "{port}", with: String(port)) }
            if let environment { process.environment = environment }
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            process.standardInput = FileHandle.nullDevice
            server = process
        } else {
            server = nil
        }
    }

    /// The servers running, to end with Side: a server adapter (node running js-debug) outlives
    /// the client that started it.
    nonisolated private static let running = DebugLockedBox<[ObjectIdentifier: Process]>([:])

    /// Ends every server adapter at once (Side is quitting).
    nonisolated static func terminateAllServers() {
        for process in running.withLock({ $0.values }) where process.isRunning { process.terminate() }
    }

    /// A port nothing listens on now: bound to port 0, the system's pick, then released.
    nonisolated static func freePort() -> UInt16? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    func setHandlers(onMessage: @escaping @Sendable (Data) -> Void, onTerminate: @escaping @Sendable () -> Void) {
        self.onMessage = onMessage
        self.onTerminate = onTerminate
    }

    func clearHandlers() {
        onMessage = nil
        onTerminate = nil
    }

    func start() async throws {
        if let server {
            let pipe = Pipe()
            server.standardOutput = pipe
            server.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                Task { await self?.logServer(data) }
            }
            let key = ObjectIdentifier(server)
            server.terminationHandler = { [weak self] _ in
                Self.running.withLock { $0[key] = nil }
                Task { await self?.ended() }
            }
            try server.run()
            Self.running.withLock { $0[key] = server }
        }
        // It listens a moment after it starts (node loading js-debug takes the longest).
        let deadline = Date().addingTimeInterval(15)
        while true {
            if let fd = Self.connect(port) {
                attach(fd)
                return
            }
            if Date() > deadline || (server.map { !$0.isRunning } ?? false) {
                stop()
                throw Failure.couldNotConnect(port, serverLog.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func logServer(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        if serverLog.utf16.count < 8_000 { serverLog += text }
        print("[DAP][server] \(text)", terminator: text.hasSuffix("\n") ? "" : "\n")
    }

    private nonisolated static func connect(_ port: UInt16) -> Int32? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func attach(_ fd: Int32) {
        socket = fd
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        self.handle = handle
        // Chunks in arrival order, one consumer (as `JSONRPCTransport` does).
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        chunkContinuation = continuation
        Task { [weak self] in
            for await chunk in chunks { await self?.consume(chunk) }
            await self?.ended()
        }
        handle.readabilityHandler = { handle in
            // read(2), not `availableData`: on a socket closed under it `availableData` raises an
            // Objective-C exception, which aborts the app (a test run crashed so, 2026-11-04).
            // read returns -1 instead, and the stream just ends.
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(handle.fileDescriptor, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            if count <= 0 {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(Data(buffer[0..<count]))
            }
        }
    }

    private func consume(_ data: Data) {
        let (messages, problems) = framing.feed(data)
        for problem in problems { print("[DAP][socket] malformed frame: \(problem)") }
        for message in messages { onMessage?(message) }
    }

    private func ended() {
        guard !terminated else { return }
        terminated = true
        onTerminate?()
    }

    func send(_ data: Data) {
        guard socket >= 0 else { return }
        var framed = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        framed.append(data)
        framed.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func stop() {
        handle?.readabilityHandler = nil
        chunkContinuation?.finish()
        if socket >= 0 { close(socket); socket = -1 }
        if let server, server.isRunning { server.terminate() }
    }
}

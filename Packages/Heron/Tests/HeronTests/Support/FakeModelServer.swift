import Foundation
import Network

/// A model API on the loopback, for measuring what Heron sends (SIDE_RFC_HERON_EFFICIENCY.md,
/// step 1): it records every request body and answers each with a scripted stream in the
/// Anthropic Messages format.
final class FakeModelServer: @unchecked Sendable {
    /// What one request is answered with: tool calls (name, JSON input) to make, or final text.
    enum Reply {
        case tools([(name: String, input: String)])
        case text(String)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-model-server")
    private let lock = NSLock()
    private var bodies: [Data] = []
    private let script: @Sendable (_ index: Int, _ body: [String: Any]) -> Reply
    private(set) var port: UInt16 = 0

    /// Request bodies, in order (the `/v1/models` refresh isn't one).
    var requests: [Data] { lock.withLock { bodies } }

    init(script: @escaping @Sendable (_ index: Int, _ body: [String: Any]) -> Reply) throws {
        self.script = script
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    /// The request line and body, once all of it has arrived.
    private static func parse(_ buffer: Data) -> (path: String, body: Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let length = lines.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return (path, Data(body.prefix(length)))
    }

    private func respond(to request: (path: String, body: Data), on connection: NWConnection) {
        guard request.path.hasPrefix("/v1/messages") else {
            // The model list: "none new", so the seeded ones stay.
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }
        let index: Int = lock.withLock {
            bodies.append(request.body)
            return bodies.count - 1
        }
        let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let reply = script(index, object)
        var stream = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        func event(_ type: String, _ payload: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            stream += "event: \(type)\ndata: \(data)\n\n"
        }
        // Usage as the real API reports it: what the request carried, all uncached here.
        let promptTokens = request.body.count / 4
        event("message_start", ["type": "message_start", "message": ["id": "msg_\(index)", "usage": ["input_tokens": promptTokens, "output_tokens": 1]]])
        switch reply {
        case .text(let text):
            event("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
            event("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]])
            event("content_block_stop", ["type": "content_block_stop", "index": 0])
            event("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": max(1, text.count / 4)]])
        case .tools(let calls):
            for (position, call) in calls.enumerated() {
                event("content_block_start", ["type": "content_block_start", "index": position,
                                              "content_block": ["type": "tool_use", "id": "toolu_\(index)_\(position)", "name": call.name, "input": [String: Any]()]])
                event("content_block_delta", ["type": "content_block_delta", "index": position, "delta": ["type": "input_json_delta", "partial_json": call.input]])
                event("content_block_stop", ["type": "content_block_stop", "index": position])
            }
            event("message_delta", ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 40 * calls.count]])
        }
        event("message_stop", ["type": "message_stop"])
        send(stream, on: connection)
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

import Foundation

/// One Server-Sent Events frame: an optional `event:` name plus a `data:` payload.
struct SSEEvent {
    let event: String?
    let data: String
}

enum SSEHTTPClientError: Error, LocalizedError {
    case notHTTP
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notHTTP:
            return "The response was not an HTTP response."
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body)"
        }
    }
}

/// The streaming transport Heron's provider adapters share — plays the same role
/// JSONRPCTransport's Content-Length parser plays for LSP, just for a different framing
/// (SSE `data:` lines over HTTP instead of length-prefixed frames over stdio). Provider-
/// agnostic: each adapter owns only its own request-building and payload parsing on top.
enum SSEHTTPClient {
    /// A dedicated session, not `.shared` — its whole purpose is the explicit request timeout
    /// below, which `.shared`'s default configuration also happens to set to 60s but not in a
    /// way any caller here controls or can point to. `timeoutIntervalForRequest` resets on any
    /// received byte, so this is a "the connection produced literally nothing for 60s" backstop
    /// underneath `AgentRunner`'s own 90s stall watchdog, which instead watches for meaningful
    /// SSE events — the two catch different failure shapes (a dead TCP connection vs. a live one
    /// that stopped saying anything useful).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    /// Streams `request`, invoking `onEvent` once per SSE frame, in order, from the caller's
    /// own task — no queue hopping happens here. Returns when the server closes the stream;
    /// throws for transport failures (connection refused/dropped, task cancellation) and for
    /// non-200 responses (with the response body captured, since providers put their error
    /// JSON there). Honors Swift task cancellation — cancelling the surrounding task tears
    /// down the connection mid-stream.
    ///
    /// Dispatches on each `data:` line rather than waiting for the blank-line frame
    /// terminator: every provider this client targets (Anthropic, OpenAI-compatible) sends
    /// one complete JSON payload per `data:` line, and not relying on empty lines sidesteps
    /// any ambiguity in how AsyncLineSequence reports them. Multi-line `data:` payloads are
    /// deliberately unsupported.
    static func stream(request: URLRequest, onEvent: (SSEEvent) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SSEHTTPClientError.notHTTP }
        guard http.statusCode == 200 else {
            // The error body arrives on the same byte stream — collect it (bounded) so the
            // caller can surface the provider's actual message instead of a bare status code.
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 20_000 { break }
            }
            throw SSEHTTPClientError.httpError(statusCode: http.statusCode, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var currentEventName: String?
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                currentEventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                onEvent(SSEEvent(event: currentEventName, data: payload))
            }
            // Comment lines (":keepalive") and other fields are ignored per the SSE spec.
        }
    }
}

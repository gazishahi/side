import XCTest
@testable import Side

/// The regression tests the 2026-09-01 audit listed in Part V item 15 that were not tied to a fix
/// already made — written now so "closed" means test-pinned, not commit-message-pinned.

// MARK: - JSON-RPC framing

final class JSONRPCFramingTests: XCTestCase {
    private func frame(_ body: String, length: Int? = nil) -> Data {
        let n = length ?? body.utf8.count
        return Data("Content-Length: \(n)\r\n\r\n".utf8) + Data(body.utf8)
    }

    func testBadContentLengthsAreReportedNotTrappedAndTheStreamRecovers() {
        // `Int("-5")` is a valid Int; indexing a buffer by it is a crash. Now it is a problem
        // report, and the stream keeps going; an absurd length is refused rather than buffered.
        var negative = JSONRPCFraming()
        // A negative length has no body worth the name; the next header follows directly.
        let clean = negative.feed(frame("", length: -5) + frame("{\"ok\":1}"))
        XCTAssertEqual(clean.problems, [.invalidContentLength(-5)])
        XCTAssertEqual(clean.messages.map { String(decoding: $0, as: UTF8.self) }, ["{\"ok\":1}"])

        // Bytes that were the bad frame's "body" corrupt the next header; both are reported, none
        // crash, and a clean frame after them is delivered.
        var junk = JSONRPCFraming()
        let recovered = junk.feed(frame("{}", length: -5) + frame("{\"a\":1}") + frame("{\"b\":2}"))
        XCTAssertEqual(recovered.problems.first, .invalidContentLength(-5))
        XCTAssertEqual(recovered.messages.map { String(decoding: $0, as: UTF8.self) }.last, "{\"b\":2}")

        var absurd = JSONRPCFraming()
        let refused = absurd.feed(frame("{}", length: 5_000_000_000))
        XCTAssertEqual(refused.problems, [.invalidContentLength(5_000_000_000)])
        XCTAssertTrue(refused.messages.isEmpty)
    }

    func testMessagesReassembleAcrossChunksAndArriveInOrder() {
        var framing = JSONRPCFraming()
        let whole = frame("{\"method\":\"x\"}")
        let first = framing.feed(whole.prefix(10))
        XCTAssertTrue(first.messages.isEmpty)
        let second = framing.feed(whole.suffix(from: 10))
        XCTAssertEqual(second.messages.map { String(decoding: $0, as: UTF8.self) }, ["{\"method\":\"x\"}"])
        // Two whole messages in one chunk come out of the same stream in order.
        let both = framing.feed(frame("{\"a\":1}") + frame("{\"b\":2}"))
        XCTAssertEqual(both.messages.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testAHeaderWithoutContentLengthIsSkipped() {
        var framing = JSONRPCFraming()
        let result = framing.feed(Data("Content-Type: x\r\n\r\n".utf8) + frame("{}"))
        XCTAssertEqual(result.problems, [.missingContentLength])
        XCTAssertEqual(result.messages.count, 1)
    }
}

// MARK: - SSE framing and cancellation

final class SSEFramingTests: XCTestCase {
    func testLinesBecomeEventsOnlyWhenTheyCarryData() {
        // An event name applies to the data line that follows it; comments, ids, retry hints and
        // blank lines produce nothing; data with no event name is still delivered.
        let cases: [(line: String, event: String?, data: String?)] = [
            ("event: message_start", nil, nil),
            ("data: {\"type\":\"message_start\"}", "message_start", "{\"type\":\"message_start\"}"),
            (":keepalive", nil, nil),
            ("id: 7", nil, nil),
            ("retry: 3000", nil, nil),
            ("", nil, nil),
            ("data: [DONE]", nil, "[DONE]"),
        ]
        var name: String?
        for c in cases {
            let event = SSEFraming.event(fromLine: c.line, eventName: &name)
            XCTAssertEqual(event?.data, c.data, c.line)
            if let expectedName = c.event { XCTAssertEqual(event?.event, expectedName, c.line) }
        }
    }

    /// Cancelling the surrounding task must tear the connection down promptly — a stream that
    /// keeps arriving after Stop is a stream that keeps billing.
    func testCancellationStopsAStreamThatWouldOtherwiseRunForever() async throws {
        let script = """
        import http.server, socketserver, sys, time
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
                try:
                    for i in range(1000):
                        self.wfile.write(f'data: {{"n":{i}}}\\n\\n'.encode()); self.wfile.flush(); time.sleep(0.05)
                except BrokenPipeError:
                    pass
            do_GET = do_POST
            def log_message(self, *a): pass
        with socketserver.TCPServer(('127.0.0.1', 0), H) as srv:
            print(srv.server_address[1], flush=True); srv.serve_forever()
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("sse-\(UUID().uuidString).py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        guard let port = Int(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XCTSkip("no local server")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"

        final class Counter: @unchecked Sendable { var events = 0 }
        let counter = Counter()
        let task = Task {
            try await SSEHTTPClient.stream(request: request) { _ in counter.events += 1 }
        }
        // Wait for the stream to actually start — a fixed sleep flaked under load, when python
        // and the connection took longer than the sleep — then let a few more events arrive.
        let deadline = Date().addingTimeInterval(5)
        while counter.events == 0, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let seenBeforeCancel = counter.events
        XCTAssertGreaterThan(seenBeforeCancel, 0, "the stream never started")
        let started = Date()
        task.cancel()
        let outcome = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "cancellation did not tear the stream down promptly")
        if case .success = outcome { XCTFail("a cancelled stream reported success") }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThanOrEqual(counter.events, seenBeforeCancel + 2, "events kept arriving after cancellation")
    }
}

// MARK: - OpenAI-compatible parser

final class OpenAICompatibleParserTests: XCTestCase {
    private func events(_ payloads: [String]) -> [AgentStreamEvent] {
        let state = OpenAICompatibleChatProvider.TurnState()
        var out: [AgentStreamEvent] = []
        for payload in payloads { _ = OpenAICompatibleChatProvider.handle(sse: SSEEvent(event: nil, data: payload), state: state) { out.append($0) } }
        return out
    }

    func testTextDeltasUsageAndTheDoneSentinel() {
        // Usage arrives in its own choices-less chunk after the finish reason; both survive to
        // the messageEnd the sentinel produces.
        let out = events([
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30}}"#,
            "[DONE]",
        ])
        XCTAssertEqual(out.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }.joined(), "Hello")
        guard case .messageEnd(let reason, let usage)? = out.last else { return XCTFail("no messageEnd") }
        XCTAssertEqual(reason, .endTurn)
        XCTAssertEqual(usage?.inputTokens, 120)
        XCTAssertEqual(usage?.outputTokens, 30)
    }

    func testAToolCallAssemblesAcrossChunksAndEndsAtDone() {
        let out = events([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])
        var partial = ""
        var started = false, ended = false
        for event in out {
            switch event {
            case .toolUseStart(let id, let name): started = id == "call_1" && name == "read_file"
            case .toolUseInputDelta(_, let json): partial += json
            case .toolUseEnd(let id): ended = id == "call_1"
            default: break
            }
        }
        XCTAssertTrue(started); XCTAssertTrue(ended)
        XCTAssertEqual(partial, #"{"path":"a"}"#)
        guard case .messageEnd(let reason, _)? = out.last else { return XCTFail("no messageEnd") }
        XCTAssertEqual(reason, .toolUse)
    }

    func testMalformedChunksAreIgnored() {
        XCTAssertTrue(events(["not json", #"{"choices":"nope"}"#]).isEmpty)
    }
}

// MARK: - Truncated stream

final class TruncatedStreamTests: XCTestCase {
    func testAnAnthropicStreamThatEndsWithoutMessageStopEmitsNoMessageEnd() {
        // The runner treats "no messageEnd" as a failure rather than an empty answer; that only
        // works if the provider never synthesizes one for a stream that just stopped.
        let state = AnthropicMessagesProvider.TurnState()
        var out: [AgentStreamEvent] = []
        for payload in [
            #"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half an ans"}}"#,
        ] {
            AnthropicMessagesProvider.handle(sse: SSEEvent(event: nil, data: payload), state: state) { out.append($0) }
        }
        XCTAssertFalse(out.contains { if case .messageEnd = $0 { return true } else { return false } })
        XCTAssertEqual(out.count, 1)
    }
}

// MARK: - Checkpoint staging

final class CheckpointStagingTests: XCTestCase {
    func testAPreStagedManualEditIsNotSweptIntoTheAgentsCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            let r = GitPaths.runGit(args, cwd: root.path); XCTAssertTrue(r.success, "git \(args): \(r.output)"); return r.output
        }
        git(["init", "-q", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        try "a".write(to: root.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        try "m".write(to: root.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-q", "-m", "base"])

        // The user has a manual edit *staged* before the agent's batch begins.
        try "manual v2".write(to: root.appendingPathComponent("manual.txt"), atomically: true, encoding: .utf8)
        git(["add", "manual.txt"])
        let baseline = GitPaths.dirtyPaths(cwd: root.path)
        XCTAssertEqual(baseline, ["manual.txt"])

        // The agent's batch edits its own file.
        try "agent v2".write(to: root.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        let outcome = AgentRunner.stageAndCommit(root: root.path, baseline: baseline, knownChanged: ["agent.txt"], message: "agent work")
        guard case .committed(_, let paths)? = outcome else { return XCTFail("expected a commit, got \(String(describing: outcome))") }
        XCTAssertEqual(paths, ["agent.txt"])
        // The commit contains only the agent's file; the manual edit is still staged, uncommitted.
        XCTAssertEqual(git(["show", "--name-only", "--format=", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), "agent.txt")
        XCTAssertEqual(git(["diff", "--cached", "--name-only"]).trimmingCharacters(in: .whitespacesAndNewlines), "manual.txt")
    }
}

// MARK: - Minimal tasks.json

final class ProjectTaskDecodeTests: XCTestCase {
    func testATaskWithOnlyNameAndCommandDecodes() throws {
        let tasks = try JSONDecoder().decode([ProjectTask].self, from: Data(#"[{"name":"test","command":"swift test"}]"#.utf8))
        XCTAssertEqual(tasks.first?.name, "test")
        XCTAssertEqual(tasks.first?.detail, "")
        XCTAssertEqual(tasks.first?.isVerification, false)
    }
}

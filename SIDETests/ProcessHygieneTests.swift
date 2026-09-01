import XCTest
@testable import Side

/// Two subprocess hazards the codebase has now fixed three times, checked statically so the
/// fourth time fails a test instead of hanging a user.
///
/// 1. `waitUntilExit()` before `readDataToEndOfFile()`: once the child fills the ~64 KB pipe
///    buffer it blocks writing while we block waiting, and neither side ever moves.
/// 2. `standardOutput = Pipe()` / `standardError = Pipe()` with nothing holding the pipe: the
///    child blocks the same way the moment it writes more than 64 KB, and nothing will ever read.
///    Output nobody wants goes to `FileHandle.nullDevice`, which never fills.
final class ProcessHygieneTests: XCTestCase {
    private var sourceFiles: [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SIDE")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testNoPipeIsCreatedWithoutAReader() throws {
        var offenders: [String] = []
        for file in sourceFiles {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("standardOutput = Pipe()") || trimmed.hasSuffix("standardError = Pipe()") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "pipes nobody reads (use FileHandle.nullDevice): \(offenders)")
    }

    func testNoWaitBeforeRead() throws {
        var offenders: [String] = []
        for file in sourceFiles {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("waitUntilExit()") {
                let window = lines[(index + 1)..<min(index + 4, lines.count)]
                if window.contains(where: { $0.contains("readDataToEndOfFile()") }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "waitUntilExit before readDataToEndOfFile deadlocks past 64 KB: \(offenders)")
    }
}

/// H2: the API key must never follow a redirect.
final class SSERedirectTests: XCTestCase {
    /// One Python HTTP server: `/start` answers 302 → `/leak`; `/leak` writes the headers it
    /// received to `leakFile`. The process prints its port on the first line of stdout.
    private func startServer(leakFile: URL) throws -> (process: Process, port: Int) {
        let script = """
        import http.server, socketserver, sys, json
        LEAK = sys.argv[1]
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path == '/start':
                    self.send_response(302); self.send_header('Location', '/leak'); self.end_headers(); return
                if self.path == '/leak':
                    open(LEAK, 'w').write(json.dumps(dict(self.headers)))
                    self.send_response(200); self.end_headers(); self.wfile.write(b'data: {}\\n\\n'); return
                self.send_response(404); self.end_headers()
            do_GET = do_POST
            def log_message(self, *a): pass
        with socketserver.TCPServer(('127.0.0.1', 0), H) as srv:
            print(srv.server_address[1], flush=True)
            srv.serve_forever()
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("redirect-\(UUID().uuidString).py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path, leakFile.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let first = out.fileHandleForReading.availableData
        guard let port = Int(String(decoding: first, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw XCTSkip("could not start a local HTTP server (python3 unavailable?)")
        }
        return (process, port)
    }

    func testTheKeyDoesNotFollowARedirect() async throws {
        let leakFile = FileManager.default.temporaryDirectory.appendingPathComponent("leak-\(UUID().uuidString).json")
        let server = try startServer(leakFile: leakFile)
        defer { server.process.terminate() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/start")!)
        request.httpMethod = "POST"
        request.setValue("sk-test-secret", forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer sk-test-secret", forHTTPHeaderField: "Authorization")

        do {
            try await SSEHTTPClient.stream(request: request) { _ in }
            XCTFail("a redirect was followed and the stream 'succeeded'")
        } catch SSEHTTPClientError.httpError(let status, _) {
            // The 302 surfaces as itself rather than being silently obeyed.
            XCTAssertEqual(status, 302)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leakFile.path), "the redirect target received the request — and with it the key")
    }
}

import XCTest
@testable import Side
@testable import Heron

/// Two subprocess hazards the codebase has now fixed three times, checked statically so the
/// fourth time fails a test instead of hanging a user.
///
/// 1. `waitUntilExit()` before `readDataToEndOfFile()`: once the child fills the ~64 KB pipe
///    buffer it blocks writing while we block waiting, and neither side ever moves.
/// 2. `standardOutput = Pipe()` / `standardError = Pipe()` with nothing holding the pipe: the
///    child blocks the same way the moment it writes more than 64 KB, and nothing will ever read.
///    Output nobody wants goes to `FileHandle.nullDevice`, which never fills.
/// Every Swift source Side ships: the app and the Heron package. Tree-scanning tests read this,
/// so the engine moving into its own package doesn't quietly drop it from their coverage.
enum SourceTree {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static var swiftFiles: [URL] {
        ["SIDE", "Packages/Heron/Sources"].flatMap { dir in
            (FileManager.default.enumerator(at: repoRoot.appendingPathComponent(dir), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        }
    }
}

final class ProcessHygieneTests: XCTestCase {
    private var sourceFiles: [URL] { SourceTree.swiftFiles }

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
    /// One Python HTTP server: `/start` (and anything under it) answers 302 → `/leak`; `/leak` writes the headers it
    /// received to `leakFile`. The process prints its port on the first line of stdout.
    private func startServer(leakFile: URL) throws -> (process: Process, port: Int) {
        let script = """
        import http.server, socketserver, sys, json
        LEAK = sys.argv[1]
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path.startswith('/start'):
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

    /// 2026-09-30 audit, SEC-12: the daily model-list refresh used `.shared`, which followed a
    /// 302 with the key header on.
    func testTheModelListRefreshDoesNotFollowARedirect() throws {
        let leakFile = FileManager.default.temporaryDirectory.appendingPathComponent("leak-\(UUID().uuidString).json")
        let server = try startServer(leakFile: leakFile)
        defer { server.process.terminate() }
        let store = ProviderRegistryStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("providers-\(UUID().uuidString).json"))
        let id = "redirect-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "SideProviderModelsRefreshed.\(id)") }
        store.addOrUpdate(ProviderDefinition(id: id, displayName: "Local", kind: .local, baseURL: URL(string: "http://127.0.0.1:\(server.port)/start")!,
                                             requiresAPIKey: false, models: [ProviderModel(id: "m", displayName: "m", contextWindowTokens: 8_000)], defaultModelId: "m"))
        let done = expectation(description: "refreshed")
        store.refreshModels(providerId: id, apiKey: "sk-test-secret", force: true) { changed in
            XCTAssertFalse(changed)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leakFile.path), "the redirect target received the refresh — and with it the key")
    }
}

/// 2026-09-30 audit, H1: Format Document on a large file, with a formatter that exits without
/// reading it, raised SIGPIPE and ended Side. Now the format fails and nothing else happens.
final class FormatterPipeTests: XCTestCase {
    func testAFormatterThatExitsWithoutReadingFailsTheFormatOnly() {
        let large = String(repeating: "let value = 1\n", count: 20_000)  // 280 KB, past a pipe's buffer
        let result = MakeWorkspaceViewController.runFormatter((executable: "/bin/sh", args: ["-c", "exit 3"]),
                                                              input: large, directory: FileManager.default.temporaryDirectory)
        XCTAssertNil(result)
    }

    func testAFormatterGetsTheLoginShellsPath() {
        let result = MakeWorkspaceViewController.runFormatter((executable: "/bin/sh", args: ["-c", "cat >/dev/null; echo $PATH"]),
                                                              input: "x", directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), LanguageServerRegistry.environmentForSpawning()["PATH"])
    }
}

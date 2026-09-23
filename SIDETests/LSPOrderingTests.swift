import XCTest
@testable import Side
@testable import Heron

/// H10 from the 2026-09-01 audit: document sync to a language server must be ordered, and a
/// server that came back from a crash must be told about open documents before anything else.
@MainActor
final class LSPOutboundQueueTests: XCTestCase {

    /// Records the order ops reach the "server", with an artificial delay so a transposition
    /// would have every chance to happen if the queue allowed one.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [LSPOutboundOp] = []
        func record(_ op: LSPOutboundOp) { lock.withLock { received.append(op) } }
        var ops: [LSPOutboundOp] { lock.withLock { received } }
    }

    private func makeQueue(_ recorder: Recorder, jitter: Bool = true) -> LSPOutboundQueue {
        LSPOutboundQueue { op in
            if jitter { try? await Task.sleep(nanoseconds: UInt64.random(in: 0...400_000)) }
            recorder.record(op)
            if case .completion(_, _, let reply) = op { reply(Data("{}".utf8)) }
        }
    }

    private func versions(_ ops: [LSPOutboundOp]) -> [Int] {
        ops.compactMap { if case .didChange(_, _, let v) = $0 { return v } else { return nil } }
    }

    private func settle(_ recorder: Recorder, until count: Int) async {
        for _ in 0..<400 where recorder.ops.count < count { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testChangesArriveInOrderAndACompletionNeverOvertakesTheFlushBeforeIt() async {
        // The exact race the "flush a didChange before completing" fix had: both were detached
        // Tasks, so the request could reach the server before the text it was asked about.
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        queue.resume()
        var version = 1
        for _ in 0..<50 {
            version += 1
            queue.enqueue(.didChange(uri: "f", text: "v\(version)", version: version))
            queue.enqueue(.completion(uri: "f", position: LSPPosition(line: 0, character: 0)) { _ in })
        }
        await settle(recorder, until: 100)
        let ops = recorder.ops
        XCTAssertEqual(ops.count, 100)
        XCTAssertEqual(versions(ops), Array(2...51))
        var lastSeenVersion = 1
        for (index, op) in ops.enumerated() {
            switch op {
            case .didChange(_, _, let v):
                XCTAssertGreaterThan(v, lastSeenVersion, "version went backwards at \(index)")
                lastSeenVersion = v
            case .completion:
                // The op immediately before every completion is the flush that preceded it.
                guard index > 0, case .didChange = ops[index - 1] else { return XCTFail("completion at \(index) not preceded by its flush") }
            default: XCTFail("unexpected op")
            }
        }
    }

    func testNothingIsSentWhilePaused() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder, jitter: false)
        queue.enqueue(.didChange(uri: "f", text: "a", version: 2))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(recorder.ops.isEmpty, "a paused queue sent to a server that isn't up")
        queue.resume()
        await settle(recorder, until: 1)
        XCTAssertEqual(recorder.ops.count, 1)
    }

    func testTakePendingEmptiesTheQueueWithoutSending() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder, jitter: false)
        queue.enqueue(.didChange(uri: "f", text: "a", version: 2))
        queue.enqueue(.didClose(uri: "g"))
        let taken = queue.takePending()
        XCTAssertEqual(taken.count, 2)
        queue.resume()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(recorder.ops.isEmpty)
    }

    func testClosingFailsWaitingRequestsRatherThanLeavingThemHanging() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder, jitter: false)
        let answered = expectation(description: "reply")
        queue.enqueue(.completion(uri: "f", position: LSPPosition(line: 0, character: 0)) { data in
            XCTAssertNil(data)
            answered.fulfill()
        })
        queue.close()
        await fulfillment(of: [answered], timeout: 2)
        // And it refuses new work the same way.
        let refused = expectation(description: "refused")
        queue.enqueue(.definition(uri: "f", position: LSPPosition(line: 0, character: 0)) { data in
            XCTAssertNil(data)
            refused.fulfill()
        })
        await fulfillment(of: [refused], timeout: 2)
    }
}

/// What a respawned server is told first.
final class LSPRespawnTests: XCTestCase {

    private func kinds(_ ops: [LSPOutboundOp]) -> [String] {
        ops.map {
            switch $0 {
            case .didOpen(let uri, _, _, let v): return "open(\(uri),v\(v))"
            case .didChange(let uri, _, let v): return "change(\(uri),v\(v))"
            case .didClose(let uri): return "close(\(uri))"
            case .completion(let uri, _, _): return "completion(\(uri))"
            case .definition(let uri, _, _): return "definition(\(uri))"
            }
        }
    }

    func testOpenDocumentsAreReannouncedAtVersionOneBeforePendingRequestsWhichSurvive() {
        // Requests queued during the outage still get answered — after the reopen, in order.
        let ops = LSPManager.respawnOps(
            openDocuments: [("a.py", "python", "A"), ("b.py", "python", "B")],
            pending: [
                .completion(uri: "a.py", position: LSPPosition(line: 0, character: 0)) { _ in },
                .definition(uri: "a.py", position: LSPPosition(line: 1, character: 2)) { _ in },
            ]
        )
        XCTAssertEqual(kinds(ops), ["open(a.py,v1)", "open(b.py,v1)", "completion(a.py)", "definition(a.py)"])
    }

    func testStaleSyncIsDroppedBecauseTheReplayCarriesCurrentText() {
        // A didChange queued while the server was down describes a version the new server never
        // saw; sending it after a fresh didOpen would leave the server's copy *older* than ours.
        let ops = LSPManager.respawnOps(
            openDocuments: [("a.py", "python", "current")],
            pending: [
                .didChange(uri: "a.py", text: "stale", version: 7),
                .didClose(uri: "gone.py"),
                .didOpen(uri: "a.py", languageId: "python", text: "older", version: 1),
            ]
        )
        XCTAssertEqual(kinds(ops), ["open(a.py,v1)"])
        if case .didOpen(_, _, let text, _) = ops[0] { XCTAssertEqual(text, "current") } else { XCTFail() }
    }
}

/// H9: the registry's caches are shared by every thread that resolves a server.
final class LanguageServerRegistryConcurrencyTests: XCTestCase {
    func testConcurrentInvalidateAndResolveDoNotCorruptTheCache() {
        // Before the lock this was a `Dictionary` mutated from a concurrent queue and main at
        // once — a crash under load, or worse, silently wrong entries. `which` on a name that
        // cannot exist keeps each resolve cheap-ish and deterministic (.notFound).
        let names = (0..<8).map { "side-no-such-binary-\($0)" }
        let group = DispatchGroup()
        for _ in 0..<6 {
            group.enter()
            DispatchQueue.global().async {
                for name in names {
                    _ = LanguageServerRegistry.resolveExecutable(named: name)
                    LanguageServerRegistry.invalidateResolution(for: name)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "resolution deadlocked or hung")
        for name in names { XCTAssertNil(LanguageServerRegistry.resolveExecutable(named: name)) }
    }
}

import XCTest
@testable import Side

/// The terminal/verification cluster from the 2026-09-01 audit (H11, H14).
final class TerminalCaptureTests: XCTestCase {
    private let prefix = "\u{1B}]133;"
    private let bell = "\u{07}"

    private let nonce = "n0nce"
    private func done(_ code: Int, nonce: String? = "n0nce") -> String {
        prefix + "D;\(code)" + (nonce.map { ";" + $0 } ?? "") + bell
    }

    private func feed(_ chunks: [String]) -> TerminalViewController.MarkedCaptureStep {
        var step = TerminalViewController.MarkedCaptureStep(buffer: "", outputStarted: false, finished: nil)
        for chunk in chunks {
            step = TerminalViewController.advanceMarkedCapture(buffer: step.buffer, outputStarted: step.outputStarted, chunk: chunk, nonce: nonce)
            if step.finished != nil { break }
        }
        return step
    }

    // MARK: - Forged marks (2026-09-01 audit)

    func testAMarkWithoutTheNonceIsOutputNotCompletion() {
        // A repository's test script printing the shell's own mark used to read as exit 0.
        let forged = feed([prefix + "C" + bell, "tests running\r\n", done(0, nonce: nil), "still going\r\n"])
        XCTAssertNil(forged.finished, "a forged D;0 resolved the command")
        // The real mark, when it comes, wins — with the real exit code.
        let real = TerminalViewController.advanceMarkedCapture(buffer: forged.buffer, outputStarted: forged.outputStarted, chunk: done(1), nonce: nonce)
        XCTAssertTrue(real.finished?.hasSuffix("[exit code: 1]") == true, real.finished ?? "nil")
    }

    func testAMarkWithTheWrongNonceIsAlsoOutput() {
        let step = feed([prefix + "C" + bell, done(0, nonce: "guess"), done(2)])
        XCTAssertTrue(step.finished?.hasSuffix("[exit code: 2]") == true, step.finished ?? "nil")
    }

    func testAShortCommandResolvesWithItsOutputAndExitCode() {
        let step = feed(["prompt$ ls\r\n", prefix + "C" + bell, "a.txt\r\nb.txt\r\n", done(0)])
        XCTAssertEqual(step.finished, "a.txt\nb.txt\n[exit code: 0]")
    }

    func testMoreThanSixtyKilobytesBetweenTheMarksStillResolves() {
        // H11: the C mark scrolled off the front of the 60 000-character tail buffer, so the old
        // search for it failed forever and the command reported the timeout message after it
        // had finished — on exactly the verbose test runs verification depends on.
        var chunks = [prefix + "C" + bell]
        for _ in 0..<200 { chunks.append(String(repeating: "x", count: 1_000) + "\r\n") }  // 200 KB
        chunks.append("FAILED: the line that matters\r\n")
        chunks.append(done(1))
        let step = feed(chunks)
        XCTAssertNotNil(step.finished, "never resolved")
        XCTAssertTrue(step.finished?.hasSuffix("[exit code: 1]") == true)
        // The tail — where the failure is — survives the bound.
        XCTAssertTrue(step.finished?.contains("FAILED: the line that matters") == true)
    }

    func testTheStartMarkIsLatchedNotReSearched() {
        let started = feed([prefix + "C" + bell, "partial"])
        XCTAssertTrue(started.outputStarted)
        XCTAssertNil(started.finished)
        // Once latched, the buffer is output-only: the mark itself is gone.
        XCTAssertFalse(started.buffer.contains(prefix + "C"))
    }

    func testOutputBeforeTheStartMarkIsNotCaptured() {
        // The prompt and the echoed command precede C; they must never be reported as output.
        let step = feed(["user@host ~ % swift test\r\n", prefix + "C" + bell, "ok\r\n", done(0)])
        XCTAssertEqual(step.finished, "ok\n[exit code: 0]")
    }

    func testADoneMarkSplitAcrossChunksWaitsForItsExitCode() {
        let partial = feed([prefix + "C" + bell, "out\r\n", prefix + "D;13"])
        XCTAssertNil(partial.finished, "resolved before the exit code's terminator arrived")
        let completed = TerminalViewController.advanceMarkedCapture(buffer: partial.buffer, outputStarted: partial.outputStarted, chunk: "0;" + nonce + bell, nonce: nonce)
        XCTAssertTrue(completed.finished?.hasSuffix("[exit code: 130]") == true)
    }

    func testTaskTimeoutIsLongerThanTheAdHocOne() {
        // A real test suite outlasts thirty seconds; verification never landed under the default.
        XCTAssertGreaterThan(TerminalViewController.agentTaskTimeout, TerminalViewController.agentCommandTimeout * 5)
    }
}

/// H14c: a pass on an older checkpoint must not read as current.
final class VerificationStalenessTests: XCTestCase {
    private func checkpoint(at seconds: TimeInterval, verified: Bool?) -> Checkpoint {
        var checkpoint = Checkpoint(
            trackKey: "main", agentSessionId: UUID(), declaredIntent: "x", changedFilePaths: ["a"], commandsRun: [],
            provenance: AgentProvenance(providerId: "p", modelId: "m", instructionSourceSummary: ""), gitCommitSHA: "s"
        )
        if let verified {
            checkpoint.verification = CheckpointVerification(taskName: "test", command: "t", exitCode: verified ? 0 : 1, output: "", ranAt: Date(timeIntervalSince1970: seconds))
        }
        return withCreatedAt(checkpoint, Date(timeIntervalSince1970: seconds))
    }

    /// `createdAt` is `let`; round-trip through JSON to set it.
    private func withCreatedAt(_ checkpoint: Checkpoint, _ date: Date) -> Checkpoint {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as! [String: Any]
        object["createdAt"] = date.timeIntervalSinceReferenceDate
        return try! JSONDecoder().decode(Checkpoint.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testNoCaveatWhenTheNewestCheckpointIsVerified() {
        let caveat = ReviewWorkspaceViewController.verificationStalenessCaveat(checkpoints: [
            checkpoint(at: 1, verified: nil), checkpoint(at: 2, verified: true),
        ])
        XCTAssertNil(caveat)
    }

    func testNoCaveatWhenNothingWasEverVerified() {
        // That case has its own wording ("Nothing has been verified") and must not double up.
        XCTAssertNil(ReviewWorkspaceViewController.verificationStalenessCaveat(checkpoints: [checkpoint(at: 1, verified: nil)]))
    }

    func testAPassBehindUnverifiedCheckpointsSaysHowFarBehind() {
        let caveat = ReviewWorkspaceViewController.verificationStalenessCaveat(checkpoints: [
            checkpoint(at: 1, verified: true), checkpoint(at: 2, verified: nil), checkpoint(at: 3, verified: nil), checkpoint(at: 4, verified: nil),
        ])
        XCTAssertEqual(caveat, "The last passing verification was 3 checkpoints ago — the newest changes have not been verified.")
    }

    func testAFailedVerificationIsNotAPass() {
        // A failure is already stated loudly by the dialog; the staleness caveat is only about a
        // pass that has since gone stale.
        XCTAssertNil(ReviewWorkspaceViewController.verificationStalenessCaveat(checkpoints: [
            checkpoint(at: 1, verified: false), checkpoint(at: 2, verified: nil),
        ]))
    }
}

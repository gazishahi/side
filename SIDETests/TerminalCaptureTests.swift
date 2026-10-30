import XCTest
@testable import Side
@testable import Heron

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

    /// Reads split wherever the PTY splits them, mid-character included: the capture keeps raw
    /// bytes and decodes once, so "é" split across two reads comes back as "é" (each read
    /// decoded on its own made it two replacement characters), and a mark split across reads
    /// is still found.
    func testACharacterOrAMarkSplitAcrossReadsComesBackWhole() {
        let raw = Array((prefix + "C" + bell + "café ✓\r\n" + done(0)).utf8)
        for split in 1..<raw.count {
            var bytes: [UInt8] = [], started = false
            var finished = TerminalViewController.advanceMarkedCapture(bytes: &bytes, outputStarted: &started, chunk: raw[..<split], nonce: nonce)
            if finished == nil {
                finished = TerminalViewController.advanceMarkedCapture(bytes: &bytes, outputStarted: &started, chunk: raw[split...], nonce: nonce)
            }
            XCTAssertEqual(finished, "café ✓\n[exit code: 0]", "split at byte \(split)")
        }
    }

    // MARK: - Forged marks (2026-09-01 audit)

    func testAMarkWithoutTheNonceOrWithTheWrongOneIsOutputNotCompletion() {
        // A repository's test script printing the shell's own mark used to read as exit 0.
        let forged = feed([prefix + "C" + bell, "tests running\r\n", done(0, nonce: nil), "still going\r\n"])
        XCTAssertNil(forged.finished, "a forged D;0 resolved the command")
        // The real mark, when it comes, wins — with the real exit code.
        let real = TerminalViewController.advanceMarkedCapture(buffer: forged.buffer, outputStarted: forged.outputStarted, chunk: done(1), nonce: nonce)
        XCTAssertTrue(real.finished?.hasSuffix("[exit code: 1]") == true, real.finished ?? "nil")
        // A guessed nonce is no better than none.
        let guessed = feed([prefix + "C" + bell, done(0, nonce: "guess"), done(2)])
        XCTAssertTrue(guessed.finished?.hasSuffix("[exit code: 2]") == true, guessed.finished ?? "nil")
    }

    func testAShortCommandResolvesWithOnlyItsOutputAndExitCode() {
        // The prompt and the echoed command precede C; they must never be reported as output.
        let step = feed(["user@host ~ % ls\r\n", prefix + "C" + bell, "a.txt\r\nb.txt\r\n", done(0)])
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

    func testADoneMarkSplitAcrossChunksWaitsForItsExitCode() {
        let partial = feed([prefix + "C" + bell, "out\r\n", prefix + "D;13"])
        XCTAssertNil(partial.finished, "resolved before the exit code's terminator arrived")
        let completed = TerminalViewController.advanceMarkedCapture(buffer: partial.buffer, outputStarted: partial.outputStarted, chunk: "0;" + nonce + bell, nonce: nonce)
        XCTAssertTrue(completed.finished?.hasSuffix("[exit code: 130]") == true)
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

    func testTheCaveatAppearsOnlyForAPassThatHasGoneStale() {
        // No caveat when the newest checkpoint is verified; none when nothing was ever verified
        // (that case has its own wording, "Nothing has been verified", and must not double up);
        // none for a failure, which the dialog already states loudly. A pass buried behind
        // unverified checkpoints says how far behind it is.
        let cases: [(name: String, checkpoints: [Checkpoint], caveat: String?)] = [
            ("newest is verified", [checkpoint(at: 1, verified: nil), checkpoint(at: 2, verified: true)], nil),
            ("nothing ever verified", [checkpoint(at: 1, verified: nil)], nil),
            ("pass three checkpoints back",
             [checkpoint(at: 1, verified: true), checkpoint(at: 2, verified: nil), checkpoint(at: 3, verified: nil), checkpoint(at: 4, verified: nil)],
             "The last passing verification was 3 checkpoints ago. The newest changes have not been verified."),
            ("failure is not a pass", [checkpoint(at: 1, verified: false), checkpoint(at: 2, verified: nil)], nil),
        ]
        for c in cases {
            XCTAssertEqual(ReviewWorkspaceViewController.verificationStalenessCaveat(checkpoints: c.checkpoints), c.caveat, c.name)
        }
    }

    /// 2026-10-29, the owner: dragging an image into Claude Code in Run did nothing. A dropped
    /// file types its escaped path; a picture with no file is saved first.
    @MainActor
    func testADroppedFileOrPictureBecomesAnEscapedPath() throws {
        XCTAssertEqual(SideTerminalView.shellEscaped("/Users/me/Screen Shot (1).png"), "/Users/me/Screen\\ Shot\\ \\(1\\).png")
        let files = NSPasteboard(name: .init("side-drop-files-\(UUID().uuidString)"))
        files.clearContents()
        files.writeObjects([URL(fileURLWithPath: "/tmp/a b.png") as NSURL])
        XCTAssertTrue(SideTerminalView.canDrop(files))
        XCTAssertEqual(SideTerminalView.droppedPaths(files), ["/tmp/a b.png"])

        let picture = NSPasteboard(name: .init("side-drop-picture-\(UUID().uuidString)"))
        picture.clearContents()
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in NSColor.blue.setFill(); rect.fill(); return true }
        picture.setData(image.tiffRepresentation, forType: .tiff)
        let saved = try XCTUnwrap(SideTerminalView.droppedPaths(picture).first)
        defer { try? FileManager.default.removeItem(atPath: saved) }
        XCTAssertTrue(saved.hasSuffix(".png"))
        XCTAssertNotNil(NSImage(contentsOfFile: saved), "a picture Claude Code can open")
        files.releaseGlobally(); picture.releaseGlobally()
    }
}

import AlloyTerminal
import XCTest
@testable import Side
@testable import SideAgents

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

    // MARK: - Program titles (2026-10-31, the owner: Claude Code's task on Run's tab)

    func testAProgramTitleLosesItsSpinner() {
        XCTAssertEqual(TerminalViewController.cleanProgramTitle("\u{2733} Fix the login bug"), "Fix the login bug")
        XCTAssertEqual(TerminalViewController.cleanProgramTitle("\u{2802} Fix the login bug"), "Fix the login bug")
        XCTAssertEqual(TerminalViewController.cleanProgramTitle("vim notes.md"), "vim notes.md")
        XCTAssertNil(TerminalViewController.cleanProgramTitle(" \u{2733} "))
    }

    @MainActor
    func testARunningProgramNamesTheTabUntilItFinishes() {
        let vc = TerminalViewController()
        vc.loadViewIfNeeded()
        let session = TerminalSession(label: "project", viewController: vc)
        func receive(_ text: String) { vc.terminalView.receive(ArraySlice(Array(text.utf8))) }
        receive("\u{1B}]0;user@host: ~/project\u{07}")
        XCTAssertEqual(session.title, "project", "a title set at the prompt names nothing")
        receive("\u{1B}]133;C\u{07}" + "\u{1B}]0;\u{2733} Claude Code\u{07}")
        XCTAssertEqual(session.title, "Claude Code")
        receive("\u{1B}]2;\u{2802} Fix the login bug\u{07}")
        XCTAssertEqual(session.title, "Fix the login bug")
        session.customName = "Mine"
        XCTAssertEqual(session.title, "Mine", "your own name wins")
        session.customName = nil
        receive("\u{1B}]133;D;0\u{07}")
        XCTAssertEqual(session.title, "project", "back to the folder once it ends")
    }
}

/// Every keeper test again, on the new engine (docs/SIDE_RFC_TERMINAL_ENGINE.md, tests to port):
/// typing into a kept shell, reading its screen back, reattaching, and a restart's restored
/// screen, as the new engine draws them.
final class SessionKeeperAlloyTests: SessionKeeperTests {
    override func setUpWithError() throws {
        try super.setUpWithError()
        TerminalEngine.overrideForTesting = .alloy
    }

    override func tearDown() {
        TerminalEngine.overrideForTesting = nil
        super.tearDown()
    }
}

/// Light/dark notices (DEC mode 2031): Claude Code picks its theme from the terminal and kept
/// the one it started with when Side changed (the owner, 2026-11-04: light inside a dark window).
final class ColorSchemeReportsTests: XCTestCase {
    func testAProgramTurnsNoticesOnAndOffAndAsksAcrossReads() {
        var reports = ColorSchemeReports()
        XCTAssertFalse(reports.enabled)
        XCTAssertTrue(reports.consume(Array("hello \u{1B}[?20".utf8)).isEmpty)
        _ = reports.consume(Array("31h world".utf8))
        XCTAssertTrue(reports.enabled, "split across two reads")
        XCTAssertEqual(reports.consume(Array("\u{1B}[?996n".utf8)), [.query])
        _ = reports.consume(Array("\u{1B}[?1049;2031l".utf8))
        XCTAssertFalse(reports.enabled, "one of several modes in one sequence")
        _ = reports.consume(Array("\u{1B}[2031h\u{1B}[?2004h".utf8))
        XCTAssertFalse(reports.enabled, "without ? it isn't the private mode, and 2004 isn't 2031")
        XCTAssertTrue(reports.consume(Array("\u{1B}[?996;1n\u{1B}[6n".utf8)).isEmpty, "other reports aren't the question")
        XCTAssertEqual(SideTerminalView.colorSchemeReport(dark: true), "\u{1B}[?997;1n")
        XCTAssertEqual(SideTerminalView.colorSchemeReport(dark: false), "\u{1B}[?997;2n")
    }
}

/// The new engine behind TerminalSurface (docs/SIDE_RFC_TERMINAL_ENGINE.md): libghostty-vt drawn
/// by Alloy, exercised the way Terminal uses SwiftTerm's view.
@MainActor
final class AlloyTerminalSurfaceTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func makeSurface() -> AlloyTerminalSurface {
        let surface = AlloyTerminalSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        surface.applyTheme(TerminalSurfaceTheme(foreground: .white, background: .black,
                                                palette: TerminalViewController.ansiPaletteColors(dark: true), backgroundOpacity: 1))
        return surface
    }

    final class Delegate: TerminalSurfaceDelegate {
        var titles: [String] = [], directories: [String?] = [], exits: [Int32?] = []
        func terminalSurface(_ surface: any TerminalSurface, titleChanged title: String) { titles.append(title) }
        func terminalSurface(_ surface: any TerminalSurface, directoryChanged directory: String?) { directories.append(directory) }
        func terminalSurface(_ surface: any TerminalSurface, processTerminated exitCode: Int32?) { exits.append(exitCode) }
    }

    func testAProgramsOutputTitleDirectoryAndExit() {
        let surface = makeSurface()
        let delegate = Delegate()
        surface.surfaceDelegate = delegate
        var raw = 0
        surface.onRawDataReceived = { raw += $0.count }
        surface.startProcess(executable: "/bin/sh", arguments: ["-c", "printf '\\033]2;my title\\007\\033]7;file://host/tmp/x\\007'; echo hello from sh; exit 4"],
                             environment: TerminalEnvironment.base(), currentDirectory: "/tmp")
        XCTAssertGreaterThan(surface.processID, 0)
        XCTAssertTrue(waitUntil { !delegate.exits.isEmpty })
        XCTAssertTrue(waitUntil { surface.visibleText().contains("hello from sh") }, surface.visibleText())
        // Events reach the main thread a turn after parsing: waited for, not assumed.
        XCTAssertTrue(waitUntil { !delegate.titles.isEmpty && !delegate.directories.isEmpty })
        XCTAssertEqual(delegate.titles, ["my title"])
        XCTAssertEqual(delegate.directories, ["file://host/tmp/x"])
        XCTAssertEqual(delegate.exits.first.flatMap { $0.map { ($0 >> 8) & 0xFF } }, 4, "the raw wait status, as SwiftTerm reported it")
        XCTAssertGreaterThan(raw, 0, "Side's watchers see the output")
    }

    func testTypedKeysReachTheProgramEncoded() {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        var submitted: [String] = []
        surface.onLineSubmitted = { submitted.append($0) }
        // od shows exactly the bytes the program got.
        surface.startProcess(executable: "/bin/sh", arguments: ["-c", "stty raw -echo; echo ready; head -c 8 | od -An -tx1"], environment: TerminalEnvironment.base(), currentDirectory: nil)
        // Typed once the terminal is raw, or the tty would echo the keys instead of passing them.
        XCTAssertTrue(waitUntil { surface.visibleText().contains("ready") })
        func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode)!
            window.makeFirstResponder(surface)
            window.firstResponder?.keyDown(with: event)
        }
        key("a", 0x00)                              // 61
        key("\u{3}", 0x08, .control, ignoring: "c") // 03, control-C
        key("\u{F700}", 0x7E)                       // 1b 5b 41, up arrow
        key("\r", 0x24)                             // 0d
        surface.send(text: "Z\r")                   // 5a 0d
        XCTAssertTrue(waitUntil { surface.visibleText().contains("0d") }, surface.visibleText())
        XCTAssertEqual(surface.visibleText().split(whereSeparator: \.isWhitespace).joined(separator: " "), "ready 61 03 1b 5b 41 0d 5a 0d")
        XCTAssertEqual(submitted, ["a", "Z"], "lines as typed, escape sequences skipped")
    }

    func testThemeSnapshotAndPaste() {
        let surface = makeSurface()
        XCTAssertEqual(surface.backgroundColor.redComponent, 0, accuracy: 0.01)
        surface.display(text: "\u{1B}[?2004hpasted below:\r\n")
        XCTAssertTrue(waitUntil { surface.visibleText().contains("pasted below:") })
        XCTAssertNotNil(surface.snapshotImage(), "a dragged tab's preview")
        XCTAssertGreaterThan(surface.columns, 40)
        XCTAssertGreaterThan(surface.rows, 10)
        XCTAssertTrue(surface.bufferText().contains("pasted below:"))
    }

    func testSelectingWithTheMouseAndScrollingBack() {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        surface.display(text: (1...80).map { "row \($0) of the scrollback" }.joined(separator: "\r\n"))
        XCTAssertTrue(waitUntil { surface.visibleText().contains("row 80 of") })
        let screen = surface.screenForTesting
        let cell = surface.cellSizeForTesting
        // Window coordinates of a cell's middle (top row is 0).
        func point(_ column: Int, _ row: Int, at fraction: CGFloat = 0.5) -> NSPoint {
            screen.convert(NSPoint(x: (CGFloat(column) + fraction) * cell.width, y: screen.bounds.height - (CGFloat(row) + 0.5) * cell.height), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint, clicks: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            switch type {
            case .leftMouseDown: screen.mouseDown(with: event)
            case .leftMouseDragged: screen.mouseDragged(with: event)
            default: screen.mouseUp(with: event)
            }
        }
        // The last row on screen: drag across "row 80".
        let last = surface.rows - 1
        mouse(.leftMouseDown, point(0, last))
        // Past the last cell's middle, which is what takes it in.
        mouse(.leftMouseDragged, point(5, last, at: 0.9))
        mouse(.leftMouseUp, point(5, last, at: 0.9))
        XCTAssertEqual(surface.selectedTextForTesting, "row 80")

        // A double click on "scrollback".
        mouse(.leftMouseDown, point(20, last), clicks: 1); mouse(.leftMouseUp, point(20, last), clicks: 1)
        mouse(.leftMouseDown, point(20, last), clicks: 2); mouse(.leftMouseUp, point(20, last), clicks: 2)
        XCTAssertEqual(surface.selectedTextForTesting, "scrollback")

        XCTAssertFalse(surface.scrollbarForTesting.isScrolledBack)
        surface.scrollForTesting(rows: 10)
        XCTAssertTrue(surface.scrollbarForTesting.isScrolledBack, "the wheel goes back through the scrollback")
        XCTAssertEqual(surface.scrollbarForTesting.offset, 80 - surface.rows - 10)
    }

    /// A program that asks for the mouse gets clicks, encoded as it asked; shift still selects.
    func testAProgramGetsTheMouseItAskedFor() {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        // Normal tracking in SGR, then whatever arrives, as hex.
        surface.startProcess(executable: "/bin/sh", arguments: ["-c", "stty raw -echo; printf '\\033[?1000h\\033[?1006hready\\r\\n'; head -c 18 | od -An -tx1"],
                             environment: TerminalEnvironment.base(), currentDirectory: nil)
        XCTAssertTrue(waitUntil { surface.visibleText().contains("ready") })
        let screen = surface.screenForTesting
        let cell = surface.cellSizeForTesting
        // Column 2, row 3 (0-based): reported as 3;4.
        let at = screen.convert(NSPoint(x: 2.5 * cell.width, y: screen.bounds.height - 3.5 * cell.height), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        screen.mouseDown(with: mouse(.leftMouseDown))
        screen.mouseUp(with: mouse(.leftMouseUp))
        surface.scrollForTesting(rows: 1)
        // ESC [ < 0 ; 3 ; 4 M, ESC [ < 0 ; 3 ; 4 m, then the wheel's ESC [ < 64 … (cut at 18 bytes).
        // od wraps at 16 bytes: compared with the whitespace collapsed.
        func hex() -> String { surface.visibleText().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        XCTAssertTrue(waitUntil { hex().contains("1b 5b 3c 30 3b 33 3b 34 4d 1b 5b 3c 30 3b 33 3b 34 6d") }, hex())
        XCTAssertNil(surface.selectedTextForTesting, "the click went to the program, not the selection")
    }

    /// A full-screen program that asked for the mouse (Claude Code's fullscreen renderer: the
    /// alternate screen, 1000 and 1006) gets the wheel as wheel buttons, from a real scroll event,
    /// a mouse wheel's and a trackpad's; it scrolls its own transcript with them.
    func testAFullScreenProgramGetsTheWheel() throws {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        surface.startProcess(executable: "/bin/sh",
                             arguments: ["-c", "stty raw -echo; printf '\\033[?1049h\\033[?1000h\\033[?1006hready\\r\\n'; head -c 36 | od -An -c"],
                             environment: TerminalEnvironment.base(), currentDirectory: nil)
        XCTAssertTrue(waitUntil { surface.visibleText().contains("ready") })
        // Two of a wheel's notches up, then a trackpad's swipe down (precise deltas, a few rows'
        // worth): at least three wheel reports, about 13 bytes each.
        realScroll(surface, in: window, lines: 2, pixels: false)
        realScroll(surface, in: window, lines: -1, pixels: true)
        func text() -> String { surface.visibleText().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        // od -c shows ESC as 033: "033 [ < 6 4 ;" is a wheel up, "6 5" a wheel down.
        XCTAssertTrue(waitUntil { text().contains("033 [ < 6 4 ;") }, "no wheel up reached the program: \(text())")
        XCTAssertTrue(waitUntil { text().contains("033 [ < 6 5 ;") || text().contains("< 6 5 ;") }, "no wheel down: \(text())")
    }

    /// A shell's scrollback, scrolled by a real scroll event (not the test hook): the event goes
    /// through the view's own handling, as one from a mouse or trackpad does.
    func testARealScrollEventScrollsTheScrollback() {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        surface.display(text: (1...200).map { "line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(waitUntil { surface.visibleText().contains("line 200") })
        realScroll(surface, in: window, lines: 5, pixels: false)
        XCTAssertTrue(waitUntil { surface.scrollbarForTesting.isScrolledBack }, "a wheel's notches scroll back")
        let offset = surface.scrollbarForTesting.offset
        realScroll(surface, in: window, lines: 3, pixels: true)
        XCTAssertTrue(waitUntil { surface.scrollbarForTesting.offset < offset }, "a trackpad's swipe too")
    }

    /// A scroll event as macOS delivers one: a wheel's (in lines) or a trackpad's (in pixels,
    /// with precise deltas), over the middle of the terminal.
    private func realScroll(_ surface: AlloyTerminalSurface, in window: NSWindow, lines: Int32, pixels: Bool) {
        let screen = surface.screenForTesting
        let inside = screen.convert(NSPoint(x: screen.bounds.midX, y: screen.bounds.midY), to: nil)
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line, wheelCount: 1, wheel1: pixels ? lines * 40 : lines, wheel2: 0, wheel3: 0)!
        // CoreGraphics' global coordinates run down from the top of the main display.
        let onScreen = window.convertPoint(toScreen: inside)
        cg.location = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        screen.scrollWheel(with: NSEvent(cgEvent: cg)!)
    }

    /// Focus reports (DEC mode 1004): a program that asked is told when the terminal gains or loses
    /// the keyboard; one that didn't is told nothing. (Before the mode is on, a gain is sent first
    /// here; had it leaked, the program would read it before the lost-then-gained it asked for.)
    func testFocusReportsOnlyOnceAsked() throws {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        let view = try XCTUnwrap(surface.screenForTesting as? AlloyTerminalView)
        surface.startProcess(executable: "/bin/sh",
                             arguments: ["-c", "stty raw -echo; printf 'ready\\r\\n'; read -r _ </dev/null; sleep 1; printf '\\033[?1004hon\\r\\n'; head -c 6 | od -An -c"],
                             environment: TerminalEnvironment.base(), currentDirectory: nil)
        XCTAssertTrue(waitUntil { surface.visibleText().contains("ready") })
        view.setFocusedForTesting(true)
        XCTAssertTrue(waitUntil { surface.visibleText().contains("on") })
        view.setFocusedForTesting(false)
        view.setFocusedForTesting(true)
        func text() -> String { surface.visibleText().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        XCTAssertTrue(waitUntil { text().contains("033 [ O 033 [ I") }, text())
    }

    /// ⌘-click hands a path to Side (which opens it in Editor) and a link's URL too.
    func testCommandClickOpensLinks() {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        var requested: [String] = []
        surface.onFileLinkRequested = { requested.append($0); return true }
        surface.display(text: "error in Sources/App/main.swift:12 \u{1B}]8;;https://example.com/x\u{1B}\\docs\u{1B}]8;;\u{1B}\\")
        XCTAssertTrue(waitUntil { surface.visibleText().contains("docs") })
        let screen = surface.screenForTesting
        let cell = surface.cellSizeForTesting
        func click(_ column: Int, _ flags: NSEvent.ModifierFlags) {
            let at = screen.convert(NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: screen.bounds.height - 0.5 * cell.height), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { screen.mouseDown(with: event) } else { screen.mouseUp(with: event) }
            }
        }
        click(15, [])
        XCTAssertEqual(requested, [], "a plain click isn't a link click")
        click(15, .command)
        click(36, .command)
        XCTAssertEqual(requested, ["Sources/App/main.swift:12", "https://example.com/x"])
    }

    /// With ⌘ held, the link under the pointer is underlined, all of it, across the rows it wraps
    /// onto, and ⌘-click opens all of it; without ⌘, or once the pointer leaves, nothing is.
    func testHoveringALinkWithCommandUnderlinesIt() {
        let surface = makeSurface()
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        let screen = surface.screenForTesting
        let columns = surface.columnsForTesting
        // A URL from column 4 that runs past the row's end onto the next.
        let url = "https://example.com/" + String(repeating: "a", count: columns)
        surface.display(text: "see " + url + " ok")
        XCTAssertTrue(waitUntil { surface.visibleText().contains(" ok") })
        let cell = surface.cellSizeForTesting
        func send(_ type: NSEvent.EventType, column: Int, row: Int, _ flags: NSEvent.ModifierFlags) {
            let at = screen.convert(NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: screen.bounds.height - (CGFloat(row) + 0.5) * cell.height), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 1)!
            switch type {
            case .mouseMoved: screen.mouseMoved(with: event)
            case .leftMouseDown: screen.mouseDown(with: event)
            case .leftMouseUp: screen.mouseUp(with: event)
            default: break
            }
        }
        send(.mouseMoved, column: 6, row: 0, [])
        XCTAssertNil(surface.hoveredLinkForTesting, "no ⌘, no link")
        XCTAssertEqual(surface.underlinedForTesting, [])

        send(.mouseMoved, column: 3, row: 1, .command)
        XCTAssertEqual(surface.hoveredLinkForTesting, url, "found from the row it wrapped onto")
        XCTAssertEqual(surface.underlinedForTesting, [[0, 4, columns - 1], [1, 0, url.count - (columns - 4) - 1]])
        XCTAssertEqual(surface.pointerForTesting, .pointingHand)

        var requested: [String] = []
        surface.onFileLinkRequested = { requested.append($0); return true }
        send(.leftMouseDown, column: 6, row: 0, .command)
        send(.leftMouseUp, column: 6, row: 0, .command)
        XCTAssertEqual(requested, [url], "⌘-click opens all of it")

        send(.mouseMoved, column: 1, row: 0, .command)
        XCTAssertNil(surface.hoveredLinkForTesting, "\"see\" isn't a link")
        XCTAssertEqual(surface.underlinedForTesting, [])
        XCTAssertEqual(surface.pointerForTesting, .iBeam)
    }

    /// Find: matches highlighted where they are, next and previous step through them (scrolling
    /// back into the scrollback), new output is searched as it arrives, and an empty search ends it.
    func testFindHighlightsAndStepsThroughMatches() {
        let surface = makeSurface()
        let rows = surface.screenRowsForTesting
        // One match far back in the scrollback, one on the last line.
        surface.display(text: "first needle\r\n" + String(repeating: "hay\r\n", count: rows + 5) + "last NEEDLE here")
        XCTAssertTrue(waitUntil { surface.visibleText().contains("last NEEDLE") })
        var statuses: [String] = []
        surface.onFindStatus = { statuses.append("\($0.map(String.init) ?? "-") of \($1)") }

        surface.find("needle")
        XCTAssertTrue(waitUntil { surface.findStatus.total == 2 })
        XCTAssertEqual(surface.searchHighlightsForTesting.matches, [[rows - 1, 5, 10]], "the one in view")
        XCTAssertEqual(surface.searchHighlightsForTesting.selected, [])

        surface.findNext()
        XCTAssertTrue(waitUntil { surface.findStatus.selected == 1 })
        XCTAssertEqual(surface.searchHighlightsForTesting.selected, [[rows - 1, 5, 10]], "the newest first")
        surface.findNext()
        XCTAssertTrue(waitUntil { surface.findStatus.selected == 2 })
        XCTAssertEqual(surface.searchHighlightsForTesting.selected.first?[1...2], [6, 11], "\"first needle\", scrolled into view")
        XCTAssertTrue(surface.scrollbarForTesting.isScrolledBack)
        surface.findPrevious()
        XCTAssertTrue(waitUntil { surface.findStatus.selected == 1 })

        surface.display(text: "\r\none more needle")
        XCTAssertTrue(waitUntil { surface.findStatus.total == 3 }, "new output is searched")

        surface.find("")
        XCTAssertTrue(waitUntil { surface.searchHighlightsForTesting.matches.isEmpty && surface.findStatus.total == 0 })
        XCTAssertEqual(statuses.first, "- of 2")
    }

    /// Scrolled back, the viewport stays on what you're reading while output keeps coming.
    func testAScrolledBackViewportStaysPutWhileOutputStreams() {
        let surface = makeSurface()
        surface.display(text: (1...200).map { "line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(waitUntil { surface.visibleText().contains("line 200") })
        surface.scrollForTesting(rows: 50)
        XCTAssertTrue(waitUntil { surface.scrollbarForTesting.isScrolledBack })
        let reading = surface.viewportTextForTesting
        XCTAssertFalse(reading.contains("line 200"))
        for batch in 0..<20 {
            surface.display(text: "\r\n" + (1...25).map { "more \(batch)-\($0)" }.joined(separator: "\r\n"))
        }
        XCTAssertTrue(waitUntil { surface.scrollbarForTesting.total > 600 }, "the output arrived")
        XCTAssertEqual(surface.viewportTextForTesting, reading, "still on what was being read")
        XCTAssertTrue(surface.scrollbarForTesting.isScrolledBack)
    }

    /// Ported from VerificationStalenessTests: a running program names the tab (OSC 0/2 between
    /// the shell's command marks) until it finishes, on the new engine, whose title events come
    /// from its parse thread.
    @MainActor
    func testARunningProgramNamesTheTabUntilItFinishes() {
        TerminalEngine.overrideForTesting = .alloy
        defer { TerminalEngine.overrideForTesting = nil }
        let vc = TerminalViewController()
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.terminalView is AlloyTerminalSurface)
        let session = TerminalSession(label: "project", viewController: vc)
        func receive(_ text: String) { vc.terminalView.receive(ArraySlice(Array(text.utf8))) }
        receive("\u{1B}]0;user@host: ~/project\u{07}")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(session.title, "project", "a title set at the prompt names nothing")
        receive("\u{1B}]133;C\u{07}" + "\u{1B}]0;\u{2733} Claude Code\u{07}")
        XCTAssertTrue(waitUntil { session.title == "Claude Code" }, session.title)
        receive("\u{1B}]2;\u{2802} Fix the login bug\u{07}")
        XCTAssertTrue(waitUntil { session.title == "Fix the login bug" }, session.title)
        session.customName = "Mine"
        XCTAssertEqual(session.title, "Mine", "your own name wins")
        session.customName = nil
        receive("\u{1B}]133;D;0\u{07}")
        XCTAssertTrue(waitUntil { session.title == "project" }, "back to the folder once it ends: \(session.title)")
    }

    /// A surface not laid out yet (a tab not shown) has the usual 80×24 grid, not one column, and
    /// tells a keeper no size until it has a real one: told 1×1, a kept shell was squeezed into
    /// one column (2026-11-13).
    func testASurfaceNotLaidOutKeepsAPlaceholderGrid() {
        let surface = AlloyTerminalSurface(frame: .zero)
        XCTAssertEqual(surface.columns, 80)
        XCTAssertEqual(surface.rows, 24)
        surface.display(text: String(repeating: "x", count: 30))
        XCTAssertTrue(waitUntil { surface.visibleText().contains(String(repeating: "x", count: 30)) }, "on one line, not wrapped at two columns")
    }

    /// Ported from AccessibilityTests: one text area named Terminal that says it takes input,
    /// whose value is the screen without its blank rows below the output.
    func testExposedAsAReadableTextArea() {
        let surface = makeSurface()
        XCTAssertTrue(surface.isAccessibilityElement())
        XCTAssertEqual(surface.accessibilityRole(), .textArea)
        XCTAssertEqual(surface.accessibilityLabel(), "Terminal")
        XCTAssertNotNil(surface.accessibilityHelp(), "a text area that accepts input should say so")
        surface.display(text: "hello from the shell\r\n")
        XCTAssertTrue(waitUntil { (surface.accessibilityValue() as? String ?? "").contains("hello from the shell") })
        let value = surface.accessibilityValue() as? String ?? ""
        XCTAssertEqual(surface.accessibilityNumberOfCharacters(), value.count)
        XCTAssertFalse(value.hasSuffix("\n"), value.debugDescription)
        XCTAssertEqual(value.components(separatedBy: "\n").count, 1, value.debugDescription)
    }

    func testAgentReportsAcrossReads() {
        var watcher = OSCWatcher(code: 6973)
        XCTAssertEqual(watcher.consume(Array("x\u{1B}]6973;agent;cl".utf8)), [])
        XCTAssertEqual(watcher.consume(Array("aude;abc;n0nce\u{07}y\u{1B}]6973;b\u{1B}\\".utf8)), ["agent;claude;abc;n0nce", "b"])
        XCTAssertEqual(watcher.consume(Array("\u{1B}]697;no\u{07}".utf8)), [], "another code")
    }

    func testSubmittedLines() {
        var tracker = SubmittedLineTracker()
        XCTAssertEqual(tracker.consume(Array("ls -la\r".utf8)[...]), ["ls -la"])
        XCTAssertEqual(tracker.consume(Array("gti\u{7F}\u{7F}it st\u{1B}[Aatus\r".utf8)[...]), ["git status"])
    }
}

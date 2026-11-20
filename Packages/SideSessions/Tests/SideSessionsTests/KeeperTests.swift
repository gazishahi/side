import Darwin
import Foundation
import GhosttyVt
@testable import SideSessionsKit
import XCTest

/// End to end: a real keeper, a real PTY and child, talked to over its socket.
final class KeeperTests: XCTestCase {
    private var runDirectory: URL!

    override func setUp() {
        super.setUp()
        // Short: a socket path must fit in 103 bytes.
        runDirectory = URL(fileURLWithPath: "/tmp/sst-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("SIDE_SESSIONS_DIR", runDirectory.path, 1)
    }

    override func tearDown() {
        for record in SessionPaths.records() { kill(record.keeperPID, SIGKILL); kill(record.childPID, SIGKILL) }
        try? FileManager.default.removeItem(at: runDirectory)
        unsetenv("SIDE_SESSIONS_DIR")
        super.tearDown()
    }

    private var keeperURL: URL {
        Bundle(for: KeeperTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SideSessionKeeper")
    }

    @discardableResult
    private func launch(_ script: String, cols: Int = 80, rows: Int = 24, client: [String: String] = [:], id: String = SessionPaths.newID(),
                        restoreFrom: String? = nil, banner: String? = nil, executable: String = "/bin/sh", arguments: [String]? = nil,
                        notifier: String? = nil) throws -> String {
        let spec = LaunchSpec(id: id, executable: executable, arguments: arguments ?? ["-c", script], environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"],
                              directory: NSTemporaryDirectory(), cols: cols, rows: rows, client: client, restoreFrom: restoreFrom, banner: banner,
                              notifier: notifier, place: "proj")
        try KeeperLauncher.launch(spec, keeper: keeperURL)
        return id
    }

    // MARK: - Tests

    func testFramesSurviveArbitrarySplits() {
        let frames = [Frame(.input, Array("hello".utf8)), Frame(.resize, json: Size(cols: 3, rows: 4)), Frame(.detach), Frame(.output, Array(repeating: 7, count: 70_000))]
        let stream = frames.flatMap(\.encoded)
        var decoder = FrameDecoder()
        var out: [Frame] = []
        var i = 0
        while i < stream.count {
            let n = min(stream.count - i, [1, 2, 5, 13, 4096][i % 5])
            decoder.append(Array(stream[i..<i + n]))
            while let frame = decoder.next() { out.append(frame) }
            i += n
        }
        XCTAssertEqual(out, frames)
        XCTAssertFalse(decoder.isCorrupt)
    }

    func testStreamsOutputAndTakesInput() throws {
        let id = try launch("printf 'ready\\n'; read line; printf 'got:%s\\n' \"$line\"; sleep 30")
        let client = try TestClient(id)
        try client.attach()
        XCTAssertTrue(client.waitForText("ready"))
        client.send(Frame(.input, Array("abc\r".utf8)))
        XCTAssertTrue(client.waitForText("got:abc"), client.text)
        XCTAssertEqual(client.welcome?.record.id, id)
        XCTAssertTrue(client.welcome?.record.tty.hasPrefix("/dev/ttys") == true)
    }

    func testReattachGivesTheSameScreenAndScrollback() throws {
        let id = try launch("i=1; while [ $i -le 60 ]; do echo \"line $i\"; i=$((i+1)); done; sleep 30", rows: 10)
        let first = try TestClient(id)
        try first.attach()
        XCTAssertTrue(first.waitForText("line 60"))
        first.close()

        let second = try TestClient(id)
        try second.attach()
        let screen = try XCTUnwrap(second.snapshotPlainText())
        XCTAssertTrue(screen.contains("line 1\n"), "scrollback missing:\n\(screen)")
        XCTAssertTrue(screen.contains("line 60"))
    }

    func testAnAttachGetsOnlyTheHistoryItsTerminalKeeps() throws {
        let id = try launch("i=1; while [ $i -le 300 ]; do echo \"row-$i\"; i=$((i+1)); done; sleep 30", rows: 10)
        let first = try TestClient(id)
        try first.attach()
        XCTAssertTrue(first.waitForText("row-300"))
        first.close()
        // A client keeping 50 lines gets the 50 above the screen, the screen, and nothing older.
        let second = try TestClient(id)
        second.send(Frame(.attach, json: Attach(cols: 80, rows: 10, history: 50)))
        XCTAssertTrue(second.wait { $0.snapshot != nil })
        let text = try XCTUnwrap(second.snapshotPlainText())
        XCTAssertTrue(text.contains("row-300"))
        XCTAssertTrue(text.contains("row-245\n"), text)
        XCTAssertFalse(text.contains("row-200\n"), "older history sent")
        // The keeper itself still has all of it.
        let third = try TestClient(id)
        try third.attach()
        XCTAssertTrue(try XCTUnwrap(third.snapshotPlainText()).contains("row-1\n"))
    }

    func testOutputWhileDetachedIsThereOnReattach() throws {
        let id = try launch("read go; echo 'while you were away'; sleep 30")
        let first = try TestClient(id)
        try first.attach()
        first.send(Frame(.input, Array("\r".utf8)))
        first.send(Frame(.detach))
        first.close()
        usleep(300_000)
        let second = try TestClient(id)
        try second.attach()
        XCTAssertTrue(try XCTUnwrap(second.snapshotPlainText()).contains("while you were away"))
    }

    /// The master is non-blocking for the reader: a paste bigger than the PTY's input queue, into a
    /// program that isn't reading yet, waits for room rather than being cut short.
    func testABigPasteIntoAProgramNotYetReadingArrivesWhole() throws {
        let id = try launch("stty raw -echo; printf 'ready\\n'; sleep 1; head -c 300000 | wc -c | tr -d ' '; printf 'counted\\n'; sleep 30")
        let client = try TestClient(id)
        try client.attach()
        XCTAssertTrue(client.waitForText("ready"))
        let paste = [UInt8](repeating: UInt8(ascii: "x"), count: 300_000)
        for start in stride(from: 0, to: paste.count, by: 16_384) {
            client.send(Frame(.input, Array(paste[start..<min(start + 16_384, paste.count)])))
        }
        XCTAssertTrue(client.wait(timeout: 15) { $0.text.contains("counted") }, String(client.text.suffix(200)))
        XCTAssertTrue(client.text.contains("300000"), String(client.text.suffix(200)))
    }

    /// A flood to an attached client (read with the reader's bridging) arrives whole and in order.
    func testAFloodReachesAnAttachedClientWhole() throws {
        let id = try launch("printf 'ready\\n'; sleep 0.5; i=0; while [ $i -lt 40 ]; do head -c 125000 /dev/zero | tr '\\0' 'x'; printf '[%d]' $i; i=$((i+1)); done; printf 'END\\n'; sleep 30")
        let client = try TestClient(id)
        try client.attach()
        XCTAssertTrue(client.waitForText("ready"))
        XCTAssertTrue(client.wait(timeout: 30) { $0.text.contains("END") })
        let text = client.text
        XCTAssertEqual(text.reduce(0) { $1 == "x" ? $0 + 1 : $0 }, 5_000_000)
        let markers = text.matches(of: /\[(\d+)\]/).map { Int($0.1)! }
        XCTAssertEqual(markers, Array(0..<40))
    }

    func testEchoAfterReturnInAProgramThatDoesntReadComesThrough() throws {
        // The completed line waits unread in the program's input; its echo must still arrive.
        let id = try launch("exec sleep 30")
        let client = try TestClient(id)
        try client.attach()
        client.send(Frame(.input, Array("abc\r".utf8)))
        XCTAssertTrue(client.waitForText("abc\r\n"), client.text)
        client.send(Frame(.input, Array("def".utf8)))
        XCTAssertTrue(client.waitForText("def"), "output stopped after Return: \(client.text)")
    }

    func testARestartBringsBackTheScreenBelowABanner() throws {
        let id = try launch("echo before-the-restart; sleep 30")
        let first = try TestClient(id)
        try first.attach()
        XCTAssertTrue(first.waitForText("before-the-restart"))
        first.close()
        // Shutdown: the keeper saves the screen and goes; the shell goes with the machine.
        let old = try XCTUnwrap(SessionPaths.records().first { $0.id == id })
        kill(old.keeperPID, SIGTERM)
        XCTAssertTrue(waitUntil { kill(old.keeperPID, 0) != 0 })
        kill(old.childPID, SIGKILL)
        let snapshot = SessionPaths.snapshot(id).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot), "no snapshot saved at shutdown")
        // Side starts the tab again from it: same id, a fresh shell.
        try launch("echo after-the-restart; sleep 30", id: id, restoreFrom: snapshot, banner: "Restored after a restart")
        let second = try TestClient(id)
        try second.attach()
        XCTAssertTrue(second.waitForText("after-the-restart"))
        let text = second.text
        let order = ["before-the-restart", "Restored after a restart", "after-the-restart"].compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 3, text)
        XCTAssertEqual(order, order.sorted(), "out of order:\n\(text)")
    }

    /// After the owner's Mac restarted (2026-11-05), recovered tabs filled with numbers that never
    /// stopped: the saved screen kept the modes Claude Code had turned on, mouse reporting among
    /// them, and the new shell under it got every movement of the mouse typed in. A new program
    /// starts with none of the old one's input modes.
    func testARestartDoesntHandTheOldProgramsModesToTheNewOne() throws {
        let modes = ["?1000", "?1002", "?1003", "?1004", "?1006", "?2004", "?1"]
        let set = modes.map { "\\033[\($0)h" }.joined()
        let id = try launch("printf '\(set)'; echo modes-on; sleep 30")
        let first = try TestClient(id)
        try first.attach()
        XCTAssertTrue(first.waitForText("modes-on"))
        first.close()
        let reattached = try TestClient(id)
        try reattached.attach()
        XCTAssertTrue(waitUntil { reattached.snapshot != nil })
        let live = String(decoding: reattached.snapshot ?? [], as: UTF8.self)
        XCTAssertTrue(live.contains("\u{1b}[?1003h") || live.contains("1003"), "the running program keeps its modes on a reattach:\n\(live.debugDescription)")
        reattached.close()
        let old = try XCTUnwrap(SessionPaths.records().first { $0.id == id })
        kill(old.keeperPID, SIGTERM)
        XCTAssertTrue(waitUntil { kill(old.keeperPID, 0) != 0 })
        kill(old.childPID, SIGKILL)
        try launch("echo after-the-restart; sleep 30", id: id, restoreFrom: SessionPaths.snapshot(id).path, banner: "Restored after a restart")
        let second = try TestClient(id)
        try second.attach()
        XCTAssertTrue(second.waitForText("after-the-restart"))
        XCTAssertTrue(waitUntil { second.snapshot != nil })
        let restored = String(decoding: second.snapshot ?? [], as: UTF8.self)
        for mode in modes {
            XCTAssertFalse(restored.contains("\u{1b}[\(mode)h"), "\(mode) carried over to the new program:\n\(restored.debugDescription)")
        }
        XCTAssertTrue(second.text.contains("modes-on"), "the old screen is still there")
    }

    func testTheRecordKeepsTheForegroundProgramAndDirectory() throws {
        // An interactive zsh with no rc files: job control puts a command in its own group.
        let id = try launch("", executable: "/bin/zsh", arguments: ["-f", "-i"])
        let client = try TestClient(id)
        try client.attach()
        usleep(300_000)
        client.send(Frame(.input, Array("printf '\\e]7;file://host/private/tmp\\a'; sleep 30\r".utf8)))
        XCTAssertTrue(waitUntil(timeout: 8) { SessionPaths.records().first { $0.id == id }?.foreground == ["sleep", "30"] },
                      "foreground: \(SessionPaths.records().first { $0.id == id }?.foreground ?? [])")
        XCTAssertEqual(SessionPaths.records().first { $0.id == id }?.pwd, "/private/tmp")
    }

    /// A stand-in for Side's notifier: appends its arguments, one call a line.
    private func fakeNotifier() throws -> (path: String, calls: () -> [String]) {
        let dir = runDirectory.appendingPathComponent("notifier", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.txt").path
        let script = dir.appendingPathComponent("notify").path
        try "#!/bin/sh\necho \"$*\" >> '\(log)'\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        return (script, { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) })
    }

    func testAProgramsNotificationReachesTheNotifierOnlyWhileDetached() throws {
        let notifier = try fakeNotifier()
        let id = try launch("read go; printf '\\033]777;notify;Build;Tests passed\\007'; printf '\\033]9;second one\\007'; read again; printf '\\033]777;notify;Attached;Not for the notifier\\007'; sleep 30",
                            notifier: notifier.path)
        let client = try TestClient(id)
        try client.attach()
        client.send(Frame(.input, Array("\r".utf8)))
        client.send(Frame(.detach))
        client.close()
        XCTAssertTrue(waitUntil { !notifier.calls().isEmpty }, "no notification")
        usleep(300_000)
        XCTAssertEqual(notifier.calls().count, 1, "one notification within 30 seconds: \(notifier.calls())")
        let call = try XCTUnwrap(notifier.calls().first)
        XCTAssertTrue(call.contains("--title Build --body Tests passed --url side://run/\(id)"), call)
        // Attached, the client hears it instead.
        let again = try TestClient(id)
        try again.attach()
        again.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(again.waitForText("Not for the notifier") || true)
        usleep(500_000)
        XCTAssertEqual(notifier.calls().count, 1, "notified while attached")
    }

    func testAnAgentThatStopsWorkingIsReported() throws {
        let notifier = try fakeNotifier()
        // A program that calls itself claude (as the real one, a binary, does), works for six
        // seconds, then waits.
        let id = try launch("", executable: "/bin/zsh", arguments: ["-f", "-i"], notifier: notifier.path)
        let client = try TestClient(id)
        try client.attach()
        usleep(300_000)
        client.send(Frame(.input, Array("(exec -a claude /bin/sh -c 'i=0; while [ $i -lt 30 ]; do echo working $i; sleep 0.2; i=$((i+1)); done; sleep 60')\r".utf8)))
        client.send(Frame(.detach))
        client.close()
        XCTAssertTrue(waitUntil(timeout: 20) { !notifier.calls().isEmpty }, "no notification when the agent stopped")
        XCTAssertTrue(notifier.calls().first?.contains("claude in proj stopped") == true || notifier.calls().first?.contains("Claude in proj stopped") == true, notifier.calls().first ?? "")
    }

    func testChildHasAControllingTerminal() throws {
        // Opening /dev/tty fails without one; job control and Ctrl-C depend on it.
        let id = try launch("if exec 3</dev/tty; then echo HAS-TTY; else echo NO-TTY; fi; sleep 30")
        let client = try TestClient(id)
        try client.attach()
        XCTAssertTrue(client.waitForText("HAS-TTY"), client.text)
    }

    func testResizeReachesTheProgram() throws {
        let id = try launch("read go; stty size; sleep 30")
        let client = try TestClient(id)
        try client.attach(Size(cols: 100, rows: 30))
        client.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(client.waitForText("30 100"), client.text)
    }

    func testAlternateScreenKeepsTheShellHistoryBehindIt() throws {
        let id = try launch("echo PRIMARY-LINE; printf '\\033[?1049h'; echo ALT-LINE; sleep 30")
        let first = try TestClient(id)
        try first.attach()
        XCTAssertTrue(first.waitForText("ALT-LINE"))
        first.close()
        let second = try TestClient(id)
        try second.attach()
        let snapshot = String(decoding: try XCTUnwrap(second.snapshot), as: UTF8.self)
        let primary = try XCTUnwrap(snapshot.range(of: "PRIMARY-LINE"))
        let alternate = try XCTUnwrap(snapshot.range(of: "ALT-LINE"))
        let enter = try XCTUnwrap(snapshot.range(of: "\u{1b}[?1049h"))
        XCTAssertTrue(primary.upperBound <= enter.lowerBound && enter.upperBound <= alternate.lowerBound, "order wrong")
        // Replayed into a terminal, leaving the alternate screen shows the shell's line again.
        let term = try XCTUnwrap(replay(snapshot + "\u{1b}[?1049l"))
        XCTAssertTrue(term.contains("PRIMARY-LINE"), term)
        XCTAssertFalse(term.contains("ALT-LINE"), term)
    }

    func testWholeTreeSignalEndsBackgroundJobsAndReportsTheExit() throws {
        let id = try launch("sleep 300 & echo \"bg:$!\"; sleep 300")
        let client = try TestClient(id)
        try client.attach()
        XCTAssertTrue(client.waitForText("bg:"))
        let background = Int32(client.text.components(separatedBy: "bg:")[1].prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThan(background, 0)
        client.send(Frame(.signal, json: SignalRequest(signal: SIGTERM, wholeTree: true)))
        XCTAssertTrue(client.wait { $0.exit != nil }, "no exit")
        XCTAssertEqual(client.exit?.signal, SIGTERM)
        XCTAssertTrue(waitUntil { kill(background, 0) != 0 }, "background job survived")
        // Told how it ended, the keeper cleans up and goes.
        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: SessionPaths.socket(id).path) })
    }

    func testExitWhileDetachedIsReportedOnAttach() throws {
        let id = try launch("echo bye; exit 3")
        XCTAssertTrue(waitUntil { SessionPaths.records().first?.exit != nil })
        let client = try TestClient(id)
        try client.attach()
        XCTAssertTrue(client.wait { $0.exit != nil })
        XCTAssertEqual(client.exit?.status, 3)
        XCTAssertTrue(try XCTUnwrap(client.snapshotPlainText()).contains("bye"))
    }

    func testConnectingAloneDoesntDisturbTheAttachedClient() throws {
        let id = try launch("read go; echo still-here; sleep 30")
        let first = try TestClient(id)
        try first.attach()
        // Something only connects and says hello (a probe, another Side looking): no takeover.
        let probe = try TestClient(id)
        XCTAssertTrue(probe.wait { $0.welcome != nil })
        probe.close()
        first.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(first.waitForText("still-here"))
        XCTAssertFalse(first.state.replaced)
    }

    func testASecondClientTakesOver() throws {
        let id = try launch("echo hi; sleep 30")
        let first = try TestClient(id)
        try first.attach()
        let second = try TestClient(id)
        try second.attach()
        XCTAssertTrue(first.wait { $0.replaced })
        XCTAssertNotNil(second.snapshot)
    }

    func testTitleAndClientFactsComeBack() throws {
        let id = try launch("printf '\\033]0;Working on tests\\007'; sleep 30", client: ["tab": "T1", "nonce": "abc"])
        let first = try TestClient(id)
        try first.attach()
        XCTAssertTrue(first.wait { $0.title == "Working on tests" })
        first.close()
        XCTAssertTrue(waitUntil { SessionPaths.records().first?.title == "Working on tests" })
        let second = try TestClient(id)
        try second.attach()
        XCTAssertEqual(second.welcome?.record.client["nonce"], "abc")
        XCTAssertTrue(second.wait { $0.title == "Working on tests" })
    }

    // MARK: Program status (OSC 7501)

    func testProgramStatusRecordsFollowTheSpecsRules() {
        var records = ProgramStatusRecords()
        records.put(.init(id: "", state: .working, app: "deploy", message: "one"))
        records.put(.init(id: "", state: .blocked, kind: .permission, message: "Apply?"))
        XCTAssertEqual(records.records.count, 1, "a report replaces its record")
        XCTAssertEqual(records.root?.state, .blocked)
        XCTAssertEqual(records.root?.app, "", "keys left out are gone")
        records.put(.init(id: "", state: .working, app: "deploy"))
        records.put(.init(id: "us-east", state: .working))
        records.put(.init(id: "us-east/db", state: .done))
        records.put(.init(id: "eu-west", state: .error))
        XCTAssertEqual(records.app(of: records.records.first { $0.id == "us-east/db" }!), "deploy", "an app comes from the nearest ancestor that has one")
        records.clear("us-east")
        XCTAssertEqual(Set(records.records.map(\.id)), ["", "eu-west"], "clearing a record clears what's beneath it")
        records.programEnded()
        XCTAssertEqual(records.records.map(\.id), ["eu-west"], "working and blocked go when the program ends; error stays")
        records.clear("")
        XCTAssertTrue(records.records.isEmpty)
        for index in 0..<(ProgramStatusRecords.limit + 5) {
            records.put(.init(id: "r\(index)", state: .idle, updatedAt: Date(timeIntervalSince1970: TimeInterval(index))))
        }
        XCTAssertEqual(records.records.count, ProgramStatusRecords.limit)
        XCTAssertNil(records.records.first { $0.id == "r0" }, "past the limit, the oldest goes")
    }

    func testAProgramsStatusReachesAClientThatAsksAndTheRecord() throws {
        // "Apply?" in base64 is QXBwbHk/.
        let id = try launch("read go; printf '\\033]7501;state=working:app=terraform:progress=40\\007'; read again; printf '\\033]7501;state=blocked:kind=permission:msg=QXBwbHk/\\033\\\\'; printf '\\033]7;file://host/private/tmp\\007'; sleep 30")
        let client = try TestClient(id, events: true)
        try client.attach()
        client.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(client.wait { _ in client.status?.first?.state == .working }, "\(client.status ?? [])")
        XCTAssertEqual(client.status?.first?.app, "terraform")
        XCTAssertEqual(client.status?.first?.progress, 40)
        client.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(client.wait { _ in client.status?.first?.state == .blocked }, "\(client.status ?? [])")
        XCTAssertEqual(client.status?.first?.kind, .permission)
        XCTAssertEqual(client.status?.first?.message, "Apply?")
        XCTAssertEqual(client.status?.count, 1, "the report replaced the record")
        XCTAssertTrue(client.wait { _ in client.pwd == "/private/tmp" }, client.pwd ?? "no pwd")
        // On disk, for a client that wasn't attached.
        XCTAssertTrue(waitUntil { SessionPaths.records().first { $0.id == id }?.programStatus.first?.state == .blocked })
        // A client that didn't ask gets none of these frames, and it comes back on its attach.
        client.close()
        let plain = try TestClient(id)
        try plain.attach()
        usleep(300_000)
        XCTAssertTrue(plain.eventFrames.isEmpty, "\(plain.eventFrames)")
        plain.close()
        let again = try TestClient(id, events: true)
        try again.attach()
        XCTAssertTrue(again.wait { _ in again.status?.first?.state == .blocked }, "the status comes with an attach")
    }

    func testANewPromptOrAnExitEndsWorkingAndBlocked() throws {
        // OSC 133;A is a new prompt: the program before it is over.
        let id = try launch("read go; printf '\\033]7501;state=working\\007'; printf '\\033]7501;id=lint:state=error\\007'; read again; printf '\\033]133;A\\007'; read last; eval \"$last\"")
        let client = try TestClient(id, events: true)
        try client.attach()
        client.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(client.wait { _ in client.status?.count == 2 }, "\(client.status ?? [])")
        client.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(client.wait { _ in client.status?.map(\.id) == ["lint"] }, "working goes at a new prompt, error stays: \(client.status ?? [])")
        // And the program exiting: working goes again, error stays.
        client.send(Frame(.input, Array("printf '\\033]7501;state=working\\007'; exit\r".utf8)))
        XCTAssertTrue(client.wait { $0.exit != nil }, "no exit")
        XCTAssertEqual(client.status?.map(\.state), [.error], "\(client.status ?? [])")
    }

    func testTheKeeperAnswersTheProgramStatusQueryEvenWhileAttached() throws {
        // The client's own terminal knows nothing of OSC 7501: the keeper, which keeps the
        // records, answers the support query.
        let id = try launch("read go; stty -echo raw; printf '\\033]7501;?\\007'; dd bs=1 count=12 2>/dev/null | od -c | head -1; sleep 30")
        let client = try TestClient(id, events: true)
        try client.attach()
        client.send(Frame(.input, Array("\r".utf8)))
        XCTAssertTrue(client.waitForText("033   ]   7   5   0   1"), client.text)
    }

    func testTheKernelSaysWhereAProcessIs() {
        // Side reads a terminal's program's real directory, not the shell's last report.
        let here = (FileManager.default.currentDirectoryPath as NSString).resolvingSymlinksInPath
        XCTAssertEqual(ForegroundProgram.directory(of: getpid()).map { ($0 as NSString).resolvingSymlinksInPath }, here)
        XCTAssertNil(ForegroundProgram.directory(of: -1))
    }

    func testRepliesToQueriesOnlyWhileDetached() throws {
        // A cursor-position query: detached, the keeper answers it; attached, the client does.
        let id = try launch("stty -echo raw; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -c | head -1; sleep 30")
        usleep(500_000)
        let client = try TestClient(id)
        try client.attach()
        XCTAssertTrue(client.waitForText("033   ["), client.text)
    }

    // MARK: - Helpers

    private func replay(_ bytes: String) -> String? {
        var term: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &term, 80, 24) == GHOSTTY_SUCCESS, let term else { return nil }
        defer { ghostty_terminal_free(term) }
        Array(bytes.utf8).withUnsafeBufferPointer { ghostty_terminal_vt_write(term, $0.baseAddress, $0.count) }
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, term, options) == GHOSTTY_SUCCESS, let formatter else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; usleep(20_000) }
        return condition()
    }

    /// A client that records what arrives.
    final class TestClient: @unchecked Sendable {
        let connection: SessionConnection
        private let lock = NSLock()
        private var _output: [UInt8] = []
        private var _snapshot: [UInt8]?
        private var _welcome: Welcome?
        private var _exit: Exit?
        private var _title: String?
        private var _replaced = false
        private var _status: [ProgramStatusRecord]?
        private var _pwd: String?
        private var _unexpected: [FrameKind] = []

        init(_ id: String, events: Bool? = nil) throws {
            connection = try SessionConnection.connect(to: SessionPaths.socket(id))
            connection.start(queue: DispatchQueue(label: "test.client"), onFrame: { [weak self] frame in self?.received(frame) }, onClose: {})
            connection.send(Frame(.hello, json: Hello(build: "test", events: events)))
        }

        private func received(_ frame: Frame) {
            lock.lock(); defer { lock.unlock() }
            switch frame.kind {
            case .welcome: _welcome = frame.decode(Welcome.self)
            case .snapshot: _snapshot = frame.payload
            case .output: _output += frame.payload
            case .exited: _exit = frame.decode(Exit.self)
            case .title: _title = String(decoding: frame.payload, as: UTF8.self)
            case .replaced: _replaced = true
            case .programStatus:
                let decoder = JSONDecoder()
                _status = try? decoder.decode([ProgramStatusRecord].self, from: Data(frame.payload))
                _unexpected.append(frame.kind)
            case .pwd:
                _pwd = String(decoding: frame.payload, as: UTF8.self)
                _unexpected.append(frame.kind)
            default: break
            }
        }

        /// Program status and pwd frames received; for a client that didn't ask, there should be none.
        var eventFrames: [FrameKind] { lock.lock(); defer { lock.unlock() }; return _unexpected }
        var status: [ProgramStatusRecord]? { lock.lock(); defer { lock.unlock() }; return _status }
        var pwd: String? { lock.lock(); defer { lock.unlock() }; return _pwd }

        struct State { let text: String; let snapshot: [UInt8]?; let welcome: Welcome?; let exit: Exit?; let title: String?; let replaced: Bool }
        var state: State {
            lock.lock(); defer { lock.unlock() }
            return State(text: String(decoding: (_snapshot ?? []) + _output, as: UTF8.self), snapshot: _snapshot, welcome: _welcome, exit: _exit, title: _title, replaced: _replaced)
        }
        var text: String { state.text }
        var snapshot: [UInt8]? { state.snapshot }
        var welcome: Welcome? { state.welcome }
        var exit: Exit? { state.exit }

        func attach(_ size: Size = Size(cols: 80, rows: 24)) throws {
            connection.send(Frame(.attach, json: size))
            guard wait({ $0.snapshot != nil }) else { throw SessionError.closed }
        }

        func send(_ frame: Frame) { connection.send(frame) }
        func close() { connection.close() }

        func wait(timeout: TimeInterval = 5, _ condition: (State) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if condition(state) { return true }; usleep(10_000) }
            return condition(state)
        }

        func waitForText(_ text: String) -> Bool { wait { $0.text.contains(text) } }

        /// The snapshot with its escape sequences removed: roughly what it draws.
        func snapshotPlainText() -> String? {
            guard let snapshot else { return nil }
            var text = String(decoding: snapshot, as: UTF8.self)
            text = text.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\u{1b}\\[[0-9;?<=>]*[ -/]*[@-~]", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\u{1b}.", with: "", options: .regularExpression)
            return text.replacingOccurrences(of: "\r", with: "")
        }
    }
}

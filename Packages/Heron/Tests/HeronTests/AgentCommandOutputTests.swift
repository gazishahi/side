import XCTest
@testable import Heron

/// An outside agent's command output as it arrives (SIDE_RFC_LIVE_COMMAND_OUTPUT.md).
@MainActor
final class AgentCommandOutputTests: XCTestCase {
    func testColourEscapesGoAndProgressLinesSettle() {
        var command = AgentCommandPresentation(command: "npm test")
        command.appendOutput("\u{1B}[32m✓\u{1B}[0m auth\r\n")
        command.appendOutput("Downloading 10%\rDownloading 50%\r")
        command.appendOutput("Downloading 100%\nDone\n")
        XCTAssertEqual(command.output, "✓ auth\nDownloading 100%\nDone\n")
    }

    func testOutputIsBoundedFromTheFrontAtALine() {
        var command = AgentCommandPresentation(command: "yes")
        let line = String(repeating: "y", count: 99) + "\n"
        for _ in 0..<3000 { command.appendOutput(line) }
        XCTAssertLessThanOrEqual(command.output.utf8.count, AgentCommandPresentation.outputLimit)
        XCTAssertTrue(command.isTruncated)
        XCTAssertTrue(command.output.hasPrefix(String(repeating: "y", count: 99) + "\n"), "starts at a whole line")
    }

    func testDeltasThenAnExitFinishTheCommand() {
        var command = AgentCommandPresentation(command: "")
        ACPHarness.apply(["_meta": ["terminal_output_delta": ["terminal_id": "t", "data": "1\n"]]], to: &command)
        ACPHarness.apply(["_meta": ["terminal_output_delta": ["terminal_id": "t", "data": "2\n"]]], to: &command)
        XCTAssertEqual(command.state, .running)
        ACPHarness.apply(["status": "completed", "_meta": ["terminal_exit": ["terminal_id": "t", "exit_code": 0, "signal": NSNull()]]], to: &command)
        XCTAssertEqual(command.output, "1\n2\n")
        XCTAssertEqual(command.state, .finished(exitCode: 0))
    }

    func testANonzeroExitFails() {
        var command = AgentCommandPresentation(command: "")
        ACPHarness.apply(["status": "completed", "_meta": ["terminal_output": ["terminal_id": "t", "data": "boom\n"], "terminal_exit": ["terminal_id": "t", "exit_code": 2, "signal": NSNull()]]], to: &command)
        XCTAssertEqual(command.state, .failed(exitCode: 2))
        XCTAssertEqual(command.output, "boom\n")
    }

    func testAnAgentThatStreamsNothingStillShowsItsResult() {
        var command = AgentCommandPresentation(command: "ls")
        ACPHarness.apply(["status": "completed", "content": [["type": "content", "content": ["type": "text", "text": "a.txt\nb.txt"]]]], to: &command)
        XCTAssertEqual(command.output, "a.txt\nb.txt")
        XCTAssertEqual(command.state, .finished(exitCode: nil))
    }

    func testTheCommandLineDropsAShellWrapper() {
        XCTAssertEqual(ACPHarness.commandLine(["command": "npm test"]), "npm test")
        XCTAssertEqual(ACPHarness.commandLine(["command": ["bash", "-lc", "make -j8"]]), "make -j8")
        XCTAssertEqual(ACPHarness.commandLine(["command": ["git", "status"]]), "git status")
        XCTAssertNil(ACPHarness.commandLine(["description": "x"]))
    }

    func testAFinishedCommandIsKeptInTheRecord() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("command-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let running = RunTranscriptEntry(kind: .agentCommand(AgentCommandPresentation(command: "sleep 9")))
        XCTAssertNil(OutsideSessionLog.record(for: running), "written once it ends")
        let done = RunTranscriptEntry(kind: .agentCommand(AgentCommandPresentation(command: "make", output: "error: x\n", state: .failed(exitCode: 2))))
        OutsideSessionLog.append([try XCTUnwrap(OutsideSessionLog.record(for: done))], to: url)
        guard case .agentCommand(let read)? = OutsideSessionLog.read(url).entries.first?.kind else { return XCTFail("no command") }
        XCTAssertEqual(read.command, "make")
        XCTAssertEqual(read.output, "error: x\n")
        XCTAssertEqual(read.state, .failed(exitCode: 2))
    }
}

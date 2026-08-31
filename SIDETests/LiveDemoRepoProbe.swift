import XCTest
@testable import Side

/// Live check against the real demo repo: what does the agent actually get offered?
final class LiveDemoRepoProbe: XCTestCase {
    func testWhatTheAgentSeesInSideDemoRepo() throws {
        let root = URL(fileURLWithPath: "/Users/gazishahi/Documents/side-demo-repo")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path))
        let tasks = ProjectTasks.tasks(projectRoot: root)
        print("=== list_tasks output the model would receive ===")
        for task in tasks {
            print("  \(task.name): \(task.command)  [verifies: \(task.isVerification)]")
        }
        let verification = ProjectTasks.verificationTask(projectRoot: root)
        print("=== verificationTask: \(verification?.name ?? "NONE") -> \(verification?.command ?? "-")")
        XCTAssertFalse(tasks.isEmpty, "the demo repo would offer the agent no tasks at all")
        XCTAssertNotNil(verification, "nothing answers 'did this work?' for the demo repo")
    }

    func testTheToolsAreActuallyOfferedInEachScope() {
        for scope in AgentToolScope.allCases {
            let names = ToolExecutor.specs(for: scope).map(\.name)
            print("=== \(scope.displayName): \(names.joined(separator: ", "))")
        }
        XCTAssertTrue(ToolExecutor.specs(for: .ask).map(\.name).contains("read_diagnostics"))
        XCTAssertTrue(ToolExecutor.specs(for: .plan).map(\.name).contains("run_task"))
        XCTAssertTrue(ToolExecutor.specs(for: .build).map(\.name).contains("run_task"))
        // Ask is read-only: a task runs a command, so it must not be offered there.
        XCTAssertFalse(ToolExecutor.specs(for: .ask).map(\.name).contains("run_task"))
    }

    func testRunTaskProducesACommandProposalNotADirectRun() {
        let root = URL(fileURLWithPath: "/Users/gazishahi/Documents/side-demo-repo")
        let executor = ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil })
        let result = executor.execute(
            name: "run_task", input: .object(["name": .string("test")]),
            toolUseId: "t1", scope: .build
        )
        guard case .commandProposal(let command) = result else {
            return XCTFail("run_task must go through the approval card, got \(result)")
        }
        XCTAssertEqual(command.command, "npm run test")
        XCTAssertEqual(command.taskName, "test")
    }

    func testAnUnknownTaskTellsTheModelWhatExists() {
        let root = URL(fileURLWithPath: "/Users/gazishahi/Documents/side-demo-repo")
        let executor = ToolExecutor(projectRoot: root, liveBufferProvider: { _ in nil })
        let result = executor.execute(
            name: "run_task", input: .object(["name": .string("bogus")]),
            toolUseId: "t1", scope: .build
        )
        guard case .completed(let output, let isError) = result else { return XCTFail("expected error") }
        XCTAssertTrue(isError)
        print("=== unknown-task message: \(output)")
        XCTAssertTrue(output.contains("test"), "the model isn't told which tasks exist")
    }

    func testExitCodeParsingMatchesWhatTheTerminalEmits() {
        // The terminal appends "\n[exit code: N]"; verification is only honest if this agrees.
        let passed = CheckpointVerification(taskName: "test", command: "npm run test",
                                           exitCode: 0, output: "ok\n[exit code: 0]")
        XCTAssertTrue(passed.passed)
        let failed = CheckpointVerification(taskName: "test", command: "npm run test",
                                            exitCode: 1, output: "boom\n[exit code: 1]")
        XCTAssertFalse(failed.passed)
    }
}

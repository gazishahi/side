import AppKit
import XCTest
@testable import Side

/// Fixed-size fixtures for the paths the audit flagged as unmeasured: large diffs, long
/// transcripts, and project-history load. These are baselines, not pass/fail gates — the value is
/// that a regression shows up as a number in a diff instead of as a user saying it feels slow.
///
/// Sizes are deliberately at the top of what's realistic (a 2,000-line diff, a 400-turn
/// conversation) rather than average, since that's where the O(n²) mistakes surface.
@MainActor
final class PerformanceTests: XCTestCase {
    /// Off by default: `measure` runs each block ten times, and the session fixture below is
    /// deliberately punishing, which together add minutes to an otherwise ~20-second suite.
    /// Run them deliberately:
    /// `TEST_RUNNER_SIDE_PERF=1 xcodebuild test -only-testing:SIDETests/PerformanceTests …`
    /// (xcodebuild only forwards environment variables prefixed `TEST_RUNNER_` into the test
    /// host, and strips the prefix — a plain `SIDE_PERF=1` silently skips everything, which is
    /// exactly the false-green this note exists to prevent).
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SIDE_PERF"] == "1",
            "performance baselines are opt-in; set SIDE_PERF=1"
        )
    }


    // MARK: - Fixtures

    private func largeDiffText(files: Int, linesPerFile: Int) -> String {
        var out = ""
        for fileIndex in 0..<files {
            out += "diff --git a/src/file\(fileIndex).swift b/src/file\(fileIndex).swift\n"
            out += "--- a/src/file\(fileIndex).swift\n+++ b/src/file\(fileIndex).swift\n"
            out += "@@ -1,\(linesPerFile) +1,\(linesPerFile) @@\n"
            for line in 0..<linesPerFile {
                switch line % 3 {
                case 0: out += "+    let added\(line) = \(line)\n"
                case 1: out += "-    let removed\(line) = \(line)\n"
                default: out += "     let context\(line) = \(line)\n"
                }
            }
        }
        return out
    }

    private func makeSession(turns: Int, resultBytes: Int) -> AgentSession {
        var session = AgentSession(trackKey: "perf", providerId: "anthropic", modelId: "claude-sonnet-5")
        let payload = String(repeating: "x", count: resultBytes)
        for index in 0..<turns {
            session.turns.append(AgentTurn(role: .user, content: [.text("message \(index)")]))
            session.turns.append(AgentTurn(role: .assistant, content: [
                .text("reply \(index)"),
                .toolUse(id: "tool\(index)", name: "read_file", input: .object(["path": .string("a.swift")])),
            ]))
            session.turns.append(AgentTurn(role: .user, content: [
                .toolResult(toolUseId: "tool\(index)", content: payload, isError: false)
            ]))
        }
        return session
    }

    // MARK: - Diff

    func testParsingA2000LineDiff() {
        let text = largeDiffText(files: 20, linesPerFile: 100)
        measure {
            let diff = UnifiedDiff.parse(text)
            XCTAssertEqual(diff.files.count, 20)
        }
    }

    func testRenderingA2000LineDiffBody() {
        let diff = UnifiedDiff.parse(largeDiffText(files: 1, linesPerFile: 2_000))
        let hunks = diff.files[0].hunks
        // One attributed string per card, not a view per line — this is the measurement that
        // would catch someone "simplifying" that back into stacked labels.
        measure {
            _ = DiffBody.attributedBody(hunks: hunks)
        }
    }

    func testBuildingManyDiffCards() {
        let diff = UnifiedDiff.parse(largeDiffText(files: 40, linesPerFile: 30))
        measure {
            for file in diff.files { _ = DiffFileCardView(file: file) }
        }
    }

    // MARK: - Session persistence

    func testWritingAndReloadingALongConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // 40 exchanges = 120 turns. Kept modest on purpose: `appendTurn` re-serializes the
        // *entire* session on every turn, so wall time here grows with the square of the
        // conversation length — this fixture already takes seconds, and the 360-turn version
        // took minutes. That quadratic write cost is a real finding this benchmark exposed;
        // fixing it means appending incrementally instead of rewriting.
        let session = makeSession(turns: 40, resultBytes: 2_000)

        measure {
            let store = AgentSessionStore(stateDirectory: directory)
            for turn in session.turns {
                store.appendTurn(turn, trackKey: "perf", providerId: "anthropic", modelId: "claude-sonnet-5")
            }
            // The reload is the half that used to load *every* track in the project at init.
            let reloaded = AgentSessionStore(stateDirectory: directory)
            XCTAssertNotNil(reloaded.session(forTrackKey: "perf"))
        }
    }

    func testRepairScanOverALongConversation() {
        let session = makeSession(turns: 200, resultBytes: 200)
        // Runs on every session load, so it has to stay linear in turn count.
        measure {
            _ = AgentSessionStore.repairingDanglingToolUses(session)
        }
    }

    // MARK: - Redaction

    func testRedactingLargeToolOutput() {
        // Every tool result passes through this before being stored or re-sent, so a pathological
        // regex here would tax every single command the agent runs.
        let output = String(repeating: "     let value = compute(index) // ordinary source line\n", count: 4_000)
        measure {
            _ = SecretRedactor.redacting(output)
        }
    }

    // MARK: - Usage accounting

    func testRollingUpAYearOfUsageRecords() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-usage-\(UUID().uuidString)")
            .appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let store = UsageStore(storeURL: storeURL)
        let calendar = Calendar.current
        let now = Date()
        for month in 0..<12 {
            let date = calendar.date(byAdding: .month, value: -month, to: now) ?? now
            for track in 0..<20 {
                store.record(
                    projectPath: "/project\(track % 4)", trackKey: "track\(track)",
                    providerId: "anthropic", modelId: "claude-sonnet-5",
                    usage: TokenUsage(inputTokens: 10_000, outputTokens: 2_000, cachedInputTokens: 40_000),
                    now: date
                )
            }
        }

        // Runs on every send (the budget check) and on every Think header refresh.
        measure {
            _ = UsageBudget.status(store: store, now: now)
            _ = store.totalsByModel()
            _ = store.totalsByProject()
        }
    }
}

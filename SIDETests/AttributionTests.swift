import XCTest
@testable import Side
import SideAgents

/// Sessions, phase 3 (SIDE_RFC_SESSIONS.md): who wrote each changed line.
final class AttributionTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "one\ntwo\nthree\nfour\nfive\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["add", "-A"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            XCTAssertTrue(GitPaths.runGitRaw(arguments, cwd: repo.path).success)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    private var file: URL { repo.appendingPathComponent("a.txt") }
    private let claude = Author(kind: .session, sessionID: "s1", agent: "claude", request: "Fix the counting")

    private func write(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) }
    private func authors(_ lines: ClosedRange<Int>, text: String? = nil) throws -> [Author] {
        let current = try text ?? String(contentsOf: file, encoding: .utf8)
        return Attribution.shared.authors(of: file, text: current, lines: lines)
    }
    private func record(_ author: Author, written: [String]?) {
        let done = expectation(description: "recorded")
        Attribution.shared.record(file, author: author, written: written) { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testAnAgentsEditIsItsAndTheRestStaysNoOnes() throws {
        try write("one\ntwo\nTHREE\nthree and a half\nfour\nfive\n")
        record(claude, written: ["THREE", "three and a half"])
        XCTAssertEqual(try authors(3...4), [claude])
        XCTAssertEqual(try authors(1...2), [], "lines as they were in HEAD are no one's")
        XCTAssertEqual(try authors(5...6), [])
        // Kept in the checkout's git folder, not among its files.
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/side/attribution.json").path))
        XCTAssertEqual(GitPaths.runGitRaw(["status", "--porcelain", "--untracked-files=all"], cwd: repo.path).output.trimmingCharacters(in: .whitespacesAndNewlines), "M a.txt")
    }

    func testWhatChangedInBetweenIsUnknownAndUnsavedTypingIsYours() throws {
        try write("one\ntwo\nTHREE\nfour\nfive\n")
        record(claude, written: ["THREE"])
        // Something else rewrote line 1; then the agent wrote again, only its own line.
        try write("ONE\ntwo\nTHREE\nfour\nfive\nsix\n")
        record(claude, written: ["six"])
        XCTAssertEqual(try authors(1...1), [.unknown])
        XCTAssertEqual(try authors(3...3), [claude], "an earlier write keeps its lines")
        XCTAssertEqual(try authors(6...6), [claude])
        // Typed in Side's editor, not saved yet: yours.
        let buffer = "ONE\ntwo\nTHREE\ntyped here\nfour\nfive\nsix\n"
        XCTAssertEqual(try authors(4...4, text: buffer), [.you])
        XCTAssertEqual(try authors(3...4, text: buffer), [claude, .you], "each author once, in order")
        // Saved: yours on disk too.
        try write(buffer)
        Attribution.shared.recordSave(file, text: buffer)
        XCTAssertEqual(try authors(4...4), [.you])
        XCTAssertEqual(try authors(3...3), [claude])
    }

    func testAWorktreesRecordIsItsOwn() throws {
        let worktree = repo.deletingLastPathComponent().appendingPathComponent("attribution-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: worktree) }
        XCTAssertTrue(GitPaths.runGitRaw(["worktree", "add", "-q", "-b", "fix", worktree.path], cwd: repo.path).success)
        let checkout = try XCTUnwrap(Attribution.checkout(of: worktree.appendingPathComponent("a.txt")))
        XCTAssertEqual(checkout.root.standardizedFileURL.path, worktree.standardizedFileURL.path)
        XCTAssertTrue(checkout.gitDirectory.path.contains("/.git/worktrees/"), checkout.gitDirectory.path)
    }

    /// What the hook brings: an edit's file and text, and a shell command's changed files.
    func testAHookEventSaysWhatWasWritten() throws {
        func event(_ body: [String: Any]) -> HookEvent {
            var event: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "s1", "cwd": repo.path]
            event.merge(body) { $1 }
            return HookEvent.parse(try! JSONSerialization.data(withJSONObject: ["side": ["agent": "claude", "ppid": 0, "at": 1], "event": event]))!
        }
        let edit = event(["tool_name": "Edit", "tool_input": ["file_path": file.path, "old_string": "three", "new_string": "THREE\nmore"]]).edit
        XCTAssertEqual(edit?.file, file)
        XCTAssertEqual(edit?.written, ["THREE", "more"])
        let multi = event(["tool_name": "MultiEdit", "tool_input": ["file_path": "a.txt", "edits": [["old_string": "a", "new_string": "x"], ["old_string": "b", "new_string": "y"]]]]).edit
        XCTAssertEqual(multi?.file.path, file.standardizedFileURL.path, "a relative path is the session's folder's")
        XCTAssertEqual(multi?.written, ["x", "y"])
        XCTAssertNil(event(["tool_name": "Write", "tool_input": ["file_path": file.path, "content": "all new"]]).edit?.written, "a whole file is the writer's")
        let shell = event(["tool_name": "Bash", "tool_input": ["command": "swift format -i ."], "tool_response": ["stdout": "", "bashEditDiff": ["changedFiles": ["a.txt"], "files": [["path": "b.txt"]]]]])
        XCTAssertEqual(shell.shellChanges.map(\.lastPathComponent), ["a.txt", "b.txt"])
        XCTAssertNil(event(["tool_name": "Read", "tool_input": ["file_path": file.path]]).edit)
    }
}

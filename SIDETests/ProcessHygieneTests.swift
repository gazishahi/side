import XCTest
@testable import Side
@testable import SideAgents

/// Two subprocess hazards the codebase has now fixed three times, checked statically so the
/// fourth time fails a test instead of hanging a user.
///
/// 1. `waitUntilExit()` before `readDataToEndOfFile()`: once the child fills the ~64 KB pipe
///    buffer it blocks writing while we block waiting, and neither side ever moves.
/// 2. `standardOutput = Pipe()` / `standardError = Pipe()` with nothing holding the pipe: the
///    child blocks the same way the moment it writes more than 64 KB, and nothing will ever read.
///    Output nobody wants goes to `FileHandle.nullDevice`, which never fills.
/// Every Swift source Side ships: the app and the SideAgents package.
/// Tree-scanning tests read this, so code moving into its own package doesn't quietly drop it
/// from their coverage.
enum SourceTree {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static var swiftFiles: [URL] {
        ["SIDE", "Packages/SideAgents/Sources"].flatMap { dir in
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

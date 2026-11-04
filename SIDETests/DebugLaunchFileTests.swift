import SideAgents
import XCTest
@testable import Side

/// SIDE_RFC_DEBUGGER.md, step 4: `.vscode/launch.json` read as VS Code reads it, with consent,
/// and the processes offered to attach to.
final class DebugLaunchFileTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/work/app")

    private static let launch = """
    {
      // VS Code's own comments and trailing commas.
      "version": "0.2.0",
      "configurations": [
        {
          "name": "Server",
          "type": "node",
          "request": "launch",
          "program": "${workspaceFolder}/src/${fileBasenameNoExtension}.js",
          "args": ["--port", "${env:PORT}"],
          "preLaunchTask": "tsc: build",
        },
        { "name": "Attach", "type": "node", "request": "attach", "port": 9229 },
        { "name": "Tool", "type": "lldb", "request": "launch", "program": "${workspaceFolder}/.build/debug/tool",
          "args": ["-v"], "cwd": "${workspaceFolder}/data", "env": {"LOG": "1", "GONE": null} },
        { "name": "Script", "type": "debugpy", "request": "launch", "program": "${file}", "justMyCode": false },
        { "name": "Service", "type": "go", "request": "launch", "mode": "debug", "program": "${fileDirname}" },
        { "name": "Picked", "type": "node", "request": "launch", "program": "${command:pickFile}" },
        { "name": "Java", "type": "java", "request": "launch" },
        { "name": "Missing task", "type": "node", "request": "launch", "program": "a.js", "preLaunchTask": "nope" }
      ]
    }
    """

    private static let tasks = """
    { "version": "2.0.0", "tasks": [
      { "label": "tsc: build", "type": "shell", "command": "npx tsc", "args": ["-p", "${workspaceFolder}/tsconfig.json"] },
    ] }
    """

    private func entries() -> [DebugLaunchFile.Entry] {
        DebugLaunchFile.entries(launchJSON: Self.launch, tasksJSON: Self.tasks, root: root,
                                currentFile: root.appendingPathComponent("src/main.py"), environment: ["PORT": "8080"])
    }

    func testConfigurationsBecomeSides() throws {
        let list = entries()
        XCTAssertEqual(list.map(\.name), ["Server", "Attach", "Tool", "Script", "Service", "Picked", "Java", "Missing task"])

        let server = try list[0].result.get()
        XCTAssertEqual(server.adapter, "js-debug")
        XCTAssertEqual(server.launchArguments?["type"], "pwa-node")
        XCTAssertEqual(server.launchArguments?["program"], "/work/app/src/main.js")
        XCTAssertEqual(server.launchArguments?["args"], ["--port", "8080"])
        XCTAssertEqual(server.launchArguments?["console"], "integratedTerminal", "a launched Node program gets a terminal")
        XCTAssertNil(server.launchArguments?["preLaunchTask"])
        XCTAssertEqual(server.build, "npx tsc '-p' '/work/app/tsconfig.json'")

        let attach = try list[1].result.get()
        XCTAssertEqual(attach.request, "attach")
        XCTAssertEqual(attach.launchArguments?["port"], 9229)
        XCTAssertNil(attach.launchArguments?["console"])

        let tool = try list[2].result.get()
        XCTAssertEqual(tool.adapter, "lldb-dap")
        XCTAssertNil(tool.launchArguments, "lldb-dap's own arguments, so the program gets its Run tab")
        XCTAssertEqual(tool.program, "/work/app/.build/debug/tool")
        XCTAssertEqual(tool.arguments, ["-v"])
        XCTAssertEqual(tool.directory, "/work/app/data")
        XCTAssertEqual(tool.environment, ["LOG": "1"])

        let script = try list[3].result.get()
        XCTAssertEqual(script.adapter, "debugpy")
        XCTAssertEqual(script.launchArguments?["type"], "python")
        XCTAssertEqual(script.launchArguments?["program"], "/work/app/src/main.py")
        XCTAssertEqual(script.launchArguments?["justMyCode"], false)

        let service = try list[4].result.get()
        XCTAssertEqual(service.adapter, "delve")
        XCTAssertEqual(service.launchArguments?["program"], "/work/app/src")
        XCTAssertEqual(service.launchArguments?["outputMode"], "remote")
    }

    func testWhatSideCantRunSaysWhy() {
        let list = entries()
        guard case .failure(let picked) = list[5].result, case .failure(let java) = list[6].result, case .failure(let missing) = list[7].result else {
            return XCTFail("expected three unsupported")
        }
        XCTAssertTrue(picked.reason.contains("${command:pickFile}"), picked.reason)
        XCTAssertTrue(java.reason.contains("\u{201C}java\u{201D}"), java.reason)
        XCTAssertTrue(missing.reason.contains("\u{201C}nope\u{201D}"), missing.reason)
    }

    func testAFileVariableNeedsAFile() {
        let list = DebugLaunchFile.entries(launchJSON: Self.launch, tasksJSON: Self.tasks, root: root, currentFile: nil)
        guard case .failure(let script) = list[3].result else { return XCTFail("needs a file") }
        XCTAssertTrue(script.reason.contains("${file}"), script.reason)
    }

    func testTheFilesTakeEffectOnlyOnceAccepted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("side-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.launch.write(to: dir.appendingPathComponent(DebugLaunchFile.path), atomically: true, encoding: .utf8)
        try Self.tasks.write(to: dir.appendingPathComponent(DebugLaunchFile.tasksPath), atomically: true, encoding: .utf8)

        XCTAssertEqual(DebugLaunchFile.pending(root: dir).map { $0.url.lastPathComponent }, ["launch.json", "tasks.json"])
        XCTAssertTrue(DebugLaunchFile.entries(root: dir, currentFile: nil).isEmpty, "nothing from the file before it's accepted")
        DebugLaunchFile.accept(DebugLaunchFile.pending(root: dir))
        XCTAssertTrue(DebugLaunchFile.pending(root: dir).isEmpty)
        let server = try XCTUnwrap(DebugLaunchFile.entries(root: dir, currentFile: dir.appendingPathComponent("src/main.js")).first?.result.get())
        XCTAssertNotNil(server.build)

        // A changed file is asked about again.
        try (Self.launch + "\n").write(to: dir.appendingPathComponent(DebugLaunchFile.path), atomically: true, encoding: .utf8)
        XCTAssertEqual(DebugLaunchFile.pending(root: dir).map { $0.url.lastPathComponent }, ["launch.json"])
        XCTAssertTrue(DebugLaunchFile.entries(root: dir, currentFile: nil).isEmpty)
    }

    func testTheProcessListIsThePersonsOwn() {
        let output = """
          101 /Applications/Safari.app/Contents/MacOS/Safari
          202 /usr/libexec/trustd
          303 /opt/homebrew/bin/node
          404 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
          505 /Users/me/app/.build/debug/tool
          606 /Applications/Side.app/Contents/MacOS/Side
          707 -zsh
          808 /Library/Developer/CoreSimulator/Volumes/iOS/Library/RuntimeRoot/System/Library/akd
        """
        let list = DebugProcesses.parse(output, excluding: 606)
        XCTAssertEqual(list.map(\.pid), [303, 101, 505])
        XCTAssertEqual(list.map(\.isNode), [true, false, false])
        // The project's own program first.
        XCTAssertEqual(DebugProcesses.parse(output, excluding: 606, projectRoot: "/Users/me/app").map(\.pid), [505, 303, 101])
        XCTAssertFalse(DebugProcesses.list().isEmpty)
    }
}

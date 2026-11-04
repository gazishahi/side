import Foundation
import SideAgents

/// A project's `.vscode/launch.json` (SIDE_RFC_DEBUGGER.md, Q3): its configurations as Side's,
/// with VS Code's variables filled in and `preLaunchTask` found in `.vscode/tasks.json`. The
/// files arrive with a cloned repository and run commands, so they take effect only once the
/// person has accepted them (the per-content consent `.side/tasks.json` has).
enum DebugLaunchFile {
    static let path = ".vscode/launch.json"
    static let tasksPath = ".vscode/tasks.json"

    /// A configuration from the file: Side's, or why Side can't run it.
    struct Entry: Equatable, Sendable {
        let name: String
        let type: String
        let result: Result<DebugConfiguration, Unsupported>
    }

    struct Unsupported: Error, Equatable, Sendable {
        let reason: String
    }

    /// What's there to accept first: the launch file, and the tasks file when a configuration
    /// runs one of its tasks. Empty once accepted (or with no launch file).
    nonisolated static func pending(root: URL) -> [(url: URL, contents: String)] {
        [path, tasksPath].compactMap { relative in
            let url = root.appendingPathComponent(relative)
            guard let contents = try? String(contentsOf: url, encoding: .utf8), !contents.isEmpty,
                  !ProjectRules.isAcknowledged(url: url, contents: contents) else { return nil }
            // The tasks file matters only with a launch file to point into it.
            if relative == tasksPath, !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { return nil }
            return (url, contents)
        }
    }

    nonisolated static func accept(_ files: [(url: URL, contents: String)]) {
        for file in files { ProjectRules.acknowledge(url: file.url, contents: file.contents) }
    }

    /// The accepted file's configurations, in its order (none until it's accepted).
    nonisolated static func entries(root: URL, currentFile: URL?) -> [Entry] {
        let url = root.appendingPathComponent(path)
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              ProjectRules.isAcknowledged(url: url, contents: contents) else { return [] }
        return entries(launchJSON: contents, tasksJSON: acceptedTasks(root: root), root: root, currentFile: currentFile)
    }

    private nonisolated static func acceptedTasks(root: URL) -> String? {
        let url = root.appendingPathComponent(tasksPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8), ProjectRules.isAcknowledged(url: url, contents: contents) else { return nil }
        return contents
    }

    /// The configurations in a launch file's text (and its tasks file's, for `preLaunchTask`).
    nonisolated static func entries(launchJSON: String, tasksJSON: String?, root: URL, currentFile: URL?,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> [Entry] {
        guard let object = parse(launchJSON), let configurations = object["configurations"] as? [[String: Any]] else { return [] }
        let tasks = tasksJSON.flatMap(parse).flatMap { $0["tasks"] as? [[String: Any]] } ?? []
        let variables = Variables(root: root, file: currentFile, environment: environment)
        return configurations.map { raw in
            let name = raw["name"] as? String ?? "Unnamed"
            let type = raw["type"] as? String ?? ""
            return Entry(name: name, type: type, result: configuration(raw, name: name, type: type, tasks: tasks, variables: variables, root: root))
        }
    }

    nonisolated static func parse(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(VSCodeTheme.stripJSONC(text).utf8)) as? [String: Any]
    }

    // MARK: One configuration

    private nonisolated static func configuration(_ raw: [String: Any], name: String, type: String, tasks: [[String: Any]],
                                                  variables: Variables, root: URL) -> Result<DebugConfiguration, Unsupported> {
        let filled: [String: Any]
        do { filled = try variables.fill(raw) as? [String: Any] ?? raw } catch let error as Unsupported { return .failure(error) } catch { return .failure(Unsupported(reason: "\(error)")) }
        let request = filled["request"] as? String ?? "launch"
        let directory = filled["cwd"] as? String ?? root.path
        var build: String?
        if let label = filled["preLaunchTask"] as? String {
            guard let command = task(label, in: tasks, variables: variables) else {
                return .failure(Unsupported(reason: "Its preLaunchTask \u{201C}\(label)\u{201D} isn't in \(tasksPath) (or that file isn't accepted yet)."))
            }
            build = command
        }
        let passed = filled.filter { !["name", "preLaunchTask", "postDebugTask", "presentation", "internalConsoleOptions", "serverReadyAction"].contains($0.key) }

        switch type {
        case "lldb-dap", "lldb", "swift", "swift-lldb", "codelldb":
            // LLDB's: the program, its arguments, directory and environment, or a process to attach to.
            if request == "attach" {
                var arguments = passed.mapValues { LSPValue(any: $0) }
                arguments["type"] = nil
                if arguments["pid"] == nil, let pid = filled["processId"] { arguments["pid"] = LSPValue(any: pid) }
                return .success(DebugConfiguration(name: name, adapter: DebugAdapters.lldb.id, request: "attach", launchArguments: arguments, directory: directory, build: build))
            }
            guard let program = filled["program"] as? String else { return .failure(Unsupported(reason: "It has no program.")) }
            var configuration = DebugConfiguration(name: name, program: program, directory: directory, build: build)
            configuration.arguments = (filled["args"] as? [Any])?.map { "\($0)" } ?? []
            if let env = filled["env"] as? [String: Any] {
                configuration.environment = env.compactMapValues { $0 is NSNull ? nil : "\($0)" }
            } else if let env = filled["env"] as? [String] {
                // lldb-dap's own shape: "NAME=value".
                configuration.environment = Dictionary(env.compactMap { entry in
                    entry.firstIndex(of: "=").map { (String(entry[..<$0]), String(entry[entry.index(after: $0)...])) }
                }, uniquingKeysWith: { $1 })
            }
            return .success(configuration)
        case "node", "pwa-node", "node-terminal", "chrome", "pwa-chrome", "msedge", "pwa-msedge":
            var arguments = passed.mapValues { LSPValue(any: $0) }
            // js-debug's own names for VS Code's types.
            arguments["type"] = .string(type.hasPrefix("pwa-") ? type : (type == "node-terminal" ? "node-terminal" : "pwa-" + type))
            arguments["request"] = .string(request)
            arguments["name"] = .string(name)
            if arguments["cwd"] == nil { arguments["cwd"] = .string(directory) }
            if request == "launch", type.contains("node"), arguments["console"] == nil { arguments["console"] = "integratedTerminal" }
            return .success(DebugConfiguration(name: name, adapter: DebugAdapters.jsDebug.id, request: request, launchArguments: arguments, directory: directory, build: build))
        case "python", "debugpy":
            var arguments = passed.mapValues { LSPValue(any: $0) }
            arguments["type"] = "python"
            arguments["request"] = .string(request)
            arguments["name"] = .string(name)
            if request == "launch", arguments["console"] == nil { arguments["console"] = "integratedTerminal" }
            if arguments["cwd"] == nil { arguments["cwd"] = .string(directory) }
            return .success(DebugConfiguration(name: name, adapter: DebugAdapters.debugpy.id, request: request, launchArguments: arguments, directory: directory, build: build))
        case "go":
            var arguments = passed.mapValues { LSPValue(any: $0) }
            arguments["type"] = nil
            arguments["request"] = .string(request)
            if request == "launch", arguments["outputMode"] == nil { arguments["outputMode"] = "remote" }
            return .success(DebugConfiguration(name: name, adapter: DebugAdapters.delve.id, request: request, launchArguments: arguments, directory: directory, build: build))
        case "":
            return .failure(Unsupported(reason: "It has no type."))
        default:
            return .failure(Unsupported(reason: "Side doesn\u{2019}t debug \u{201C}\(type)\u{201D} configurations yet."))
        }
    }

    /// A task's command line, found by its label: `command` and `args`, quoted for a shell.
    private nonisolated static func task(_ label: String, in tasks: [[String: Any]], variables: Variables) -> String? {
        guard let task = tasks.first(where: { ($0["label"] as? String ?? $0["taskName"] as? String) == label }),
              let filled = try? variables.fill(task) as? [String: Any], let command = filled["command"] as? String else { return nil }
        let arguments = (filled["args"] as? [Any] ?? []).map { argument -> String in
            let text = (argument as? [String: Any])?["value"] as? String ?? "\(argument)"
            return DebugLaunch.shellQuoted(text)
        }
        // A shell task's command is a command line already; a process task's is one program.
        let head = (filled["type"] as? String) == "process" ? DebugLaunch.shellQuoted(command) : command
        return ([head] + arguments).joined(separator: " ")
    }

    // MARK: Variables

    /// VS Code's `${…}` variables Side can fill: the workspace, the open file, the environment.
    /// One Side can't (`${command:…}`, `${input:…}`) makes the configuration unusable, not wrong.
    struct Variables: Sendable {
        let root: URL
        let file: URL?
        let environment: [String: String]

        nonisolated func value(_ name: String) throws -> String {
            func needFile() throws -> URL {
                guard let file else { throw Unsupported(reason: "It uses ${\(name)}, which needs a file open.") }
                return file
            }
            switch name {
            case "workspaceFolder", "workspaceRoot", "cwd": return root.path
            case "workspaceFolderBasename": return root.lastPathComponent
            case "userHome": return NSHomeDirectory()
            case "pathSeparator", "/": return "/"
            case "file": return try needFile().path
            case "fileBasename": return try needFile().lastPathComponent
            case "fileBasenameNoExtension": return try needFile().deletingPathExtension().lastPathComponent
            case "fileExtname": return try needFile().pathExtension.isEmpty ? "" : "." + needFile().pathExtension
            case "fileDirname": return try needFile().deletingLastPathComponent().path
            case "fileDirnameBasename": return try needFile().deletingLastPathComponent().lastPathComponent
            case "fileWorkspaceFolder": return root.path
            case "relativeFile":
                let path = try needFile().path
                return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
            case "relativeFileDirname":
                let path = try needFile().deletingLastPathComponent().path
                return path == root.path ? "." : (path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path)
            default:
                if name.hasPrefix("env:") { return environment[String(name.dropFirst(4))] ?? "" }
                if name.hasPrefix("workspaceFolder:") { return root.path }
                throw Unsupported(reason: "It uses ${\(name)}, which Side can\u{2019}t fill in yet.")
            }
        }

        nonisolated func fill(_ value: Any) throws -> Any {
            switch value {
            case let text as String: return try fill(text)
            case let array as [Any]: return try array.map(fill)
            case let object as [String: Any]: return try object.mapValues(fill)
            default: return value
            }
        }

        nonisolated func fill(_ text: String) throws -> String {
            guard text.contains("${") else { return text }
            var result = ""
            var rest = Substring(text)
            while let open = rest.range(of: "${") {
                result += rest[..<open.lowerBound]
                guard let close = rest[open.upperBound...].firstIndex(of: "}") else { result += rest[open.lowerBound...]; return result }
                result += try value(String(rest[open.upperBound..<close]))
                rest = rest[rest.index(after: close)...]
            }
            return result + rest
        }
    }
}

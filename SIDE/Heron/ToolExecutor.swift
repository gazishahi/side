import Foundation

/// Executes the tools Heron offers the model. Read tools auto-run (pure reads, nothing to
/// promote); write tools deliberately **cannot** mutate anything from here — they return a
/// `ProposedEdit` for human approval instead, which is why this type still contains no code
/// that touches disk. `run_shell_command` never runs anything here either — it always returns a
/// `ProposedCommand` for `AgentRunner` to execute via `WorkspaceBridge.runShellCommand`, which
/// types it into the track's own real Run terminal; this type has no `Process` of its own.
struct ToolExecutor {
    let projectRoot: URL
    /// Live unsaved editor content by absolute path, supplied by Make. An agent reading a file
    /// the user has unsaved edits in should see what's on screen, not stale disk content —
    /// otherwise it reasons about code that no longer exists.
    var liveBufferProvider: (URL) -> String?

    private static let maxOutputCharacters = 60_000
    private static let maxListedFiles = 400
    private static let maxSearchMatches = 100

    /// The tools a given scope actually exposes. Filtering the *specs* is the enforcement point
    /// for `AgentToolScope`: a model that never sees `write_file` can't propose a write, which
    /// makes Ask/Plan a real boundary rather than an instruction it might reason past.
    static func specs(for scope: AgentToolScope) -> [ToolSpec] {
        specs.filter { spec in
            switch spec.name {
            case "edit_file", "write_file": return scope.allowsWrites
            case "run_shell_command": return scope.allowsCommands
            default: return true
            }
        }
    }

    static var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "read_file",
                description: "Read a UTF-8 text file from the open project. Paths are relative to the project root. Returns the file with 1-based line numbers prefixed, so you can cite exact lines.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Path relative to the project root.")]),
                        "start_line": .object(["type": .string("number"), "description": .string("Optional 1-based first line to return.")]),
                        "line_count": .object(["type": .string("number"), "description": .string("Optional number of lines to return from start_line.")]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
            ToolSpec(
                name: "list_files",
                description: "List files in the open project, optionally filtered. Hidden files and dependency/build directories (node_modules, .build, DerivedData, …) are excluded, matching what the file explorer shows.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path_contains": .object(["type": .string("string"), "description": .string("Optional case-insensitive substring the relative path must contain.")]),
                        "extension": .object(["type": .string("string"), "description": .string("Optional file extension filter, without the dot.")]),
                    ]),
                ])
            ),
            ToolSpec(
                name: "edit_file",
                description: "Propose replacing an exact string in a file with new text. The user reviews the diff and approves or rejects it — nothing is written until they approve. old_string must appear exactly once in the file; include surrounding lines to make it unique.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Path relative to the project root.")]),
                        "old_string": .object(["type": .string("string"), "description": .string("Exact existing text to replace, including indentation.")]),
                        "new_string": .object(["type": .string("string"), "description": .string("Replacement text.")]),
                    ]),
                    "required": .array([.string("path"), .string("old_string"), .string("new_string")]),
                ])
            ),
            ToolSpec(
                name: "write_file",
                description: "Propose creating a new file, or replacing an existing file's entire contents. The user reviews the diff and approves or rejects it — nothing is written until they approve. Prefer edit_file for changes to existing files.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Path relative to the project root.")]),
                        "content": .object(["type": .string("string"), "description": .string("The file's full new contents.")]),
                    ]),
                    "required": .array([.string("path"), .string("content")]),
                ])
            ),
            ToolSpec(
                name: "search_files",
                description: "Search file contents across the open project for a literal string or regular expression. Returns matching lines with their file path and line number.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("Literal text, or a regular expression when is_regex is true.")]),
                        "is_regex": .object(["type": .string("boolean"), "description": .string("Treat query as a regular expression. Defaults to false.")]),
                        "extension": .object(["type": .string("string"), "description": .string("Optional file extension filter, without the dot.")]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            ),
            ToolSpec(
                name: "run_shell_command",
                description: "Propose running a shell command in this track's own terminal session (Run). The user reviews and approves or rejects it before it actually runs — nothing executes until they approve, unless they've turned on auto-run for this track. Runs from the project root (or the track's own worktree, if it has one).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object(["type": .string("string"), "description": .string("The shell command to run.")]),
                    ]),
                    "required": .array([.string("command")]),
                ])
            ),
        ]
    }

    static let writeToolNames: Set<String> = ["edit_file", "write_file"]

    /// A tool either finished (read tools) or produced something a human must approve first
    /// (write tools, and `run_shell_command`). Keeping these in one return type means the caller
    /// can't accidentally treat a pending proposal as a completed action.
    enum Result {
        case completed(output: String, isError: Bool)
        case proposal(ProposedEdit)
        case commandProposal(ProposedCommand)
    }

    /// Runs off the main thread (file I/O), so `liveBufferProvider` must be snapshotted by the
    /// caller before dispatching — never read the editor's storage from here.
    /// Runs a tool the model asked for, refusing anything outside `scope`.
    ///
    /// The scope check has to live *here*, not only in `specs(for:)`. Filtering the spec list
    /// decides what the model is *shown*; the name that comes back arrives verbatim off the
    /// provider stream and was dispatched unchecked, so a local or BYOK endpoint that emitted
    /// `write_file` in an Ask-mode conversation produced a real edit proposal — and at `.full`
    /// autonomy it applied itself. Replaying history after a Build→Ask switch was a second
    /// route to the same place. A boundary the caller can talk past is an instruction, not a
    /// boundary, so this is where it's enforced.
    func execute(name: String, input: JSONValue, toolUseId: String, scope: AgentToolScope) -> Result {
        guard Self.specs(for: scope).contains(where: { $0.name == name }) else {
            return .completed(
                output: "Refused: \(name) isn't available in \(scope.displayName) mode. Tell the user what you'd need to do and let them switch modes.",
                isError: true
            )
        }
        switch name {
        case "read_file":
            let (output, isError) = readFile(input)
            return .completed(output: output, isError: isError)
        case "list_files":
            let (output, isError) = listFiles(input)
            return .completed(output: output, isError: isError)
        case "search_files":
            let (output, isError) = searchFiles(input)
            return .completed(output: output, isError: isError)
        case "edit_file":
            return proposeEdit(input, toolUseId: toolUseId)
        case "write_file":
            return proposeWrite(input, toolUseId: toolUseId)
        case "run_shell_command":
            guard let command = input.stringValue(for: "command"), !command.isEmpty else {
                return .completed(output: "Missing required argument: command", isError: true)
            }
            return .commandProposal(ProposedCommand(toolUseId: toolUseId, command: command))
        default:
            return .completed(output: "Unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - Write tools (propose only — never touch disk)

    private func proposeEdit(_ input: JSONValue, toolUseId: String) -> Result {
        guard let path = input.stringValue(for: "path") else { return .completed(output: "Missing required argument: path", isError: true) }
        guard let oldString = input.stringValue(for: "old_string") else { return .completed(output: "Missing required argument: old_string", isError: true) }
        guard let newString = input.stringValue(for: "new_string") else { return .completed(output: "Missing required argument: new_string", isError: true) }
        guard let url = ProjectFileAccess.resolveInsideProject(path: path, root: projectRoot),
              ProjectFileAccess.isReadable(url, root: projectRoot) else {
            return .completed(output: "Refused: \(path) is outside the open project.", isError: true)
        }
        guard ProjectFileAccess.isWritable(url, root: projectRoot) else {
            return .completed(output: "Refused: \(path) is part of the repository's or Side's own internals, which tools must not write.", isError: true)
        }
        guard let base = currentContent(of: url) else {
            return .completed(output: "Couldn't read \(path) — it may not exist. Use write_file to create it.", isError: true)
        }
        // Exactly-once matching, same contract as the editor's own find-and-replace expectations:
        // an ambiguous match means the model doesn't actually know which site it's changing.
        let occurrences = base.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            return .completed(output: "old_string wasn't found in \(path). Re-read the file — it may differ from what you expected.", isError: true)
        }
        guard occurrences == 1 else {
            return .completed(output: "old_string appears \(occurrences) times in \(path). Include more surrounding context so it matches exactly once.", isError: true)
        }
        let proposed = base.replacingOccurrences(of: oldString, with: newString)
        guard proposed != base else {
            return .completed(output: "That edit wouldn't change \(path) — old_string and new_string are identical.", isError: true)
        }
        return .proposal(ProposedEdit(toolUseId: toolUseId, url: url, relativePath: relativePath(for: url), baseContent: base, proposedContent: proposed, isNewFile: false))
    }

    private func proposeWrite(_ input: JSONValue, toolUseId: String) -> Result {
        guard let path = input.stringValue(for: "path") else { return .completed(output: "Missing required argument: path", isError: true) }
        guard let content = input.stringValue(for: "content") else { return .completed(output: "Missing required argument: content", isError: true) }
        guard let url = ProjectFileAccess.resolveInsideProject(path: path, root: projectRoot) else {
            return .completed(output: "Refused: \(path) is outside the open project.", isError: true)
        }
        guard ProjectFileAccess.isWritable(url, root: projectRoot) else {
            return .completed(output: "Refused: \(path) is part of the repository's or Side's own internals, which tools must not write.", isError: true)
        }
        let existing = currentContent(of: url)
        if let existing, existing == content {
            return .completed(output: "\(path) already has exactly that content — nothing to change.", isError: true)
        }
        return .proposal(ProposedEdit(
            toolUseId: toolUseId, url: url, relativePath: relativePath(for: url),
            baseContent: existing ?? "", proposedContent: content, isNewFile: existing == nil
        ))
    }

    /// The content a proposal is computed against: unsaved buffer if the file is open and dirty
    /// in Make, otherwise disk. nil means the file doesn't exist.
    func currentContent(of url: URL) -> String? {
        if let live = liveBufferProvider(url) { return live }
        guard let data = try? Data(contentsOf: url), data.count <= ProjectFileAccess.maxReadableFileSize else { return nil }
        return ProjectFileAccess.decodeText(from: data)
    }

    private func relativePath(for url: URL) -> String {
        let rootPrefix = projectRoot.standardizedFileURL.path + "/"
        return url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.lastPathComponent
    }

    // MARK: - Tools

    private func readFile(_ input: JSONValue) -> (String, Bool) {
        guard let path = input.stringValue(for: "path") else { return ("Missing required argument: path", true) }
        guard let url = ProjectFileAccess.resolveInsideProject(path: path, root: projectRoot) else {
            return ("Refused: \(path) is outside the open project.", true)
        }
        let text: String
        if let live = liveBufferProvider(url) {
            text = live
        } else {
            guard let data = try? Data(contentsOf: url) else { return ("Couldn't read \(path) — it may not exist.", true) }
            guard data.count <= ProjectFileAccess.maxReadableFileSize else {
                return ("\(path) is \(data.count / 1_000_000) MB, over the 10 MB read limit.", true)
            }
            guard let decoded = ProjectFileAccess.decodeText(from: data) else {
                return ("\(path) doesn't appear to be a text file.", true)
            }
            text = decoded
        }

        var lines = text.components(separatedBy: "\n")
        let totalLines = lines.count
        var firstLineNumber = 1
        if let start = input.intValue(for: "start_line"), start > 1 {
            firstLineNumber = min(start, totalLines)
            lines = Array(lines.dropFirst(firstLineNumber - 1))
        }
        if let count = input.intValue(for: "line_count"), count > 0, count < lines.count {
            lines = Array(lines.prefix(count))
        }
        let numbered = lines.enumerated().map { "\(firstLineNumber + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        return (truncate(numbered, note: "file truncated"), false)
    }

    private func listFiles(_ input: JSONValue) -> (String, Bool) {
        let substring = input.stringValue(for: "path_contains")?.lowercased()
        let ext = input.stringValue(for: "extension")?.lowercased()
        var matches = ProjectFileAccess.scan(root: projectRoot).map(\.relativePath)
        if let substring, !substring.isEmpty { matches = matches.filter { $0.lowercased().contains(substring) } }
        if let ext, !ext.isEmpty { matches = matches.filter { ($0 as NSString).pathExtension.lowercased() == ext } }
        guard !matches.isEmpty else { return ("No matching files.", false) }
        let total = matches.count
        var body = matches.prefix(Self.maxListedFiles).joined(separator: "\n")
        if total > Self.maxListedFiles { body += "\n… \(total - Self.maxListedFiles) more (narrow the filter to see them)" }
        return (truncate(body, note: "list truncated"), false)
    }

    private func searchFiles(_ input: JSONValue) -> (String, Bool) {
        guard let query = input.stringValue(for: "query"), !query.isEmpty else {
            return ("Missing required argument: query", true)
        }
        let isRegex = input.boolValue(for: "is_regex") ?? false
        var regex: NSRegularExpression?
        if isRegex {
            do {
                regex = try NSRegularExpression(pattern: query, options: [.caseInsensitive])
            } catch {
                return ("Invalid regular expression: \(error.localizedDescription)", true)
            }
        }
        let ext = input.stringValue(for: "extension")?.lowercased()

        var results: [String] = []
        var truncated = false
        for file in ProjectFileAccess.scan(root: projectRoot) {
            if let ext, !ext.isEmpty, (file.relativePath as NSString).pathExtension.lowercased() != ext { continue }
            guard let data = try? Data(contentsOf: file.url), data.count <= ProjectFileAccess.maxReadableFileSize,
                  let text = liveBufferProvider(file.url) ?? ProjectFileAccess.decodeText(from: data) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let matched: Bool
                if let regex {
                    matched = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                } else {
                    matched = line.range(of: query, options: .caseInsensitive) != nil
                }
                guard matched else { continue }
                results.append("\(file.relativePath):\(index + 1)\t\(line.trimmingCharacters(in: .whitespaces))")
                if results.count >= Self.maxSearchMatches { truncated = true; break }
            }
            if truncated { break }
        }
        guard !results.isEmpty else { return ("No matches for \(query).", false) }
        var body = results.joined(separator: "\n")
        if truncated { body += "\n… more matches not shown (narrow the search to see them)" }
        return (truncate(body, note: "results truncated"), false)
    }

    /// Tool output is fed straight back into the model's context, so an unbounded read of a
    /// generated file could blow the whole context window on one call.
    private func truncate(_ text: String, note: String) -> String {
        guard text.count > Self.maxOutputCharacters else { return text }
        return String(text.prefix(Self.maxOutputCharacters)) + "\n… [\(note)]"
    }
}

private extension JSONValue {
    func stringValue(for key: String) -> String? {
        guard case .object(let object) = self, case .string(let value)? = object[key] else { return nil }
        return value
    }

    func intValue(for key: String) -> Int? {
        guard case .object(let object) = self else { return nil }
        switch object[key] {
        case .number(let value): return Int(value)
        // Models sometimes emit numeric arguments as strings; accepting both avoids a
        // spurious tool error the model then has to guess its way out of.
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    func boolValue(for key: String) -> Bool? {
        guard case .object(let object) = self else { return nil }
        switch object[key] {
        case .bool(let value): return value
        case .string(let value): return value == "true"
        default: return nil
        }
    }
}

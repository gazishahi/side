import Foundation

struct ScannedFile {
    let url: URL
    let relativePath: String
}

/// Shared project-file walking and text decoding. Extracted from
/// MakeWorkspaceViewController (which still owns the quick-open index built on top of it) so
/// Heron's read tools see exactly the same files, with the same ignore rules, that quick-open
/// shows the user — an agent that could "see" files the file explorer hides, or vice versa,
/// would be confusing in both directions.
enum ProjectFileAccess {
    static let maxIndexedFiles = 25000
    static let maxReadableFileSize = 10_000_000

    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules", ".next", "Pods", "dist", "build",
        ".venv", "venv", "vendor", "Carthage", "target", "out", ".cache", "coverage",
        "__pycache__", ".tox", ".mypy_cache", ".pytest_cache",
    ]

    nonisolated static func scan(root: URL) -> [ScannedFile] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        let rootPrefix = root.path + "/"
        var scanned: [ScannedFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true && ignoredDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if values?.isRegularFile == true && !url.pathExtension.isEmpty {
                scanned.append(ScannedFile(url: url, relativePath: url.path.replacingOccurrences(of: rootPrefix, with: "")))
            }
            if scanned.count >= maxIndexedFiles { break }
        }
        return scanned.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// UTF-8 alone rejected any file with a Latin-1/Windows-1252 byte in it — real source files
    /// (a stray non-ASCII character in a comment, anything authored on Windows) got a false
    /// "not a text file" refusal instead of opening. `.isoLatin1` never fails to decode any byte
    /// sequence at all, so it's a deliberate last resort here, not real detection — better to
    /// open a legitimate non-UTF-8 file than to refuse it outright.
    static func decodeText(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Resolves an agent-supplied path (relative to the project root, or absolute) and refuses
    /// anything that escapes the project. Load-bearing for the read tools: without it, a
    /// `../../.ssh/id_rsa` argument would happily be read and streamed back to a model.
    static func resolveInsideProject(path: String, root: URL) -> URL? {
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let resolved = URL(fileURLWithPath: candidate.path).standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        return resolved
    }

    /// Paths inside the project that tools must not *read*.
    ///
    /// `.git/side/` holds Side's own state: every track's record and every track's full
    /// conversation, including the user's own messages, which are never redacted (only tool
    /// results pass through the redactor). `.git` is already hidden from listings, but
    /// `read_file` takes an explicit path — so without this, an agent in one track could read
    /// everything the user has ever typed in every other track of the project, and prompt
    /// injection from a repo file made that reachable without the user's involvement.
    static func isReadable(_ url: URL, root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(resolvedRoot + "/") else { return true }
        let relative = String(url.path.dropFirst(resolvedRoot.count + 1))
        return !relative.hasPrefix(".git/side/") && !relative.hasPrefix(".side/")
    }

    /// Paths that are inside the project but must never be *written* by a tool.
    ///
    /// Containment alone isn't enough for writes: `.git/config` and `.git/hooks/` turn an edit
    /// into code execution. A `core.fsmonitor` or `core.hooksPath` entry runs on git's next
    /// invocation — and Side itself runs `git status` unattended while checkpointing — so a
    /// write there escapes the approval boundary entirely, without ever going near
    /// `CommandAutoRunPolicy`. At `.full` autonomy it wouldn't even need a click.
    ///
    /// `.side/` is Side's own per-project state (track records, conversations); an agent
    /// rewriting it could forge checkpoints or plant standing instructions for future sessions.
    static func isWritable(_ url: URL, root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(resolvedRoot + "/") else { return url.path != resolvedRoot }
        let relative = String(url.path.dropFirst(resolvedRoot.count + 1))
        let firstComponent = relative.split(separator: "/").first.map(String.init) ?? relative
        return firstComponent != ".git" && firstComponent != ".side"
    }
}

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
}

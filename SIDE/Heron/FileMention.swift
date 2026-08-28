import Foundation

/// `@path/to/file.swift` in a Think message — a *pointer*, never inlined content.
///
/// The tempting implementation is to paste the referenced file into the message. Don't: a
/// conversation that mentions six files would then carry six full copies in its persisted turns
/// *and* re-send all of them on every subsequent message, for the rest of the track's life. That
/// is precisely the unbounded-growth shape `AgentSessionStore` was restructured to kill, and it
/// would cost real money on every turn besides.
///
/// So a mention resolves to a path the model is told about, and the model reads it with the
/// `read_file` tool if it actually needs the contents. One extra round trip, bounded context.
struct FileMention: Equatable {
    /// Exactly what the user typed after `@`, so an error message can quote them.
    let raw: String
    /// Project-relative path, resolved against what's actually on disk.
    let relativePath: String
    let isDirectory: Bool
}

enum FileMentionResolver {
    /// Characters a mention can contain. Deliberately excludes `,` and `;` so
    /// "look at @a.swift, @b.swift" doesn't swallow punctuation into the path, and stops at
    /// whitespace so prose after a mention stays prose.
    private static let terminators = CharacterSet(charactersIn: " \t\n\r,;:!?)\u{201D}\"'")

    /// Pulls `@`-prefixed tokens out of message text.
    ///
    /// Skips an `@` that's part of a larger word (`user@example.com`, `@2x.png`) by requiring the
    /// preceding character to be whitespace or the start of the string — otherwise every email
    /// address in a message becomes a broken file reference.
    static func mentionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            let precedingIsBoundary: Bool
            if at == text.startIndex {
                precedingIsBoundary = true
            } else {
                let previous = text[text.index(before: at)]
                precedingIsBoundary = previous.isWhitespace || previous == "(" || previous == "\u{201C}"
            }
            let afterAt = text.index(after: at)
            index = afterAt
            guard precedingIsBoundary, afterAt < text.endIndex else { continue }
            let rest = text[afterAt...]
            let end = rest.rangeOfCharacter(from: terminators)?.lowerBound ?? rest.endIndex
            let token = String(rest[..<end])
            // A bare "@" is someone typing, not a reference.
            if !token.isEmpty { tokens.append(token) }
            index = end
        }
        return tokens
    }

    /// Resolves tokens against the project. Unresolved tokens come back separately rather than
    /// being dropped: silently ignoring a typo'd path is how you get an agent confidently
    /// answering about a file nobody meant.
    static func resolve(text: String, projectRoot: URL) -> (mentions: [FileMention], unresolved: [String]) {
        var mentions: [FileMention] = []
        var unresolved: [String] = []
        var seen = Set<String>()

        for token in mentionTokens(in: text) {
            let cleaned = token.hasSuffix("/") ? String(token.dropLast()) : token
            guard !cleaned.isEmpty else { continue }
            // Containment, not string trust: `@../../etc/passwd` must not resolve, and this is
            // the same rule `ProjectFileAccess` applies to tool arguments.
            //
            // `appendingPathComponent`, not `URL(fileURLWithPath:relativeTo:)`: the latter
            // produces a URL that keeps a *base*, and its `path` then reports only the relative
            // part — which silently defeated the prefix check below and made every valid mention
            // look out-of-project. Caught by these tests, not by reading.
            let candidate: URL = cleaned.hasPrefix("/")
                ? URL(fileURLWithPath: cleaned).standardizedFileURL
                : projectRoot.appendingPathComponent(cleaned).standardizedFileURL
            let rootPath = projectRoot.standardizedFileURL.path
            guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
                unresolved.append(token)
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                unresolved.append(token)
                continue
            }
            let relativePath = String(candidate.path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            guard seen.insert(relativePath).inserted else { continue }
            mentions.append(FileMention(raw: token, relativePath: relativePath, isDirectory: isDirectory.boolValue))
        }
        return (mentions, unresolved)
    }

    /// The note appended to a message that carries mentions — paths and nothing else.
    ///
    /// Says "read them if you need them" rather than "here they are," which is the whole design:
    /// the agent decides whether a mentioned file is worth a round trip, and a mention that turns
    /// out to be irrelevant costs nothing.
    static func contextNote(mentions: [FileMention], unresolved: [String]) -> String? {
        guard !mentions.isEmpty || !unresolved.isEmpty else { return nil }
        var lines: [String] = []
        if !mentions.isEmpty {
            lines.append("The user referenced these project paths with @. Read the ones you need with read_file or list_files — their contents are not included here:")
            for mention in mentions {
                lines.append("- \(mention.relativePath)\(mention.isDirectory ? "/ (directory)" : "")")
            }
        }
        if !unresolved.isEmpty {
            // Told plainly so the agent asks instead of inventing a plausible file.
            lines.append("These @ references don't exist in the project: \(unresolved.joined(separator: ", ")). Ask the user what they meant rather than guessing.")
        }
        return lines.joined(separator: "\n")
    }
}

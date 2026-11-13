import Foundation

/// Changes as a review queue (SIDE_RFC_SESSIONS.md, phase 4): a checkout's uncommitted changes,
/// hunk by hunk, grouped by who wrote them: each agent session, then you, then what no write
/// Side saw explains. Built from the diff's text and the files' attribution; pure, so it's
/// tested without a window.
struct ReviewQueue: Equatable {
    /// One hunk of one file, as `git diff` wrote it.
    struct Hunk: Equatable {
        let path: String
        /// The file's header lines (`diff --git`, `---`, `+++`, …), shared by its hunks.
        let fileHeader: String
        /// From its `@@` line on.
        let text: String
        /// New-side line numbers the hunk adds.
        let addedLines: [Int]
        let added: Int
        let removed: Int
    }

    struct Group: Equatable {
        let author: Author
        var hunks: [Hunk]
        var added: Int { hunks.reduce(0) { $0 + $1.added } }
        var removed: Int { hunks.reduce(0) { $0 + $1.removed } }
        /// Its files, in the diff's order.
        var paths: [String] {
            var seen: [String] = []
            for hunk in hunks where !seen.contains(hunk.path) { seen.append(hunk.path) }
            return seen
        }
        /// "Fix the flaky login test", "Your edits", "Unknown".
        var title: String {
            switch author.kind {
            case .session: return author.request ?? author.name
            case .you: return "Your edits"
            case .shared: return "Several sessions"
            case .unknown: return "Not attributed"
            }
        }

        /// The group's hunks as one `git diff`: each file's header once, then its hunks.
        var diffText: String {
            var text = ""
            var lastPath: String?
            for hunk in hunks {
                if hunk.path != lastPath {
                    if !text.isEmpty { text += "\n" }
                    text += hunk.fileHeader
                    lastPath = hunk.path
                }
                text += "\n" + hunk.text
            }
            return text
        }
    }

    var groups: [Group] = []

    /// The hunks in `diff` (full `git diff` text, files with `diff --git` headers).
    static func hunks(in diff: String) -> [Hunk] {
        var result: [Hunk] = []
        for block in diff.components(separatedBy: "\ndiff --git ").enumerated().map({ $0.offset == 0 ? $0.element : "diff --git " + $0.element }) {
            let lines = block.components(separatedBy: "\n")
            guard let first = lines.firstIndex(where: { $0.hasPrefix("@@") }) else { continue }
            let header = lines[..<first].joined(separator: "\n")
            let path = Self.path(fromHeader: Array(lines[..<first]))
            var start = first
            while start < lines.count {
                var end = start + 1
                while end < lines.count, !lines[end].hasPrefix("@@") { end += 1 }
                let text = lines[start..<end].joined(separator: "\n")
                let parsed = UnifiedDiff.parseHunks(text).first
                let added = parsed?.lines.filter { $0.kind == .added } ?? []
                result.append(Hunk(path: path, fileHeader: header, text: text, addedLines: added.compactMap(\.newNumber),
                                   added: added.count, removed: parsed?.lines.filter { $0.kind == .removed }.count ?? 0))
                start = end
            }
        }
        return result
    }

    /// `+++ b/path`, else `diff --git a/x b/path`.
    static func path(fromHeader lines: [String]) -> String {
        if let plus = lines.first(where: { $0.hasPrefix("+++ ") }), !plus.hasSuffix("/dev/null") {
            let name = String(plus.dropFirst(4))
            return name.hasPrefix("b/") ? String(name.dropFirst(2)) : name
        }
        if let minus = lines.first(where: { $0.hasPrefix("--- ") }), !minus.hasSuffix("/dev/null") {
            let name = String(minus.dropFirst(4))
            return name.hasPrefix("a/") ? String(name.dropFirst(2)) : name
        }
        let parts = (lines.first ?? "").components(separatedBy: " b/")
        return parts.count > 1 ? parts.last! : ""
    }

    /// Groups `diff`'s hunks by author: a hunk is the author's who wrote most of its new lines;
    /// one that only removes lines, or adds lines no write Side saw, isn't attributed. Sessions
    /// first (in order of first appearance), then you, then several sessions, then the rest.
    static func build(diff: String, owners: (String) -> [Author?]) -> ReviewQueue {
        var ownersByPath: [String: [Author?]] = [:]
        var groups: [Group] = []
        for hunk in hunks(in: diff) {
            let lineOwners = ownersByPath[hunk.path] ?? owners(hunk.path)
            ownersByPath[hunk.path] = lineOwners
            var counts: [Author: Int] = [:]
            for line in hunk.addedLines where lineOwners.indices.contains(line - 1) {
                if let owner = lineOwners[line - 1], owner.kind != .unknown { counts[owner, default: 0] += 1 }
            }
            // Most lines wins; a tie goes to a session over anyone else.
            let author = counts.sorted { a, b in
                a.value != b.value ? a.value > b.value : (a.key.kind == .session && b.key.kind != .session)
            }.first?.key ?? .unknown
            if let index = groups.firstIndex(where: { $0.author == author }) {
                groups[index].hunks.append(hunk)
            } else {
                groups.append(Group(author: author, hunks: [hunk]))
            }
        }
        let order: [Author.Kind: Int] = [.session: 0, .you: 1, .shared: 2, .unknown: 3]
        let sorted = groups.enumerated().sorted { (order[$0.element.author.kind]!, $0.offset) < (order[$1.element.author.kind]!, $1.offset) }.map(\.element)
        return ReviewQueue(groups: sorted)
    }
}

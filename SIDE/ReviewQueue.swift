import Foundation
import SideAgents

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

        /// What an approval is kept under: the file and the hunk's lines, not its numbers, so it
        /// holds while other hunks move it and goes when it changes.
        var key: String {
            let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            return path + "\u{0}" + String(Attribution.hash(body), radix: 16)
        }
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

/// Which hunks have been approved, per checkout, kept in its git dir beside the attribution
/// (`side/review.json`): never in the project's files. An approval is for a hunk's exact lines.
final class ReviewApprovals: @unchecked Sendable {
    static let shared = ReviewApprovals()
    private let lock = NSLock()
    private var cache: [String: Set<String>] = [:]

    private func store(_ checkout: Attribution.Checkout) -> URL { checkout.gitDirectory.appendingPathComponent("side/review.json") }

    func approved(in root: URL) -> Set<String> {
        guard let checkout = Attribution.checkout(of: root.appendingPathComponent("x")) else { return [] }
        lock.lock(); defer { lock.unlock() }
        return load(checkout)
    }

    func set(_ keys: [String], approved: Bool, in root: URL) {
        guard let checkout = Attribution.checkout(of: root.appendingPathComponent("x")) else { return }
        lock.lock(); defer { lock.unlock() }
        var set = load(checkout)
        if approved { set.formUnion(keys) } else { set.subtract(keys) }
        cache[checkout.gitDirectory.path] = set
        let url = store(checkout)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(set.sorted()) { try? data.write(to: url, options: .atomic) }
    }

    /// Approvals whose hunks are gone (committed, discarded, rewritten) let go of.
    func keep(only live: Set<String>, in root: URL) {
        guard let checkout = Attribution.checkout(of: root.appendingPathComponent("x")) else { return }
        lock.lock()
        let stale = load(checkout).subtracting(live)
        lock.unlock()
        if !stale.isEmpty { set(Array(stale), approved: false, in: root) }
    }

    private func load(_ checkout: Attribution.Checkout) -> Set<String> {
        if let cached = cache[checkout.gitDirectory.path] { return cached }
        let keys = (try? Data(contentsOf: store(checkout))).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        cache[checkout.gitDirectory.path] = Set(keys)
        return Set(keys)
    }
}

/// What the queue does to a checkout: commit its approved hunks, discard a session's.
enum ReviewGit {
    enum Failure: Error, Equatable {
        /// Something else is staged: a commit now would take it too.
        case otherChangesStaged([String])
        /// Lines in these hunks are someone else's, written after: discarding would take theirs.
        case othersBuildOnIt([String])
        case git(String)

        var message: String {
            switch self {
            case .otherChangesStaged(let paths):
                return "Other changes are staged (\(paths.prefix(3).joined(separator: ", "))\(paths.count > 3 ? ", \u{2026}" : "")). Commit or unstage them first, so this commit holds only what you approved."
            case .othersBuildOnIt(let names):
                return "\(names.joined(separator: " and ")) changed lines inside these changes since. Discarding them would take those too."
            case .git(let output): return output.isEmpty ? "git couldn\u{2019}t do it." : output
            }
        }
    }

    /// The hunks as a patch git can apply: each file's header once, then its hunks.
    static func patch(_ hunks: [ReviewQueue.Hunk]) -> String {
        ReviewQueue.Group(author: .unknown, hunks: hunks).diffText + "\n"
    }

    /// Stages exactly `hunks` and commits them with `message` (the repository's hooks and
    /// signing apply, as with any commit). Refused when anything else is staged; what it staged
    /// is taken back out if the commit fails.
    static func commit(_ hunks: [ReviewQueue.Hunk], message: String, cwd: String) -> Result<String, Failure> {
        let staged = GitPaths.runGit(["diff", "--cached", "--name-only"], cwd: cwd)
        guard staged.success else { return .failure(.git(staged.output)) }
        let already = staged.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard already.isEmpty else { return .failure(.otherChangesStaged(already)) }
        let paths = Array(Set(hunks.map(\.path))).sorted()
        switch apply(hunks, ["--cached"], cwd: cwd) {
        case .failure(let failure): return .failure(failure)
        case .success: break
        }
        let committed = GitPaths.runGit(["commit", "-q", "-m", message], cwd: cwd)
        guard committed.success else {
            _ = GitPaths.runGit(["reset", "-q", "--"] + paths, cwd: cwd)
            return .failure(.git(committed.output))
        }
        return .success(GitPaths.runGit(["rev-parse", "--short", "HEAD"], cwd: cwd).output)
    }

    /// Takes `hunks` out of the working tree, as if never written. `owners` says who wrote each
    /// file's lines now: refused when any added line in them is someone else's than `author`.
    static func discard(_ hunks: [ReviewQueue.Hunk], author: Author, owners: (String) -> [Author?], cwd: String) -> Result<Void, Failure> {
        var others: [String] = []
        for hunk in hunks {
            let lineOwners = owners(hunk.path)
            for line in hunk.addedLines where lineOwners.indices.contains(line - 1) {
                guard let owner = lineOwners[line - 1], owner != author else { continue }
                if !others.contains(owner.name) { others.append(owner.name) }
            }
        }
        guard others.isEmpty else { return .failure(.othersBuildOnIt(others)) }
        return apply(hunks, ["-R"], cwd: cwd)
    }

    private static func apply(_ hunks: [ReviewQueue.Hunk], _ options: [String], cwd: String) -> Result<Void, Failure> {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("side-review-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: file) }
        do { try patch(hunks).write(to: file, atomically: true, encoding: .utf8) } catch { return .failure(.git(error.localizedDescription)) }
        let applied = GitPaths.runGit(["apply", "--whitespace=nowarn"] + options + [file.path], cwd: cwd)
        return applied.success ? .success(()) : .failure(.git(applied.output))
    }

    /// The commit message drafted from what was asked: its first line, as the subject.
    static func draftMessage(for group: ReviewQueue.Group) -> String {
        guard group.author.kind == .session, let request = group.author.request else { return "" }
        let line = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "" }
        let subject = line.count > 72 ? String(line.prefix(71)) + "\u{2026}" : line
        return subject.prefix(1).uppercased() + subject.dropFirst()
    }
}

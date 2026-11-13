import Foundation
import SideAgents

/// Who wrote each changed line (SIDE_RFC_SESSIONS.md, phase 3): an agent's session, you in
/// Side's editor, several sessions at once, or nobody Side knows of.
///
/// Each checkout keeps its own record in its git folder (`<git dir>/side/attribution.json`,
/// a worktree's own git dir for a worktree): never in the project's files, never committed. A
/// file's record is its lines as hashes and each line's author, as of the last thing that wrote
/// it. A new write is laid over it with a line diff: lines that didn't change keep their author;
/// changed and new ones get the writer when they're what the writer says it wrote, and Unknown
/// when they aren't (something else wrote them in between). Nothing claims more than it knows.
struct Author: Codable, Hashable {
    enum Kind: String, Codable {
        /// An agent's session, from its hooks.
        case session
        /// The person, saving in Side's editor (or typing, not yet saved).
        case you
        /// Changed by a shell command while more than one session was working in the checkout.
        case shared
        case unknown
    }
    var kind: Kind
    var sessionID: String?
    var agent: String?
    /// What the session was asked when it wrote this, the first line.
    var request: String?

    static let you = Author(kind: .you)
    static let unknown = Author(kind: .unknown)

    /// "Claude Code", "You", "Several sessions", "Unknown".
    var name: String {
        switch kind {
        case .session: return agent.map(ProgramMarks.displayName) ?? "An agent"
        case .you: return "You"
        case .shared: return "Several sessions"
        case .unknown: return "Unknown"
        }
    }
}

/// One file's record: its lines as of the last write Side saw, and each line's author.
struct FileAttribution: Codable, Equatable {
    var lineHashes: [UInt64]
    /// Index into the checkout's authors, per line; nil for a line no write touched since the
    /// record began (as it was in HEAD).
    var owners: [Int?]

    /// `current` laid over this record: unchanged lines keep their owners; inserted lines get
    /// `owner(lineText)`.
    func updated(to current: [String], owner: (String) -> Int?) -> FileAttribution {
        let hashes = current.map(Attribution.hash)
        let difference = hashes.difference(from: lineHashes)
        var owners = self.owners
        // Removals by their offsets in the old lines, highest first; then insertions by their
        // offsets in the new ones, lowest first.
        func offset(_ change: CollectionDifference<UInt64>.Change) -> Int {
            switch change {
            case .insert(let offset, _, _), .remove(let offset, _, _): return offset
            }
        }
        let removals = difference.removals.map(offset).sorted(by: >)
        for offset in removals where owners.indices.contains(offset) { owners.remove(at: offset) }
        let insertions = difference.insertions.map(offset).sorted()
        for offset in insertions { owners.insert(owner(current[offset]), at: min(offset, owners.count)) }
        if owners.count != hashes.count { owners = Array(owners.prefix(hashes.count)) + Array(repeating: nil, count: max(0, hashes.count - owners.count)) }
        return FileAttribution(lineHashes: hashes, owners: owners)
    }
}

struct CheckoutAttribution: Codable, Equatable {
    var authors: [Author] = []
    /// By path relative to the checkout's root.
    var files: [String: FileAttribution] = [:]

    mutating func index(of author: Author) -> Int {
        if let index = authors.firstIndex(of: author) { return index }
        authors.append(author)
        return authors.count - 1
    }
}

/// The records, read and written on a queue of their own.
final class Attribution: @unchecked Sendable {
    static let shared = Attribution()
    static let didChangeNotification = Notification.Name("SideAttributionDidChange")

    private let queue = DispatchQueue(label: "side.attribution")
    private var records: [String: CheckoutAttribution] = [:]

    /// FNV-1a: stable across launches (Swift's `Hasher` isn't).
    static func hash(_ line: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in line.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return value
    }

    static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    // MARK: Where a file's checkout and record live

    struct Checkout: Equatable {
        let root: URL
        let gitDirectory: URL
        var store: URL { gitDirectory.appendingPathComponent("side/attribution.json") }
    }

    /// The checkout a file is in: the nearest folder above it with a `.git` (a folder, or a
    /// worktree's file naming its git dir). Read from disk, without running git.
    static func checkout(of file: URL) -> Checkout? {
        var folder = file.deletingLastPathComponent().standardizedFileURL
        while folder.path != "/" {
            let dotGit = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return Checkout(root: folder, gitDirectory: dotGit) }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir: ") }) else { return nil }
                let path = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
                let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path).standardizedFileURL
                return Checkout(root: folder, gitDirectory: gitDir)
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    static func relativePath(_ file: URL, in checkout: Checkout) -> String? {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        let root = checkout.root.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: Recording

    /// An agent wrote `file`: the lines it says it wrote (`written`) are its; anything else
    /// that changed since the record is Unknown. `written` nil: everything that changed is the
    /// writer's (a whole file written, a save).
    func record(_ file: URL, author: Author, written: [String]?, then: (() -> Void)? = nil) {
        queue.async { [self] in
            update(file, author: author, written: written)
            then?()
        }
    }

    /// The person saved `text` to `file` in Side's editor.
    func recordSave(_ file: URL, text: String) {
        queue.async { [self] in update(file, author: .you, written: nil, text: text) }
    }

    /// Runs `body` after everything recorded so far (tests).
    func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    private func update(_ file: URL, author: Author, written: [String]?, text: String? = nil) {
        guard let checkout = Self.checkout(of: file), let path = Self.relativePath(file, in: checkout),
              let current = text ?? (try? String(contentsOf: file, encoding: .utf8)) else { return }
        var record = load(checkout)
        let lines = Self.lines(current)
        let base = record.files[path] ?? Self.baseline(path, in: checkout)
        let writtenSet = written.map { Set($0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
        let writer = record.index(of: author)
        let unknown = record.index(of: .unknown)
        let updated = base.updated(to: lines) { line in
            guard let writtenSet else { return writer }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A blank line inside what was written is the writer's too; one it didn't write is no one's.
            return trimmed.isEmpty || writtenSet.contains(trimmed) ? writer : unknown
        }
        record.files[path] = updated
        save(record, to: checkout)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
    }

    /// A file with no record yet starts from HEAD's version, its lines no one's: only what
    /// changes from here on is anyone's. A file HEAD doesn't have starts empty.
    private static func baseline(_ path: String, in checkout: Checkout) -> FileAttribution {
        let result = GitPaths.runGitRaw(["show", "HEAD:\(path)"], cwd: checkout.root.path)
        let lines = result.success ? Self.lines(result.output) : []
        return FileAttribution(lineHashes: lines.map(hash), owners: Array(repeating: nil, count: lines.count))
    }

    // MARK: Reading

    /// Who wrote lines `range` (one-based, inclusive) of `file` as it reads now (`text`, the
    /// editor's buffer, unsaved typing included, which is yours). Each author once, in order of
    /// first appearance; lines no write touched aren't counted.
    func authors(of file: URL, text: String, lines range: ClosedRange<Int>) -> [Author] {
        queue.sync {
            guard let checkout = Self.checkout(of: file), let path = Self.relativePath(file, in: checkout) else { return [] }
            var record = load(checkout)
            guard let stored = record.files[path] else { return [] }
            let you = record.index(of: .you)
            let now = stored.updated(to: Self.lines(text)) { _ in you }
            var seen: [Author] = []
            for line in range where now.owners.indices.contains(line - 1) {
                guard let owner = now.owners[line - 1], record.authors.indices.contains(owner) else { continue }
                let author = record.authors[owner]
                if !seen.contains(author) { seen.append(author) }
            }
            return seen
        }
    }

    /// Each line's author in `file` as it reads now (`text`), nil where no write touched it.
    /// Lines typed in the buffer since the last write are yours.
    func owners(of file: URL, text: String) -> [Author?] {
        queue.sync {
            let lines = Self.lines(text)
            guard let checkout = Self.checkout(of: file), let path = Self.relativePath(file, in: checkout) else { return Array(repeating: nil, count: lines.count) }
            var record = load(checkout)
            guard let stored = record.files[path] else { return Array(repeating: nil, count: lines.count) }
            let you = record.index(of: .you)
            let authors = record.authors
            return stored.updated(to: lines) { _ in you }.owners.map { owner in
                owner.flatMap { $0 == you ? Author.you : authors.indices.contains($0) ? authors[$0] : nil }
            }
        }
    }

    // MARK: Store

    private func load(_ checkout: Checkout) -> CheckoutAttribution {
        if let cached = records[checkout.store.path] { return cached }
        let record = (try? Data(contentsOf: checkout.store)).flatMap { try? JSONDecoder().decode(CheckoutAttribution.self, from: $0) } ?? CheckoutAttribution()
        records[checkout.store.path] = record
        return record
    }

    private func save(_ record: CheckoutAttribution, to checkout: Checkout) {
        records[checkout.store.path] = record
        try? FileManager.default.createDirectory(at: checkout.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: checkout.store, options: .atomic) }
    }
}

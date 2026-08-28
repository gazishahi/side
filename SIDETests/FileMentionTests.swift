import XCTest
@testable import Side

final class FileMentionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mentions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data("export const a = 1\n".utf8).write(to: root.appendingPathComponent("src/greeter.ts"))
        try Data("readme\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("deep\n".utf8).write(to: root.appendingPathComponent("src/deep/nested.swift"))
        try Data("vendored\n".utf8).write(to: root.appendingPathComponent("node_modules/pkg/index.js"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Token scanning

    func testFindsMentionsAndIgnoresEmailAddresses() {
        let tokens = FileMentionResolver.mentionTokens(in: "look at @src/greeter.ts and mail me@example.com")
        // An email's `@` has a non-boundary character before it — treating it as a file
        // reference would make every address in a message a broken mention.
        XCTAssertEqual(tokens, ["src/greeter.ts"])
    }

    func testPunctuationAfterAMentionStaysPunctuation() {
        XCTAssertEqual(
            FileMentionResolver.mentionTokens(in: "compare @a.swift, @b.swift; then stop"),
            ["a.swift", "b.swift"]
        )
        XCTAssertEqual(FileMentionResolver.mentionTokens(in: "check @README.md?"), ["README.md"])
        XCTAssertEqual(FileMentionResolver.mentionTokens(in: "(see @src/greeter.ts)"), ["src/greeter.ts"])
    }

    func testABareAtIsNotAMention() {
        XCTAssertTrue(FileMentionResolver.mentionTokens(in: "what does @ mean").isEmpty)
        XCTAssertTrue(FileMentionResolver.mentionTokens(in: "@").isEmpty)
    }

    // MARK: - Resolution

    func testResolvesRealPathsAndReportsTypos() {
        let result = FileMentionResolver.resolve(
            text: "explain @src/greeter.ts and @src/nope.ts", projectRoot: root
        )
        XCTAssertEqual(result.mentions.map(\.relativePath), ["src/greeter.ts"])
        // Reported, not dropped: silently ignoring a typo is how an agent ends up confidently
        // answering about a file nobody meant.
        XCTAssertEqual(result.unresolved, ["src/nope.ts"])
    }

    func testDirectoriesResolveAndAreLabelled() {
        let result = FileMentionResolver.resolve(text: "look through @src/deep/", projectRoot: root)
        XCTAssertEqual(result.mentions.first?.relativePath, "src/deep")
        XCTAssertEqual(result.mentions.first?.isDirectory, true)
    }

    func testEscapingTheProjectRootIsRefused() {
        let result = FileMentionResolver.resolve(
            text: "read @../../etc/passwd and @/etc/hosts", projectRoot: root
        )
        // Same containment rule the tools apply — a mention must not become a path traversal.
        XCTAssertTrue(result.mentions.isEmpty, "resolved: \(result.mentions)")
        XCTAssertEqual(result.unresolved.count, 2)
    }

    func testRepeatedMentionsAppearOnce() {
        let result = FileMentionResolver.resolve(
            text: "@README.md is like @README.md", projectRoot: root
        )
        XCTAssertEqual(result.mentions.count, 1)
    }

    // MARK: - What actually gets sent

    func testTheNoteCarriesPathsAndNotFileContents() throws {
        let result = FileMentionResolver.resolve(text: "summarize @src/greeter.ts", projectRoot: root)
        let note = try XCTUnwrap(FileMentionResolver.contextNote(mentions: result.mentions, unresolved: []))

        XCTAssertTrue(note.contains("src/greeter.ts"), note)
        // The whole design decision, pinned: inlining content would persist a copy in the
        // session file and re-send it on every later turn for the rest of the track's life.
        XCTAssertFalse(note.contains("export const a = 1"), note)
        XCTAssertTrue(note.lowercased().contains("read_file"), "the agent has to be told how to get the contents")
    }

    func testUnresolvedMentionsTellTheAgentToAskRatherThanGuess() throws {
        let note = try XCTUnwrap(FileMentionResolver.contextNote(mentions: [], unresolved: ["src/nope.ts"]))
        XCTAssertTrue(note.contains("src/nope.ts"))
        XCTAssertTrue(note.lowercased().contains("ask the user"), note)
    }

    func testNoMentionsMeansNoNoteAtAll() {
        XCTAssertNil(FileMentionResolver.contextNote(mentions: [], unresolved: []))
    }

    // MARK: - Completion index

    func testIndexSkipsVendoredDirectoriesAndFuzzyMatches() {
        let index = ProjectFileIndex()
        let done = expectation(description: "indexed")
        index.refresh(root: root) { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertTrue(index.relativePaths.contains("src/greeter.ts"))
        // node_modules is noise in a completion list, and matches what the file tree hides.
        XCTAssertFalse(index.relativePaths.contains { $0.hasPrefix("node_modules") }, "\(index.relativePaths)")

        // Same scorer as Quick Open, so initials work here too.
        XCTAssertEqual(index.matches(for: "greeter").first, "src/greeter.ts")
        XCTAssertTrue(index.matches(for: "sdn").contains("src/deep/nested.swift"))
    }
}

/// The crash this feature first shipped with is gone by construction rather than by guard:
/// completion no longer calls `NSTextView.complete(_:)` at all, so there is no
/// insert-during-textDidChange path to recurse through. `MentionCompletionPopup` only displays;
/// text changes exclusively when a row is accepted. See that file's note for the full account.

/// Covers the highlighting/click surface: which spans of text get styled as mentions, and the
/// empty-query behaviour behind a bare `@`.
final class MentionPresentationTests: XCTestCase {

    private func highlighted(_ text: String) -> [String] {
        let ns = text as NSString
        return FileMentionResolver.tokenRanges(in: text).map { ns.substring(with: $0) }
    }

    func testHighlightsMentionsAndNothingElse() {
        XCTAssertEqual(
            highlighted("look at @src/greeter.ts then @README.md"),
            ["@src/greeter.ts", "@README.md"]
        )
        XCTAssertEqual(highlighted("mail me@example.com about it"), [])
        XCTAssertEqual(highlighted("what does @ mean"), [])
    }

    func testHighlightRangesAgreeWithWhatGetsSent() {
        // Two code paths read the same text — one decides what's *shown* as a mention, the other
        // what's *sent*. If they disagree, the user sees a styled reference the agent was never
        // told about (or the reverse).
        let text = "compare @a.swift, @b/c.swift; ignore me@example.com and a bare @"
        XCTAssertEqual(
            highlighted(text).map { String($0.dropFirst()) },
            FileMentionResolver.mentionTokens(in: text)
        )
    }

    func testHighlightsATypoTheSameAsARealPath() throws {
        // Styling reflects "Side read this as a mention," so a wrong path has to look like one
        // and fail visibly rather than blend into the sentence.
        XCTAssertEqual(highlighted("check @src/nope.ts"), ["@src/nope.ts"])
    }

    func testBareAtOffersShallowPathsFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bare-at-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("TOP.md"))
        try Data("x".utf8).write(to: root.appendingPathComponent("a/mid.swift"))
        try Data("x".utf8).write(to: root.appendingPathComponent("a/b/c/deep.swift"))

        let index = ProjectFileIndex()
        let done = expectation(description: "indexed")
        index.refresh(root: root) { done.fulfill() }
        wait(for: [done], timeout: 5)

        // Filesystem enumeration order would look arbitrary; a bare `@` should open on the
        // project's top level.
        XCTAssertEqual(index.matches(for: "").first, "TOP.md")
        XCTAssertEqual(index.matches(for: "").last, "a/b/c/deep.swift")
    }
}

/// The note must never be persisted into the user's turn — a stored note appears in the bubble
/// when the transcript is rebuilt from disk (the live and reloaded transcripts disagreed, which
/// is how this was found) and freezes resolution at send time.
final class MentionNoteHandlingTests: XCTestCase {

    func testPunctuationOnlyTokensAreNotMentions() {
        // "with @." in prose is punctuation. An early version styled it as a file reference,
        // which made the highlighting look broken.
        XCTAssertTrue(FileMentionResolver.tokenRanges(in: "referenced with @.").isEmpty)
        XCTAssertTrue(FileMentionResolver.mentionTokens(in: "referenced with @.").isEmpty)
        XCTAssertTrue(FileMentionResolver.tokenRanges(in: "a @- b").isEmpty)
        // …but a real dotfile still counts.
        XCTAssertEqual(FileMentionResolver.mentionTokens(in: "see @.gitignore"), [".gitignore"])
    }

    func testResolutionAndHighlightingAgreeAboutPunctuation() {
        let text = "check @. and @src/a.swift plus @-"
        let ns = text as NSString
        XCTAssertEqual(
            FileMentionResolver.tokenRanges(in: text).map { String(ns.substring(with: $0).dropFirst()) },
            FileMentionResolver.mentionTokens(in: text)
        )
    }
}

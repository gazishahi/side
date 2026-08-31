import XCTest
@testable import Side

/// Reading fields out of tool-call arguments that haven't finished arriving. Everything here is
/// about one hazard: a preview built from a fragment must never claim something the completed
/// call won't say. A path that is still being written could name a different file; a half-decoded
/// escape could show a character the model didn't send.
final class StreamingJSONFieldsTests: XCTestCase {

    private func extract(_ text: String, _ keys: Set<String>) -> StreamingJSONFields.Partial {
        StreamingJSONFields.extract(text, keys: keys)
    }

    func testACompletedValueIsMarkedComplete() {
        let partial = extract(#"{"path": "a.swift", "content": "hi"}"#, ["path", "content"])
        XCTAssertEqual(partial.completedValue(for: "path"), "a.swift")
        XCTAssertEqual(partial.completedValue(for: "content"), "hi")
    }

    func testAValueStillArrivingIsReadableButNotComplete() {
        let partial = extract(#"{"path": "a.swift", "content": "func hi("#, ["path", "content"])
        XCTAssertEqual(partial.completedValue(for: "path"), "a.swift")
        XCTAssertEqual(partial.value(for: "content"), "func hi(")
        // The distinction the whole preview rests on: displayable, not actionable.
        XCTAssertNil(partial.completedValue(for: "content"))
    }

    func testAHalfWrittenPathIsNeverReportedAsComplete() {
        // "src/ma" could become src/main.swift or src/mathUtils.ts. Naming the wrong file in the
        // card header is worse than naming none.
        let partial = extract(#"{"path": "src/ma"#, ["path"])
        XCTAssertNil(partial.completedValue(for: "path"))
    }

    func testAnUnterminatedKeyYieldsNothing() {
        let partial = extract(#"{"path": "a.swift", "cont"#, ["path", "content"])
        XCTAssertEqual(partial.completedValue(for: "path"), "a.swift")
        XCTAssertNil(partial.value(for: "content"))
    }

    func testEscapesAreDecoded() {
        let partial = extract(#"{"content": "line\none\t\"quoted\"\\done"}"#, ["content"])
        XCTAssertEqual(partial.completedValue(for: "content"), "line\none\t\"quoted\"\\done")
    }

    func testATrailingBackslashIsDroppedRatherThanGuessed() {
        // The fragment ended mid-escape. It could be \n, \t, or \". Emitting the backslash itself
        // would show a character the model never sent.
        let partial = extract("{\"content\": \"abc\\", ["content"])
        XCTAssertEqual(partial.value(for: "content"), "abc")
        XCTAssertNil(partial.completedValue(for: "content"))
    }

    func testAnIncompleteUnicodeEscapeIsDropped() {
        let partial = extract(#"{"content": "caf\u00"#, ["content"])
        XCTAssertEqual(partial.value(for: "content"), "caf")
    }

    func testACompleteUnicodeEscapeIsDecoded() {
        let partial = extract(#"{"content": "café"}"#, ["content"])
        XCTAssertEqual(partial.completedValue(for: "content"), "café")
    }

    func testASurrogatePairIsDecodedAsOneScalar() {
        let partial = extract(#"{"content": "🚀 ship"}"#, ["content"])
        XCTAssertEqual(partial.completedValue(for: "content"), "🚀 ship")
    }

    func testALoneHighSurrogateAwaitingItsPairIsDropped() {
        let partial = extract(#"{"content": "go \ud83d"#, ["content"])
        XCTAssertEqual(partial.value(for: "content"), "go ")
    }

    func testNumbersAndBooleansAreSteppedOverSoLaterKeysAreReachable() {
        let partial = extract(#"{"line": 42, "replace_all": true, "path": "a.swift"}"#, ["path"])
        XCTAssertEqual(partial.completedValue(for: "path"), "a.swift")
    }

    func testNestedContainersAreSteppedOver() {
        let partial = extract(#"{"opts": {"a": [1, 2], "b": "}"}, "path": "a.swift"}"#, ["path"])
        XCTAssertEqual(partial.completedValue(for: "path"), "a.swift")
    }

    func testNonObjectInputYieldsNothing() {
        XCTAssertTrue(extract("", ["path"]).values.isEmpty)
        XCTAssertTrue(extract("[1,2]", ["path"]).values.isEmpty)
        XCTAssertTrue(extract("not json at all", ["path"]).values.isEmpty)
    }

    func testTheFinalTextAgreesWithARealJSONParse() throws {
        let object: [String: Any] = ["path": "src/a b/ünïcode\"quote\".ts", "content": "let x = 1\n\tlet y = \"2\"\n"]
        let data = try JSONSerialization.data(withJSONObject: object)
        let partial = extract(String(data: data, encoding: .utf8)!, ["path", "content"])
        XCTAssertEqual(partial.completedValue(for: "path"), object["path"] as? String)
        XCTAssertEqual(partial.completedValue(for: "content"), object["content"] as? String)
    }

    func testEveryPrefixOfARealCallIsEitherCorrectOrSilent() throws {
        // The property that matters, checked at every possible split point: whatever the extractor
        // reports for a prefix must be a prefix of the truth, and anything it calls *complete*
        // must equal the truth exactly.
        let object: [String: Any] = ["path": "src/mathUtils.ts", "content": "export const add = (a: number, b: number) => a + b\n"]
        let data = try JSONSerialization.data(withJSONObject: object)
        let full = String(data: data, encoding: .utf8)!
        let truth = ["path": object["path"] as! String, "content": object["content"] as! String]
        for length in 0...full.count {
            let prefix = String(full.prefix(length))
            let partial = extract(prefix, ["path", "content"])
            for (key, expected) in truth {
                guard let seen = partial.value(for: key) else { continue }
                XCTAssertTrue(expected.hasPrefix(seen), "at \(length): \(key) = \(seen)")
                if partial.complete.contains(key) { XCTAssertEqual(seen, expected, "at \(length): \(key)") }
            }
        }
    }
}

/// What the card shows while the model writes.
final class StreamingEditPreviewTests: XCTestCase {

    func testWriteFilePreviewsItsContent() {
        let draft = StreamingEditPreview.draft(toolName: "write_file", partialJSON: #"{"path": "a.ts", "content": "let x"#)
        XCTAssertEqual(draft?.path, "a.ts")
        XCTAssertEqual(draft?.body, "let x")
        XCTAssertEqual(draft?.isComplete, false)
    }

    func testEditFilePreviewsTheReplacementNotTheSearchText() {
        // old_string is text already visible in the file; new_string is the news.
        let json = #"{"path": "a.ts", "old_string": "const a = 1", "new_string": "const a = 2"#
        let draft = StreamingEditPreview.draft(toolName: "edit_file", partialJSON: json)
        XCTAssertEqual(draft?.body, "const a = 2")
    }

    func testEditFileIsCompleteOnlyWhenEveryFieldHasLanded() {
        let json = #"{"path": "a.ts", "old_string": "x", "new_string": "y"}"#
        XCTAssertEqual(StreamingEditPreview.draft(toolName: "edit_file", partialJSON: json)?.isComplete, true)
        let missing = #"{"path": "a.ts", "new_string": "y"}"#
        XCTAssertEqual(StreamingEditPreview.draft(toolName: "edit_file", partialJSON: missing)?.isComplete, false)
    }

    func testNothingIsPreviewedUntilThePathIsWhole() {
        XCTAssertNil(StreamingEditPreview.draft(toolName: "write_file", partialJSON: #"{"path": "a.t"#))
        XCTAssertNil(StreamingEditPreview.draft(toolName: "write_file", partialJSON: #"{"path": ""#))
        XCTAssertNil(StreamingEditPreview.draft(toolName: "write_file", partialJSON: "{"))
    }

    func testOnlyEditToolsArePreviewed() {
        // A preview card for `run_shell_command` or `read_file` would be a diff card for
        // something that isn't a diff.
        XCTAssertNil(StreamingEditPreview.draft(toolName: "read_file", partialJSON: #"{"path": "a.ts"}"#))
        XCTAssertNil(StreamingEditPreview.draft(toolName: "run_shell_command", partialJSON: #"{"path": "a.ts"}"#))
    }

    func testANewFilesPreviewLinesAreMarkedAsAdditions() {
        let text = StreamingEditPreview.previewDiffText(body: "a\nb", isNewFile: true)
        let hunks = UnifiedDiff.parseHunks(text)
        XCTAssertEqual(hunks.flatMap(\.lines).filter { $0.kind == .added }.count, 2)
    }

    func testAnExistingFilesPreviewLinesAreNeutral() {
        // Which of these lines are actually changes isn't knowable until the whole content is
        // here and can be diffed; tinting them green first would be a guess that then changes.
        let text = StreamingEditPreview.previewDiffText(body: "a\nb", isNewFile: false)
        let hunks = UnifiedDiff.parseHunks(text)
        XCTAssertTrue(hunks.flatMap(\.lines).allSatisfy { $0.kind == .context })
    }

    func testThePreviewParsesAsAHunkEvenWhenEmpty() {
        // A card that renders nothing is fine; one that crashes the parser is not.
        let text = StreamingEditPreview.previewDiffText(body: "", isNewFile: true)
        XCTAssertFalse(UnifiedDiff.parseHunks(text).isEmpty)
    }
}

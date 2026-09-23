import XCTest
@testable import Side
@testable import Heron

/// Reading fields out of tool-call arguments that haven't finished arriving. Everything here is
/// about one hazard: a preview built from a fragment must never claim something the completed
/// call won't say. A path that is still being written could name a different file; a half-decoded
/// escape could show a character the model didn't send.
final class StreamingJSONFieldsTests: XCTestCase {

    private func extract(_ text: String, _ keys: Set<String>) -> StreamingJSONFields.Partial {
        StreamingJSONFields.extract(text, keys: keys)
    }

    func testAValueIsCompleteOnlyOnceItsClosingQuoteHasArrived() {
        // The distinction the whole preview rests on: a value still arriving is displayable, not
        // actionable. "src/ma" could become src/main.swift or src/mathUtils.ts, and naming the
        // wrong file in the card header is worse than naming none. An unterminated key yields
        // nothing at all.
        let complete = extract(#"{"path": "a.swift", "content": "hi"}"#, ["path", "content"])
        XCTAssertEqual(complete.completedValue(for: "path"), "a.swift")
        XCTAssertEqual(complete.completedValue(for: "content"), "hi")

        let arriving = extract(#"{"path": "a.swift", "content": "func hi("#, ["path", "content"])
        XCTAssertEqual(arriving.completedValue(for: "path"), "a.swift")
        XCTAssertEqual(arriving.value(for: "content"), "func hi(")
        XCTAssertNil(arriving.completedValue(for: "content"))

        let halfPath = extract(#"{"path": "src/ma"#, ["path"])
        XCTAssertNil(halfPath.completedValue(for: "path"))

        let halfKey = extract(#"{"path": "a.swift", "cont"#, ["path", "content"])
        XCTAssertEqual(halfKey.completedValue(for: "path"), "a.swift")
        XCTAssertNil(halfKey.value(for: "content"))
    }

    func testEscapesAreDecodedAndHalfEscapesAreDroppedRatherThanGuessed() {
        // A fragment that ends mid-escape could be \n, \t, or \". Emitting the backslash itself
        // would show a character the model never sent; the same goes for a partial \uXXXX and a
        // lone high surrogate still awaiting its pair.
        let cases: [(name: String, json: String, value: String, completed: String?)] = [
            ("escapes decoded", #"{"content": "line\none\t\"quoted\"\\done"}"#, "line\none\t\"quoted\"\\done", "line\none\t\"quoted\"\\done"),
            ("trailing backslash dropped", "{\"content\": \"abc\\", "abc", nil),
            ("incomplete unicode escape dropped", #"{"content": "caf\u00"#, "caf", nil),
            ("complete unicode escape decoded", #"{"content": "café"}"#, "café", "café"),
            ("surrogate pair is one scalar", #"{"content": "🚀 ship"}"#, "🚀 ship", "🚀 ship"),
            ("lone high surrogate dropped", #"{"content": "go \ud83d"#, "go ", nil),
        ]
        for c in cases {
            let partial = extract(c.json, ["content"])
            XCTAssertEqual(partial.value(for: "content"), c.value, c.name)
            XCTAssertEqual(partial.completedValue(for: "content"), c.completed, c.name)
        }
    }

    func testNumbersBooleansAndNestedContainersAreSteppedOverSoLaterKeysAreReachable() {
        let scalars = extract(#"{"line": 42, "replace_all": true, "path": "a.swift"}"#, ["path"])
        XCTAssertEqual(scalars.completedValue(for: "path"), "a.swift")
        let nested = extract(#"{"opts": {"a": [1, 2], "b": "}"}, "path": "a.swift"}"#, ["path"])
        XCTAssertEqual(nested.completedValue(for: "path"), "a.swift")
    }

    func testNonObjectInputYieldsNothing() {
        XCTAssertTrue(extract("", ["path"]).values.isEmpty)
        XCTAssertTrue(extract("[1,2]", ["path"]).values.isEmpty)
        XCTAssertTrue(extract("not json at all", ["path"]).values.isEmpty)
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

    func testEditFilePreviewsTheReplacementAndIsCompleteOnlyWhenEveryFieldHasLanded() {
        // old_string is text already visible in the file; new_string is the news.
        let arriving = #"{"path": "a.ts", "old_string": "const a = 1", "new_string": "const a = 2"#
        let draft = StreamingEditPreview.draft(toolName: "edit_file", partialJSON: arriving)
        XCTAssertEqual(draft?.body, "const a = 2")
        XCTAssertEqual(draft?.isComplete, false)
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

    func testThePreviewDiffMarksNewFileLinesAsAdditionsAndExistingOnesAsNeutral() {
        // Which lines of an existing file are actually changes isn't knowable until the whole
        // content is here and can be diffed; tinting them green first would be a guess that then
        // changes. And a card that renders nothing is fine; one that crashes the parser is not.
        let added = UnifiedDiff.parseHunks(StreamingEditPreview.previewDiffText(body: "a\nb", isNewFile: true))
        XCTAssertEqual(added.flatMap(\.lines).filter { $0.kind == .added }.count, 2)
        let neutral = UnifiedDiff.parseHunks(StreamingEditPreview.previewDiffText(body: "a\nb", isNewFile: false))
        XCTAssertTrue(neutral.flatMap(\.lines).allSatisfy { $0.kind == .context })
        XCTAssertFalse(UnifiedDiff.parseHunks(StreamingEditPreview.previewDiffText(body: "", isNewFile: true)).isEmpty)
    }
}

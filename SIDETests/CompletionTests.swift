import AlloyCore
import XCTest
@testable import Side

/// SIDE_RFC_IDE_ESSENTIALS.md, step 1: edits go to a server as edits, completion lists are
/// filtered here, and an item is applied the way its server meant.
final class LSPIncrementalSyncTests: XCTestCase {

    /// Applies LSP content changes to a string the way a server does (UTF-16 positions).
    private func apply(_ changes: [TextDocumentContentChangeEvent], to text: String) -> String {
        var units = Array(text.utf16)
        for change in changes {
            guard let range = change.range else { units = Array(change.text.utf16); continue }
            func offset(_ p: LSPPosition) -> Int {
                var line = 0, i = 0
                while line < p.line, i < units.count { if units[i] == 0x0A { line += 1 }; i += 1 }
                return min(i + p.character, units.count)
            }
            units.replaceSubrange(offset(range.start)..<offset(range.end), with: Array(change.text.utf16))
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    func testEditsBecomeRangesCountedInTheTextBeforeEach() {
        let buffer = TextBuffer("let a = 1\nlet b = 2\n")
        var seen: [AppliedEdit] = []
        buffer.onChange = { seen += $0.edits }
        let before = buffer.text
        buffer.apply([TextEdit(range: 4..<5, text: "alpha"), TextEdit(range: 14..<15, text: "beta")])
        buffer.apply([TextEdit(range: 0..<0, text: "// é\n")])
        let changes = LSPManager.contentChanges(for: seen, from: before)
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.last?.range, LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)))
        XCTAssertEqual(apply(changes, to: before.string), buffer.string)
    }

    func testRandomEditingKeepsTheServersCopyExactlyTheEditors() {
        var generator = SystemRandomNumberGenerator()
        let buffer = TextBuffer("func a() {\n    b()\n}\n😀 two\n")
        var seen: [AppliedEdit] = []
        buffer.onChange = { seen += $0.edits }
        let start = buffer.text
        let pieces = ["x", "\n", "", "é", "😀", "  ", "{\n}", "abc"]
        for _ in 0..<300 {
            let length = buffer.text.utf16Count
            var a = Int.random(in: 0...length, using: &generator), b = Int.random(in: a...min(length, a + 4), using: &generator)
            // Keep offsets on scalar boundaries, as the editor does.
            let ns = buffer.string as NSString
            if a < ns.length, a > 0, UTF16.isTrailSurrogate(ns.character(at: a)) { a -= 1 }
            if b < ns.length, b > 0, UTF16.isTrailSurrogate(ns.character(at: b)) { b += 1 }
            buffer.apply([TextEdit(range: a..<max(a, b), text: pieces.randomElement(using: &generator)!)])
            if Bool.random(using: &generator) { buffer.undo() }
        }
        XCTAssertEqual(apply(LSPManager.contentChanges(for: seen, from: start), to: start.string), buffer.string)
    }

    func testWhatAServerSaysItDoesIsRead() {
        let incremental = LSPServerCapabilities(initializeResult: LSPResult(value: ["capabilities": ["textDocumentSync": ["openClose": true, "change": 2], "completionProvider": ["triggerCharacters": [".", "::"], "resolveProvider": true]]]))
        XCTAssertEqual(incremental.syncKind, 2)
        XCTAssertEqual(incremental.completionTriggers, [".", "::"])
        XCTAssertTrue(incremental.completionResolves)
        let whole = LSPServerCapabilities(initializeResult: LSPResult(value: ["capabilities": ["textDocumentSync": 1]]))
        XCTAssertEqual(whole.syncKind, 1)
        XCTAssertFalse(whole.completionResolves)
    }
}

/// The client against a real process: a small server in Python that keeps its copy of the
/// document from the edits it's sent, asks for settings, answers completion and resolve, and
/// writes what it saw to a file.
final class LSPClientProcessTests: XCTestCase {
    private static let server = #"""
import sys, json, os
out = os.environ["SIDE_FAKE_LSP_OUT"]
text = {}
seen = {"changes": [], "configuration": None, "cancelled": []}
def send(o):
    b = json.dumps(o).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); sys.stdout.buffer.flush()
def dump():
    with open(out, "w") as f: json.dump({"text": text, **seen}, f)
def offset(units, p):
    line, i = 0, 0
    while line < p["line"] and i < len(units):
        if units[i] == 10: line += 1
        i += 1
    return min(i + p["character"], len(units))
while True:
    headers = {}
    while True:
        l = sys.stdin.buffer.readline()
        if not l: sys.exit(0)
        l = l.strip()
        if not l: break
        k, v = l.split(b":", 1); headers[k.lower()] = int(v)
    m = json.loads(sys.stdin.buffer.read(headers[b"content-length"]))
    meth = m.get("method")
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"capabilities": {"textDocumentSync": 2, "completionProvider": {"triggerCharacters": ["."], "resolveProvider": True}}}})
    elif meth == "initialized":
        send({"jsonrpc": "2.0", "id": "cfg", "method": "workspace/configuration", "params": {"items": [{"section": "a"}, {"section": "b"}]}})
    elif "id" in m and meth is None and m["id"] == "cfg":
        seen["configuration"] = m.get("result"); dump()
    elif meth == "textDocument/didOpen":
        d = m["params"]["textDocument"]; text[d["uri"]] = d["text"]; dump()
    elif meth == "textDocument/didChange":
        uri = m["params"]["textDocument"]["uri"]
        units = list(text[uri].encode("utf-16-le"))
        u16 = [units[i] | (units[i+1] << 8) for i in range(0, len(units), 2)]
        for c in m["params"]["contentChanges"]:
            seen["changes"].append("range" in c)
            new = [x for x in c["text"].encode("utf-16-le")]
            new16 = [new[i] | (new[i+1] << 8) for i in range(0, len(new), 2)]
            if "range" in c:
                a, b = offset(u16, c["range"]["start"]), offset(u16, c["range"]["end"])
                u16[a:b] = new16
            else:
                u16 = new16
        text[uri] = b"".join(x.to_bytes(2, "little") for x in u16).decode("utf-16-le"); dump()
    elif meth == "textDocument/completion":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"isIncomplete": False, "items": [{"label": "alpha", "kind": 6, "data": {"n": 1}}, {"label": "beta", "sortText": "0"}]}})
    elif meth == "completionItem/resolve":
        item = m["params"]; item["documentation"] = {"kind": "markdown", "value": "doc %s %s" % (item["label"], item.get("data", {}).get("n"))}
        send({"jsonrpc": "2.0", "id": m["id"], "result": item})
    elif meth == "$/cancelRequest":
        seen["cancelled"].append(m["params"]["id"]); dump()
    elif meth == "shutdown":
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
"""#

    func testAServerGetsEditsAnswersAndIsAnswered() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "no python3")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("side-fake-lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("server.py"), out = dir.appendingPathComponent("seen.json")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["SIDE_FAKE_LSP_OUT"] = out.path
        let client = LSPClient(executableURL: python, arguments: [script.path], environment: environment, currentDirectory: dir)
        let capabilities = try await client.start(rootURI: dir.absoluteString)
        XCTAssertEqual(capabilities.syncKind, 2)

        let buffer = TextBuffer("one\ntwo 😀\nthree\n")
        var edits: [AppliedEdit] = []
        buffer.onChange = { edits += $0.edits }
        let opened = buffer.text
        await client.apply(.didOpen(uri: "file:///a.txt", languageId: "plaintext", text: opened.string, version: 1))
        buffer.apply([TextEdit(range: 4..<7, text: "TWO"), TextEdit(range: 13..<13, text: "!")])
        buffer.apply([TextEdit(range: 0..<0, text: "zero\n")])
        await client.apply(.didChange(uri: "file:///a.txt", changes: LSPManager.contentChanges(for: edits, from: opened), text: buffer.text, version: 2))

        let completion = expectation(description: "completion")
        let received = LockedBox<LSPCompletionList?>(nil)
        await client.apply(.completion(uri: "file:///a.txt", position: LSPPosition(line: 0, character: 1), context: CompletionContext(triggerKind: 1), token: LSPRequestToken()) { result in
            received.value = result.map { LSPCompletionList($0) }
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 10)
        let list = try XCTUnwrap(received.value)
        XCTAssertEqual(list.items.map(\.label), ["alpha", "beta"])

        // The item goes back as the server sent it (its `data` too) and comes back documented.
        let resolved = expectation(description: "resolve")
        let doc = LockedBox<String?>(nil)
        await client.apply(.resolve(item: list.items[0].raw, uri: "file:///a.txt", token: LSPRequestToken()) { result in
            var item = list.items[0]
            if let object = result?.object { item.merge(object) }
            doc.value = item.documentation
            resolved.fulfill()
        })
        await fulfillment(of: [resolved], timeout: 10)
        XCTAssertEqual(doc.value, "doc alpha 1")

        // What the server ended up with, and what it was told.
        var seen: [String: Any] = [:]
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: out), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["configuration"] is [Any], (object["changes"] as? [Bool])?.count == 3 { seen = object; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual((seen["text"] as? [String: String])?["file:///a.txt"], buffer.string, "the server's copy matches the editor's")
        XCTAssertEqual(seen["changes"] as? [Bool], [true, true, true], "every change was an edit, not the text")
        XCTAssertEqual((seen["configuration"] as? [Any])?.count, 2, "workspace/configuration was answered, one value per item")
        await client.stop()
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class CompletionRankingTests: XCTestCase {
    private func ranked(_ labels: [String], _ query: String) -> [String] {
        var session = CompletionSession(wordStart: 0, requestCaret: 0)
        session.receive(LSPCompletionList(items: labels.map { LSPCompletionItem(label: $0) }, isIncomplete: false), query: query)
        return session.shownItems.map(\.label)
    }

    func testAPrefixBeatsALaterMatchAndWhatDoesntMatchGoes() {
        XCTAssertEqual(ranked(["refoo", "foobar", "bar", "foo"], "foo"), ["foo", "foobar", "refoo"])
    }

    func testWordStartsCount() {
        // "gT" is getThing's word starts, and only a scattered match in "gratuitous".
        XCTAssertEqual(ranked(["gratuitous", "getThing"], "gT").first, "getThing")
        XCTAssertEqual(ranked(["user_name", "unmanned"], "un").first, "unmanned", "a prefix still wins")
        XCTAssertEqual(ranked(["abc_name", "anonymous"], "an").first, "anonymous")
    }

    func testMatchingIgnoresCaseButPrefersTheTypedCase() {
        XCTAssertEqual(ranked(["string", "String"], "Str"), ["String", "string"])
    }

    func testNothingTypedKeepsTheServersOrder() {
        var session = CompletionSession(wordStart: 0, requestCaret: 0)
        let items = [LSPCompletionItem(label: "b", sortText: "2"), LSPCompletionItem(label: "a", sortText: "3"), LSPCompletionItem(label: "c", sortText: "1")]
        session.receive(LSPCompletionList(items: items, isIncomplete: false), query: "")
        XCTAssertEqual(session.shownItems.map(\.label), ["c", "b", "a"])
    }

    func testFilteringAServersWholeListIsCheap() {
        // What typescript-language-server sends for a bare identifier: thousands of globals.
        let labels = (0..<6000).map { "symbol\($0)Name" } + ["setTimeout", "setInterval", "Set", "settings"]
        var session = CompletionSession(wordStart: 0, requestCaret: 0)
        session.receive(LSPCompletionList(items: labels.map { LSPCompletionItem(label: $0) }, isIncomplete: false), query: "s")
        var worst = 0.0
        for query in ["se", "set", "setT", "setTi", "setTim"] {
            let start = DispatchTime.now().uptimeNanoseconds
            session.filter(query)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        XCTAssertEqual(session.shownItems.first?.label, "setTimeout")
        // Debug builds are several times slower than the budget's optimized build.
        XCTAssertLessThan(worst, 60, "filtering 6,000 items took \(worst) ms")
    }
}

final class CompletionReplyTests: XCTestCase {
    func testBothReplyShapesAndSharedDefaultsAreRead() {
        let bare = LSPCompletionList(LSPResult(value: [["label": "a"], ["label": "b", "kind": 3]]))
        XCTAssertEqual(bare.items.map(\.label), ["a", "b"])
        XCTAssertFalse(bare.isIncomplete)

        let range: [String: Any] = ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 6]]
        let list = LSPCompletionList(LSPResult(value: [
            "isIncomplete": true,
            "itemDefaults": ["editRange": range],
            "items": [["label": "alpha"], ["label": "beta", "textEdit": ["range": range, "newText": "beta()"]]],
        ] as [String: Any]))
        XCTAssertTrue(list.isIncomplete)
        XCTAssertEqual(list.items[0].textEdit?.newText, "alpha", "the shared range with the item's own text")
        XCTAssertEqual(list.items[1].textEdit?.newText, "beta()", "an item's own edit stays its own")
    }

    func testAnInsertOrReplaceEditKeepsBothRanges() {
        let item = LSPCompletionItem(["label": "value", "textEdit": [
            "newText": "value",
            "insert": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 2]],
            "replace": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 5]],
        ]] as [String: Any])
        XCTAssertEqual(item?.textEdit?.range.end.character, 5)
        XCTAssertEqual(item?.insertRange?.end.character, 2)
    }
}

final class CompletionApplyTests: XCTestCase {
    private func session(wordStart: Int, requestCaret: Int) -> CompletionSession {
        CompletionSession(wordStart: wordStart, requestCaret: requestCaret)
    }

    func testAPlainItemReplacesTheWordTypedSoFar() throws {
        let text = Rope("let x = pri\n")
        let result = try XCTUnwrap(CompletionEdits.edits(for: LSPCompletionItem(label: "print"), session: session(wordStart: 8, requestCaret: 9), caret: 11, text: text, replacing: false))
        XCTAssertEqual(result.all.first?.range, NSRange(location: 8, length: 3))
        XCTAssertEqual(result.caretAfter, 13)
    }

    func testAServersRangeStretchesOverWhatWasTypedSinceItWasAsked() throws {
        // Asked at "fo|" (column 6); "o" typed since; the server's range ended at its caret.
        let text = Rope("  x = foo\n")
        var item = LSPCompletionItem(label: "foobar")
        item.textEdit = LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 6), end: LSPPosition(line: 0, character: 8)), newText: "foobar")
        let result = try XCTUnwrap(CompletionEdits.edits(for: item, session: session(wordStart: 6, requestCaret: 8), caret: 9, text: text, replacing: false))
        XCTAssertEqual(result.all.first?.range, NSRange(location: 6, length: 3))
    }

    func testAnEmptyRangeAtATriggerStillCoversWhatsTypedAfterIt() throws {
        // "document.|" asked; "getEl" typed since. The server's range was empty, at its caret.
        let text = Rope("document.getEl\n")
        var item = LSPCompletionItem(label: "getElementById")
        item.textEdit = LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 9), end: LSPPosition(line: 0, character: 9)), newText: "getElementById")
        let result = try XCTUnwrap(CompletionEdits.edits(for: item, session: session(wordStart: 9, requestCaret: 9), caret: 14, text: text, replacing: false))
        XCTAssertEqual(result.all.first?.range, NSRange(location: 9, length: 5))
    }

    func testAServerThatCountedNewerTextStillLandsOnTheWord() throws {
        // sourcekit-lsp: asked after "m" (col 9), answered with a range to col 10, the "i" typed
        // since already in it. The edit ends at the caret, not past the text.
        let text = Rope("let m = mi")
        var item = LSPCompletionItem(label: "min")
        item.insertTextFormat = 2
        item.textEdit = LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 8), end: LSPPosition(line: 0, character: 10)), newText: "min(${1:x}, ${2:y})")
        let result = try XCTUnwrap(CompletionEdits.edits(for: item, session: session(wordStart: 8, requestCaret: 9), caret: 10, text: text, replacing: false))
        XCTAssertEqual(result.all.first?.range, NSRange(location: 8, length: 2))
        XCTAssertEqual(result.snippet.text, "min(x, y)")
        XCTAssertEqual(result.snippet.stops.first, [4..<5])
    }

    func testReturnInsertsTabReplacesTheRestOfTheWord() throws {
        let text = Rope("fo|obar\n".replacingOccurrences(of: "|", with: ""))
        var item = LSPCompletionItem(label: "format")
        item.textEdit = LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 6)), newText: "format")
        item.insertRange = LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 2))
        let insert = try XCTUnwrap(CompletionEdits.edits(for: item, session: session(wordStart: 0, requestCaret: 2), caret: 2, text: text, replacing: false))
        XCTAssertEqual(insert.all.first?.range, NSRange(location: 0, length: 2))
        let replace = try XCTUnwrap(CompletionEdits.edits(for: item, session: session(wordStart: 0, requestCaret: 2), caret: 2, text: text, replacing: true))
        XCTAssertEqual(replace.all.first?.range, NSRange(location: 0, length: 6))
    }

    func testAnAutoImportAboveMovesTheCaretWithIt() throws {
        let text = Rope("\nuseSt\n")
        var item = LSPCompletionItem(label: "useState")
        item.additionalTextEdits = [LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)), newText: "import { useState } from 'react'\n")]
        let result = try XCTUnwrap(CompletionEdits.edits(for: item, session: session(wordStart: 1, requestCaret: 2), caret: 6, text: text, replacing: false))
        XCTAssertEqual(result.all.count, 2)
        let buffer = TextBuffer(text.string)
        buffer.apply(result.all.map { TextEdit(range: $0.range.location..<NSMaxRange($0.range), text: $0.text) })
        XCTAssertEqual(buffer.string, "import { useState } from 'react'\n\nuseState\n")
        XCTAssertEqual(result.caretAfter, ("import { useState } from 'react'\n\nuseState" as NSString).length)
    }

    func testSnippetsAreInsertedAsTextUntilPlaceholdersExist() {
        XCTAssertEqual(CompletionText.plain(snippet: "print(${1:value})$0").text, "print(value)")
        XCTAssertEqual(CompletionText.plain(snippet: "print(${1:value})$0").caret, 6)
        XCTAssertEqual(CompletionText.plain(snippet: "for ${1|a,b|} in $2 {\n\t$0\n}").text, "for a in  {\n\t\n}")
        XCTAssertEqual(CompletionText.plain(snippet: "cost \\$5").text, "cost $5")
        XCTAssertEqual(CompletionText.plain(snippet: "f(${1:x: ${2:Int}})").text, "f(x: Int)")
    }

    func testWithoutAServerTheOpenFilesWordsComplete() {
        let words = CompletionText.bufferWords([Rope("let total = subtotal + tax\nprint(total)\n"), Rope("total2 = 9")], excluding: "")
        XCTAssertEqual(words.first, "total")
        XCTAssertTrue(words.contains("subtotal"))
        XCTAssertTrue(words.contains("tax"), "three letters or more")
        XCTAssertFalse(words.contains("9"))
    }
}

/// SIDE_RFC_IDE_ESSENTIALS.md's budgets for step 1.
final class CompletionBudgetTests: XCTestCase {
    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    func testReRankingAWholeListPerKeystroke() throws {
        try Budgets.skipUnlessEnabled()
        let labels = (0..<6000).map { "symbol\($0)Name" } + ["setTimeout", "setInterval", "Set", "settings"]
        var session = CompletionSession(wordStart: 0, requestCaret: 0)
        session.receive(LSPCompletionList(items: labels.map { LSPCompletionItem(label: $0, detail: "(method) Something.\($0)(): void") }, isIncomplete: false), query: "s")
        var times: [Double] = []
        for _ in 0..<20 {
            for query in ["s", "se", "set", "setT", "setTi", "setTim", "sym", "symb", "symbol1"] {
                let start = DispatchTime.now().uptimeNanoseconds
                session.filter(query)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
        }
        Budgets.check("completion.filter", percentile(times, 0.99), detail: String(format: "p50 %.2f ms", percentile(times, 0.5)))
    }

    func testAKeystrokesEditBecomesAChangeCheaply() throws {
        try Budgets.skipUnlessEnabled()
        let line = "    let value = compute(alpha, beta) + offset // a comment\n"
        let buffer = TextBuffer(String(repeating: line, count: 100_000))
        var edits: [AppliedEdit] = []
        buffer.onChange = { edits = $0.edits }
        var times: [Double] = []
        for i in 0..<400 {
            let before = buffer.text
            let at = (i * 7919 % 99_000) * (line as NSString).length + 10
            buffer.apply([TextEdit(range: at..<at, text: "x")])
            let start = DispatchTime.now().uptimeNanoseconds
            _ = LSPManager.contentChanges(for: edits, from: before)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        Budgets.check("completion.sync", percentile(times, 0.99), detail: String(format: "p50 %.3f ms", percentile(times, 0.5)))
    }
}

/// Return and closing brackets indent the way the code nests.
@MainActor
final class EditorIndentTests: XCTestCase {
    private func newline(_ text: String) -> (text: String, caret: Int)? {
        let caret = (text as NSString).range(of: "|").location
        let ns = text.replacingOccurrences(of: "|", with: "") as NSString
        return MakeWorkspaceViewController.newline(in: ns, replacing: NSRange(location: caret, length: 0))
    }

    func testReturnBetweenBracesPutsTheCloserOnItsOwnLineAtTheOuterIndent() {
        let result = newline("    function f() {|}")
        XCTAssertEqual(result?.text, "\n        \n    ")
        XCTAssertEqual(result?.caret, 9, "the caret on the indented line between")
    }

    func testReturnAfterAnOpenerIndentsOnceAndOtherwiseKeepsTheIndent() {
        XCTAssertEqual(newline("  if (x) {|\n  }")?.text, "\n    ", "two-space files indent by two")
        XCTAssertEqual(newline("    let a = 1|")?.text, "\n    ")
        XCTAssertEqual(newline("\tfunc a() {|}\n\t\tb()\n")?.text, "\n\t\t\n\t", "tab files indent with tabs")
    }

    func testAClosingBracketOnABlankLineGoesBackToItsOpenersIndent() {
        let text = "function f() {\n    body()\n        " as NSString
        let outdent = MakeWorkspaceViewController.outdentedCloser("}", in: text, at: text.length)
        XCTAssertEqual(outdent?.text, "}")
        XCTAssertEqual(outdent?.range, NSRange(location: 26, length: 8))
        XCTAssertNil(MakeWorkspaceViewController.outdentedCloser("}", in: "x = {a" as NSString, at: 6), "not on a line with code")
    }
}

/// Step 2: what signature help and hover read from a server, and how they're shown.
@MainActor
final class SignatureAndHoverTests: XCTestCase {
    func testSignatureHelpFindsTheParameterByOffsetsOrByItsText() throws {
        let help = try XCTUnwrap(LSPSignatureHelp(LSPResult(value: [
            "signatures": [
                ["label": "setTimeout(handler: TimerHandler, timeout?: number): number",
                 "parameters": [["label": [11, 32]], ["label": "timeout?: number", "documentation": ["kind": "markdown", "value": "The delay in **ms**."]]]],
                ["label": "setTimeout(handler: string): number", "parameters": [["label": "handler: string"]]],
            ],
            "activeSignature": 0, "activeParameter": 1,
        ] as [String: Any])))
        XCTAssertEqual(help.signatures.count, 2)
        XCTAssertEqual(help.current.parameters[0].range, 11..<32)
        XCTAssertEqual(help.current.parameters[1].range, 34..<50)
        XCTAssertEqual(help.currentParameter, 1)
        let shown = MakeWorkspaceViewController.render(help).string
        XCTAssertTrue(shown.hasPrefix("1/2  setTimeout("), shown)
        XCTAssertTrue(shown.hasSuffix("The delay in ms."), shown)
        XCTAssertNil(LSPSignatureHelp(LSPResult(value: NSNull())), "no call: no card")
    }

    func testHoverContentsInEachShapeAServerSends() {
        XCTAssertEqual(LSPHover(LSPResult(value: ["contents": ["kind": "markdown", "value": "**x**"]]))?.markdown, "**x**")
        XCTAssertEqual(LSPHover(LSPResult(value: ["contents": ["language": "swift", "value": "let x: Int"]]))?.markdown, "```swift\nlet x: Int\n```")
        XCTAssertEqual(LSPHover(LSPResult(value: ["contents": ["plain", ["language": "ts", "value": "a"]]] as [String: Any]))?.markdown, "plain\n\n```ts\na\n```")
        XCTAssertNil(LSPHover(LSPResult(value: ["contents": ""])))
    }

    func testMarkdownKeepsCodeAndIdentifiersAndDropsMarks() {
        let shown = MarkdownLite.attributed("```ts\nfunction f(): void\n```\n\nCalls `snake_case_name` — see [the docs](https://x.y) and *this*.").string
        XCTAssertEqual(shown, "function f(): void\n\nCalls snake_case_name — see the docs and this.")
        XCTAssertEqual(MarkdownLite.attributed("a_b_c and _d_").string, "a_b_c and d")
    }

    func testAProblemComesBeforeTheDocs() {
        let problem = LSPDiagnostic(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 1)), severity: .error, message: "Cannot find name 'x'.", source: "ts")
        let shown = MakeWorkspaceViewController.hoverContent(problems: [problem], markdown: "let x").string
        XCTAssertEqual(shown, "\u{25CF} Cannot find name 'x'.  ts\n\nlet x")
    }
}

/// Step 3: what a server's rename and fixes say.
final class WorkspaceEditTests: XCTestCase {
    private let range: [String: Any] = ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]

    func testBothShapesOfAWorkspaceEdit() throws {
        let changes = try XCTUnwrap(LSPWorkspaceEdit(["changes": ["file:///b.ts": [["range": range, "newText": "x"]], "file:///a.ts": [["range": range, "newText": "y"]]]]))
        XCTAssertEqual(changes.files.map(\.uri), ["file:///a.ts", "file:///b.ts"])
        let documentChanges = try XCTUnwrap(LSPWorkspaceEdit(["documentChanges": [
            ["textDocument": ["uri": "file:///a.ts", "version": 3], "edits": [["range": range, "newText": "z"]]],
            ["kind": "rename", "oldUri": "file:///a.ts", "newUri": "file:///c.ts"],
        ]]))
        XCTAssertEqual(documentChanges.editCount, 1)
        XCTAssertEqual(documentChanges.unsupported, 1, "a file rename is counted, not applied")
    }

    func testActionsCommandsAndWhatsDisabled() throws {
        let fix = try XCTUnwrap(LSPCodeAction(["title": "Add import", "kind": "quickfix", "isPreferred": true,
                                                "edit": ["changes": ["file:///a.ts": [["range": range, "newText": "import x\n"]]]]] as [String: Any]))
        XCTAssertTrue(fix.isQuickFix)
        XCTAssertTrue(fix.isPreferred)
        XCTAssertEqual(fix.edit?.editCount, 1)
        let command = try XCTUnwrap(LSPCodeAction(["title": "Organize", "command": "_organize", "arguments": ["a"]] as [String: Any]))
        XCTAssertEqual(command.command?.name, "_organize")
        let disabled = try XCTUnwrap(LSPCodeAction(["title": "Extract", "kind": "refactor.extract", "disabled": ["reason": "Select an expression"]] as [String: Any]))
        XCTAssertEqual(disabled.disabledReason, "Select an expression")
    }
}

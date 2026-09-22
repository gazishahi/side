import XCTest
@testable import Side

/// Audit H7 (encoding-safe saves) and H8 (external changes reach the editor and the indexes).
final class FileIntegrityTests: XCTestCase {
    func testDecodeRefusesBinaryAndRecordsTheFilesShape() {
        let cp1252Cafe = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in Windows-1252
        let cases: [(name: String, bytes: Data, text: String?, format: TextFileCodec.Format?)] = [
            ("NUL byte", Data([0x41, 0x00, 0x42]), nil, nil),
            ("dense control bytes", Data([0x01, 0x02, 0x03, 0x04, 0x41]), nil, nil),
            ("UTF-16 without a BOM", "hi".data(using: .utf16LittleEndian)!, nil, nil),
            ("plain UTF-8", Data("a\nb".utf8), "a\nb", .utf8),
            ("UTF-8 with BOM", Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8), "x", .init(encoding: .utf8, byteOrderMark: true, lineEnding: .lf)),
            ("Windows-1252", cp1252Cafe, "café", .init(encoding: .windowsCP1252, byteOrderMark: false, lineEnding: .lf)),
            ("CRLF is normalised in the buffer", Data("a\r\nb\r\nc".utf8), "a\nb\nc", .init(encoding: .utf8, byteOrderMark: false, lineEnding: .crlf)),
            ("UTF-16 LE with BOM", Data([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!, "hi", .init(encoding: .utf16LittleEndian, byteOrderMark: true, lineEnding: .lf)),
        ]
        for c in cases {
            let decoded = TextFileCodec.decode(c.bytes)
            XCTAssertEqual(decoded?.text, c.text, c.name)
            XCTAssertEqual(decoded?.format, c.format, c.name)
        }
    }

    func testSavingWritesBackTheSameBytesForEverythingTheUserDidNotTouch() throws {
        // A CP1252 file with CRLF endings: edit line 1, and line 2's bytes — including the
        // non-ASCII one — must be identical, with CRLF preserved on the new line too.
        let line2 = Data([0x63, 0x61, 0x66, 0xE9])
        let original = Data("first\r\n".utf8) + line2
        let decoded = try XCTUnwrap(TextFileCodec.decode(original))
        let edited = decoded.text.replacingOccurrences(of: "first", with: "FIRST\nsecond")
        let saved = try XCTUnwrap(TextFileCodec.encode(edited, as: decoded.format))
        XCTAssertEqual(saved, Data("FIRST\r\nsecond\r\n".utf8) + line2)
        // A character the encoding can't hold is refused, never transcoded.
        XCTAssertNil(TextFileCodec.encode("→", as: decoded.format))
        // BOMs come back.
        let bom = TextFileCodec.Format(encoding: .utf8, byteOrderMark: true, lineEnding: .lf)
        XCTAssertEqual(TextFileCodec.encode("x", as: bom), Data([0xEF, 0xBB, 0xBF, 0x78]))
        // Writing through the URL helper picks the file's own format up from disk.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codec-\(UUID().uuidString).txt")
        try original.write(to: url)
        try TextFileCodec.write("new\ncafé", to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("new\r\n".utf8) + line2)
    }

    @MainActor
    func testAWatchedRootReportsChangesAndMakesTheMentionIndexStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let index = ProjectFileIndex()
        let indexed = expectation(description: "indexed")
        index.refresh(root: root) { indexed.fulfill() }
        wait(for: [indexed], timeout: 5)
        XCTAssertEqual(index.relativePaths, ["a.txt"])

        let changed = expectation(description: "watcher fired")
        changed.assertForOverFulfill = false
        var seen: [URL] = []
        // Setup writes may still be in flight when the stream starts, so wait for b.txt itself.
        let watcher = ProjectWatcher(root: root, latency: 0.1) { urls in
            seen += urls
            if urls.contains(where: { $0.lastPathComponent == "b.txt" }) { changed.fulfill() }
        }
        // Give the stream a beat to start, then write.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try "b".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 10)
        XCTAssertTrue(seen.contains { $0.lastPathComponent == "b.txt" }, "\(seen)")
        _ = watcher

        // Same root, no stale mark: refresh is a no-op (the original early-return).
        let unchanged = expectation(description: "no-op refresh")
        index.refresh(root: root) { unchanged.fulfill() }
        wait(for: [unchanged], timeout: 5)
        XCTAssertEqual(index.relativePaths, ["a.txt"])
        // Marked stale: the new file appears.
        index.markStale()
        let rescanned = expectation(description: "rescanned")
        index.refresh(root: root) { rescanned.fulfill() }
        wait(for: [rescanned], timeout: 5)
        XCTAssertEqual(Set(index.relativePaths), ["a.txt", "b.txt"])
    }
}

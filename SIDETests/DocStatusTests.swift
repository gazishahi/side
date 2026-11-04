import XCTest
@testable import Side
@testable import Heron

/// Documentation truthfulness, checked by machine.
///
/// Twice now a document has described something shipped as unstarted (stacked tracks in the
/// 2026-08-25 audit, Phase 10 in the 2026-09-01 one). Both times the recommended fix was a
/// check like this and it was never written, which is why the drift recurred. The convention is
/// small: every planning or reference document carries a `Status:` line near the top, and a
/// document that says *built* names the symbols it means on a `Symbols:` line, each of which must
/// exist in the source tree. The constitution's stage table is checked against the real
/// `ShellViewController.Stage`. Audit reports are snapshots and exempt.
final class DocStatusTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private var docs: [URL] {
        let dir = repoRoot.appendingPathComponent("docs")
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "md" && !$0.lastPathComponent.contains("AUDIT_REPORT") }.sorted { $0.path < $1.path }
    }
    private lazy var sourceText: String = {
        SourceTree.swiftFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }()

    private func status(of doc: URL) throws -> (status: String, symbols: [String], head: String) {
        let text = try String(contentsOf: doc, encoding: .utf8)
        let head = text.components(separatedBy: "\n").prefix(12).joined(separator: "\n")
        // Planning documents have two more states: a spec that is agreed and waiting to be built,
        // and an RFC whose decisions are still pending. Both are honest; neither is "built".
        let statusMatch = head.range(of: #"Status:\s*\**\s*(built|planned|in progress|reference|agreed|accepted|decisions pending)"#, options: .regularExpression)
        let status = statusMatch.map { head[$0] }.map { line -> String in
            let afterColon = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            return afterColon.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        } ?? ""
        var symbols: [String] = []
        if let symbolsLine = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("Symbols:") }) {
            let regex = try NSRegularExpression(pattern: "`([A-Za-z_][A-Za-z0-9_]*)`")
            for match in regex.matches(in: symbolsLine, range: NSRange(symbolsLine.startIndex..., in: symbolsLine)) {
                symbols.append(String(symbolsLine[Range(match.range(at: 1), in: symbolsLine)!]))
            }
        }
        return (status, symbols, head)
    }

    func testEveryDocumentDeclaresAStatus() throws {
        let allowed: Set<String> = ["built", "planned", "in progress", "reference", "agreed", "accepted", "decisions pending"]
        XCTAssertFalse(docs.isEmpty)
        for doc in docs {
            let found = try status(of: doc)
            XCTAssertTrue(allowed.contains(found.status), "\(doc.lastPathComponent): status is '\(found.status)' — expected one of \(allowed.sorted())\n\(found.head)")
        }
    }

    func testABuiltDocumentNamesSymbolsThatExist() throws {
        for doc in docs {
            let found = try status(of: doc)
            guard found.status == "built" else { continue }
            XCTAssertFalse(found.symbols.isEmpty, "\(doc.lastPathComponent) says built but names no symbols — add a `Symbols:` line")
            for symbol in found.symbols {
                let declared = sourceText.range(of: #"\b(class|struct|enum|actor|protocol)\s+\#(symbol)\b"#, options: .regularExpression) != nil
                XCTAssertTrue(declared, "\(doc.lastPathComponent) claims `\(symbol)` is built, but nothing declares it")
            }
        }
    }

    func testTheConstitutionsStageTableMatchesTheCode() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("docs/SIDE_PRODUCT_CONSTITUTION.md"), encoding: .utf8)
        let realStages = Set(ShellViewController.Stage.allCases.map(\.title))
        var checked = 0
        for line in text.components(separatedBy: "\n") where line.hasPrefix("| ") && line.contains("|") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, cells[0] != "Stage", !cells[0].hasPrefix("-") else { continue }
            let stage = cells[0], status = cells[1].replacingOccurrences(of: "*", with: "")
            switch status {
            case "built":
                XCTAssertTrue(realStages.contains(stage), "constitution says \(stage) is built; ShellViewController.Stage has no such case")
                checked += 1
            case "planned", _ where status.hasPrefix("not a stage"):
                XCTAssertFalse(realStages.contains(stage), "constitution says \(stage) is not a stage, but it exists in code — update the table")
                checked += 1
            default:
                break
            }
        }
        XCTAssertEqual(checked, 7, "expected the five built stages and two non-stages to be checked")
    }
}

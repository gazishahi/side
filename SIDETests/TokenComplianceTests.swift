import XCTest
@testable import Side

/// Direction 02 §2 acceptance, enforced at test time rather than by a checklist nobody reruns.
final class TokenComplianceTests: XCTestCase {
    private var tokenFile: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SIDE/DesignSystem.swift")
    }

    private var sourceFiles: [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SIDE")
        return (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DesignSystem.swift" }
    }

    private func offenders(matching pattern: String, excludingLinesContaining exclusion: String? = nil) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in sourceFiles {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                if let exclusion, line.contains(exclusion) { continue }
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        return found
    }

    func testTheTokenFileIsTheOnlyHomeForLiteralsBordersAndMotion() throws {
        // Direction 02 §2: colour, radius, and type sizes come from the token file; §2.1 gives
        // hierarchy from tone, so hairlines separate rows and never enclose them (the Working
        // ring on DS.StatusDot is the one border, and it lives in the token file); a raw
        // `context.duration = 0.2` is an animation Reduce Motion cannot turn off, so every
        // duration goes through the motion helper and Reduce Motion is consulted in exactly one
        // place; and the per-stage palettes are gone.
        let rules: [(rule: String, pattern: String, exclusion: String?)] = [
            ("no colour literals outside the token file", #"NSColor\(white:"#, nil),
            ("no radius literals outside the token file", #"cornerRadius = [0-9]"#, nil),
            ("no font sizes outside the token file", #"ofSize:"#, "pointSize"),
            ("Reduce Motion is consulted only in the token file", "accessibilityDisplayShouldReduceMotion", nil),
            ("every animation duration goes through the motion helper", #"context\.duration = 0\."#, nil),
            ("every timing function goes through the motion helper", #"timingFunction = CAMediaTimingFunction\("#, "easeInEaseOut"),
            ("nothing is enclosed by a border (borderWidth)", #"borderWidth = 1"#, nil),
            ("nothing is enclosed by a border (bindLayerBorder)", #"bindLayerBorder\("#, nil),
            ("the per-stage palettes are gone", "TracksPalette|ReviewPalette", nil),
        ]
        for rule in rules {
            XCTAssertEqual(try offenders(matching: rule.pattern, excludingLinesContaining: rule.exclusion), [], rule.rule)
        }

        let tokens = try String(contentsOf: tokenFile, encoding: .utf8)
        XCTAssertEqual(
            tokens.components(separatedBy: "accessibilityDisplayShouldReduceMotion").count - 1, 1,
            "Reduce Motion is consulted in exactly one place in the token file"
        )
    }

    func testStatusStateMapsActivityWithoutLosingFailure() {
        XCTAssertEqual(DS.StatusState(.failed), .failed)
        XCTAssertEqual(DS.StatusState(.needsYou), .needsYou)
        XCTAssertEqual(DS.StatusState(.working), .working)
        XCTAssertEqual(DS.StatusState(.none), .idle)
    }

    @MainActor
    func testTheStatusDotIsAnAccessibleImageNamedForItsState() {
        let dot = DS.StatusDot(state: .needsYou)
        XCTAssertTrue(dot.isAccessibilityElement())
        XCTAssertEqual(dot.accessibilityRole(), .image)
        XCTAssertEqual(dot.accessibilityLabel(), "Needs you")
        dot.state = .working
        XCTAssertEqual(dot.accessibilityLabel(), "Working")
        XCTAssertEqual(dot.layer?.borderWidth, 1.5, "working is a ring, not a fill")
    }
}

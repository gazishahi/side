import XCTest
@testable import Side

/// Direction 02 §2 acceptance, enforced at test time rather than by a checklist nobody reruns.
final class TokenComplianceTests: XCTestCase {
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

    func testNoColorLiteralsOutsideTheTokenFile() throws {
        XCTAssertEqual(try offenders(matching: #"NSColor\(white:"#), [])
    }

    func testNoRadiusLiteralsOutsideTheTokenFile() throws {
        XCTAssertEqual(try offenders(matching: #"cornerRadius = [0-9]"#), [])
    }

    func testNoFontSizesOutsideTheTokenFile() throws {
        XCTAssertEqual(try offenders(matching: #"ofSize:"#, excludingLinesContaining: "pointSize"), [])
    }

    func testReduceMotionIsConsultedInExactlyOnePlace() throws {
        XCTAssertEqual(try offenders(matching: "accessibilityDisplayShouldReduceMotion"), [])
        let tokens = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SIDE/DesignSystem.swift"), encoding: .utf8)
        XCTAssertEqual(tokens.components(separatedBy: "accessibilityDisplayShouldReduceMotion").count - 1, 1)
    }

    func testEveryAnimationDurationGoesThroughTheMotionHelper() throws {
        // A raw `context.duration = 0.2` is an animation Reduce Motion cannot turn off.
        XCTAssertEqual(try offenders(matching: #"context\.duration = 0\."#), [])
        XCTAssertEqual(try offenders(matching: #"timingFunction = CAMediaTimingFunction\("#, excludingLinesContaining: "easeInEaseOut"), [])
    }

    func testThePerStagePalettesAreGone() throws {
        XCTAssertEqual(try offenders(matching: "TracksPalette|ReviewPalette"), [])
    }

    func testDiffAndGutterColorsAreTokens() {
        XCTAssertEqual(DiffBody.addedFill, DS.Color.diffAdded)
        XCTAssertEqual(DiffBody.removedFill, DS.Color.diffRemoved)
        XCTAssertEqual(DiffBody.addedText, DS.Color.statusVerified)
        XCTAssertEqual(DiffBody.removedText, DS.Color.statusFailed)
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

    func testMotionDurationHonoursReduceMotion() {
        let expected: TimeInterval = DS.Motion.reduceMotion ? 0 : 0.2
        XCTAssertEqual(DS.Motion.duration(0.2), expected)
    }
}

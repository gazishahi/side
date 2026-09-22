import AppKit
import XCTest
@testable import Side

@MainActor
final class TypographyTests: XCTestCase {
    private var originalScale: DS.Text.Scale!

    override func setUp() {
        super.setUp()
        originalScale = .current
    }

    override func tearDown() {
        DS.Text.Scale.current = originalScale
        super.tearDown()
    }

    /// The five roles by name, read at whatever scale is current.
    private func roleSizes() -> [(role: String, size: CGFloat)] {
        [
            ("title", DS.Text.title().pointSize),
            ("heading", DS.Text.heading().pointSize),
            ("body", DS.Text.body().pointSize),
            ("caption", DS.Text.caption().pointSize),
            ("code", DS.Text.code().pointSize),
        ]
    }

    func testDefaultScaleRendersTheFiveRoles() {
        DS.Text.Scale.current = .standard
        // Direction 02 §2.6: five roles. If these drift, every screen shifts without anyone deciding to.
        XCTAssertEqual(DS.Text.title().pointSize, 20)
        XCTAssertEqual(DS.Text.heading().pointSize, 15)
        XCTAssertEqual(DS.Text.body().pointSize, 13)
        XCTAssertEqual(DS.Text.caption().pointSize, 11)
        XCTAssertEqual(DS.Text.code().pointSize, 12)
    }

    func testEveryRoleFollowsTheScaleAndTheHierarchyNeverInverts() {
        // A role that ignores the scale drifts out of step with the rest of the screen, and a
        // hierarchy that inverts at some scale would be worse than no scaling at all.
        DS.Text.Scale.current = .standard
        let baseline = roleSizes()
        DS.Text.Scale.current = .larger
        for (index, enlarged) in roleSizes().enumerated() {
            XCTAssertGreaterThan(enlarged.size, baseline[index].size, "\(enlarged.role) ignored the scale")
        }

        for scale in [DS.Text.Scale.compact, .standard, .larger] {
            DS.Text.Scale.current = scale
            XCTAssertLessThan(DS.Text.caption().pointSize, DS.Text.body().pointSize, "caption/body inverted at \(scale)")
            XCTAssertLessThan(DS.Text.body().pointSize, DS.Text.title().pointSize, "body/title inverted at \(scale)")
        }
    }

    func testWeightIsPreservedThroughScaling() {
        DS.Text.Scale.current = .large
        let semibold = DS.Text.heading(.semibold)
        let regular = DS.Text.heading(.regular)
        XCTAssertEqual(semibold.pointSize, regular.pointSize)
        XCTAssertNotEqual(semibold.fontDescriptor.symbolicTraits, regular.fontDescriptor.symbolicTraits)
    }

    func testCodeRoleStaysMonospaced() {
        DS.Text.Scale.current = .larger
        let font = DS.Text.code()
        // Diffs and gutters line up on a fixed advance; a scale that silently swapped in a
        // proportional face would break every column in the app.
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace) || font.isFixedPitch, font.fontName)
    }

    func testChangingTheScaleNotifiesOnceAndOnlyOnAChange() {
        DS.Text.Scale.current = .standard
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: DS.Text.scaleDidChangeNotification, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        DS.Text.Scale.current = .large
        XCTAssertEqual(notifications, 1)

        // Re-selecting the current size shouldn't make every open stage rebuild itself.
        DS.Text.Scale.current = .large
        XCTAssertEqual(notifications, 1)
    }
}

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

    func testDefaultScaleRendersTheSizesTheAppAlreadyUsed() {
        DS.Text.Scale.current = .standard
        // The point of the migration was to name the existing sizes, not to redesign type. If
        // these drift, every screen shifts without anyone deciding to.
        XCTAssertEqual(DS.Text.body().pointSize, 12, accuracy: 0.6)
        XCTAssertEqual(DS.Text.control().pointSize, 12)
        XCTAssertEqual(DS.Text.heading().pointSize, 13)
        XCTAssertEqual(DS.Text.title().pointSize, 17)
        XCTAssertEqual(DS.Text.caption().pointSize, 11)
        XCTAssertEqual(DS.Text.figure().pointSize, 20)
    }

    func testEveryRoleGrowsWithTheScale() {
        DS.Text.Scale.current = .standard
        let baseline = [
            DS.Text.display().pointSize, DS.Text.figure().pointSize, DS.Text.title().pointSize,
            DS.Text.subtitle().pointSize, DS.Text.heading().pointSize, DS.Text.body().pointSize,
            DS.Text.control().pointSize, DS.Text.caption().pointSize, DS.Text.micro().pointSize,
            DS.Text.code().pointSize,
        ]

        DS.Text.Scale.current = .larger
        let enlarged = [
            DS.Text.display().pointSize, DS.Text.figure().pointSize, DS.Text.title().pointSize,
            DS.Text.subtitle().pointSize, DS.Text.heading().pointSize, DS.Text.body().pointSize,
            DS.Text.control().pointSize, DS.Text.caption().pointSize, DS.Text.micro().pointSize,
            DS.Text.code().pointSize,
        ]

        for (index, before) in baseline.enumerated() {
            XCTAssertGreaterThan(enlarged[index], before, "role \(index) ignored the scale")
        }
    }

    func testSmallerScaleShrinksAndOrderingIsPreserved() {
        DS.Text.Scale.current = .compact
        // A hierarchy that inverts at some scale would be worse than no scaling at all.
        XCTAssertLessThan(DS.Text.caption().pointSize, DS.Text.body().pointSize)
        XCTAssertLessThan(DS.Text.body().pointSize, DS.Text.title().pointSize)
        XCTAssertLessThan(DS.Text.micro().pointSize, DS.Text.caption().pointSize)
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

    func testScalePersists() {
        DS.Text.Scale.current = .large
        XCTAssertEqual(DS.Text.Scale.current, .large)
        XCTAssertEqual(
            DS.Text.Scale(rawValue: UserDefaults.standard.double(forKey: "SideTextScale")), .large,
            "the setting has to survive a relaunch to be worth having"
        )
    }
}

import AppKit
import XCTest
@testable import SwiftMath

/// The vendored copy's one font loads, and a formula typesets to an image.
final class SwiftMathTests: XCTestCase {
    func testAFormulaTypesets() throws {
        var image = MathImage(latex: #"\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#, fontSize: 20, textColor: .black)
        let (error, rendered, layout) = image.asImage()
        XCTAssertNil(error)
        let size = try XCTUnwrap(rendered?.size)
        XCTAssertGreaterThan(size.width, 60)
        XCTAssertGreaterThan(layout?.descent ?? 0, 0, "a fraction reaches below the baseline")
        XCTAssertEqual(MathFont.allCases, [.latinModernFont])
    }

    func testAnUnknownCommandIsAnError() {
        var image = MathImage(latex: #"\notacommand{x}"#, fontSize: 20, textColor: .black)
        XCTAssertNotNil(image.asImage().0)
    }
}

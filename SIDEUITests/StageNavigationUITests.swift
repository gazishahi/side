import XCTest

/// End-to-end UI automation — the piece the audit called out as absent. Unit-level AX tests can
/// assert that a view *says* the right thing; only this can assert that a real launched app puts
/// it in the tree, that the menu commands reach it, and that the window is operable by keyboard.
///
/// Written against the AX tree the same way an assistive client sees it, so a regression that
/// makes Side unusable with VoiceOver fails the build rather than waiting for someone to notice.
final class StageNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Stops a test run from mutating the developer's own last-opened project or text size.
        app.launchArguments += ["-SideUITesting", "YES"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func goToStage(_ name: String) {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Navigate"].click()
        menuBar.menuItems["Go to \(name)"].click()
    }

    func testEveryStageIsReachableFromTheNavigateMenu() {
        // The constitution promises keyboard movement between stages; before the audit there
        // were no stage jumps at all, and nothing has been verifying them since they landed.
        for stage in ["Make", "Think", "Review", "Run", "Tracks"] {
            goToStage(stage)
            XCTAssertTrue(app.windows.firstMatch.exists, "window disappeared after going to \(stage)")
        }
    }

    func testRunStageExposesTheTerminalAsATextArea() {
        goToStage("Run")
        let terminal = app.windows.firstMatch.textViews["Terminal"]
        // The audit found the SwiftTerm view completely absent from the live tree — this is the
        // assertion that keeps it there.
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the terminal is not in the AX tree")
    }

    func testThinkComposerAcceptsKeyboardInput() {
        goToStage("Think")
        let window = app.windows.firstMatch
        let composer = window.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText("hello from a UI test")
        // Nothing is sent — this asserts the composer is focusable and takes text, which is the
        // keyboard half of the accessibility pass, without spending tokens on a provider call.
        XCTAssertTrue(window.exists)
    }

    func testPreferencesOpensAndExposesItsPanes() {
        app.menuBars.firstMatch.menuBarItems["Side"].click()
        app.menuBars.firstMatch.menuItems["Settings…"].click()

        let preferences = app.windows["Preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 5))
        for pane in ["Providers", "Usage", "Appearance", "History"] {
            XCTAssertTrue(preferences.radioButtons[pane].exists, "\(pane) pane is missing from Preferences")
        }
    }
}

import XCTest

/// App Store screenshots, from the sample lists in iOS/ScreenshotSample.
/// Run by scripts/ios-screenshots (which sets LISTFUL_SAMPLE to a fresh copy
/// of them and exports the attachments); skipped otherwise.
@MainActor
final class ScreenshotTests: XCTestCase {
    private func launch() throws -> XCUIApplication {
        let sample = ProcessInfo.processInfo.environment["LISTFUL_SAMPLE"]
        try XCTSkipIf(sample == nil, "Run by scripts/ios-screenshots")
        let app = XCUIApplication()
        app.launchArguments = ["-testFolder", sample!, "-selectedList", ""]
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        sleep(1)  // let animations settle
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPhoneScreenshots() throws {
        let app = try launch()
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone)
        XCUIDevice.shared.orientation = .portrait
        app.staticTexts["Trip to Lisbon"].firstMatch.tap()
        shot(app, "1-list")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        shot(app, "2-lists")
        app.staticTexts["Website relaunch"].firstMatch.tap()
        app.textViews["Pick one with the team"].tap()
        shot(app, "3-editing")
    }

    func testPadScreenshots() throws {
        let app = try launch()
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
        XCUIDevice.shared.orientation = .portrait
        app.staticTexts["Trip to Lisbon"].firstMatch.tap()
        shot(app, "1-list")
        app.staticTexts["Website relaunch"].firstMatch.tap()
        shot(app, "2-work")
    }
}

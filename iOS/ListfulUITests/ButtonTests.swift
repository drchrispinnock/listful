import XCTest

/// Drives the app's row buttons and keyboard bar against a scratch folder
/// (DEBUG builds read `-testFolder`), checking the file each one changes.
/// The simulator shares the Mac's file system, so the test can read the
/// file the app writes.
@MainActor
final class ButtonTests: XCTestCase {
    private var folder: URL!
    private var plan: URL { folder.appending(path: "Work/Plan.md") }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "ListfulUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Work"), withIntermediateDirectories: true)
        try "- [ ] Plan\n  - [ ] Step one\n  - [ ] Step two\n- [ ] Review\n".write(to: plan, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func fileText() -> String {
        (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
    }

    /// Waits for the debounced save to write what's expected.
    private func expectFile(_ text: String, _ message: String) {
        let deadline = Date().addingTimeInterval(5)
        while fileText() != text && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual(fileText(), text, message)
    }

    func testRowButtonsAndKeyboardBar() {
        let app = XCUIApplication()
        app.launchArguments = ["-testFolder", folder.path]
        app.launch()
        if app.staticTexts["Work"].exists && !app.staticTexts["Plan"].exists { app.staticTexts["Work"].tap() }
        app.staticTexts["Plan"].firstMatch.tap()

        app.buttons["Mark done"].firstMatch.tap()
        expectFile("- [x] Plan\n  - [ ] Step one\n  - [ ] Step two\n- [ ] Review\n", "tick")

        app.textViews["Step two"].tap()
        app.buttons["Indent"].tap()
        expectFile("- [x] Plan\n  - [ ] Step one\n    - [ ] Step two\n- [ ] Review\n", "indent")

        app.buttons["Outdent"].tap()
        app.buttons["Move Up"].tap()
        expectFile("- [x] Plan\n  - [ ] Step two\n  - [ ] Step one\n- [ ] Review\n", "outdent, move up")

        app.buttons["Hide Keyboard"].tap()
        app.buttons["Collapse"].firstMatch.tap()
        expectFile("- [x] Plan <!-- listful: collapsed -->\n  - [ ] Step two\n  - [ ] Step one\n- [ ] Review\n", "collapse")
    }

    /// New Task, type, Return: the cursor is on a new, empty task (no stray
    /// line break in it), and what's typed next goes there; again, twice.
    func testReturnStartsNextTask() {
        let app = XCUIApplication()
        app.launchArguments = ["-testFolder", folder.path]
        app.launch()
        if app.staticTexts["Work"].exists && !app.staticTexts["Plan"].exists { app.staticTexts["Work"].tap() }
        app.staticTexts["Plan"].firstMatch.tap()
        app.buttons["New Task"].tap()
        for word in ["Test", "More"] {
            app.typeText(word)
            app.typeText("\n")
            XCTAssertEqual(app.textViews.allElementsBoundByIndex.last?.value as? String, "", "new row after \(word) is empty")
        }
        app.typeText("Again")
        expectFile("- [ ] Plan\n  - [ ] Step one\n  - [ ] Step two\n- [ ] Review\n- [ ] Test\n- [ ] More\n- [ ] Again\n", "typed rows")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "after return"; a.lifetime = .keepAlways; add(a)

        // Return mid-text splits there.
        let review = app.textViews["Review"]
        review.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).tap()
        app.typeText("A\n")
        expectFile("- [ ] Plan\n  - [ ] Step one\n  - [ ] Step two\n- [ ] A\n- [ ] Review\n- [ ] Test\n- [ ] More\n- [ ] Again\n", "split at cursor")
    }
}

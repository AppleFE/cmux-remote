import XCTest

extension SmokeUITests {
    func assertBrowserSurfaceVisible(in app: XCUIApplication) {
        XCTAssertTrue(app.otherElements["BrowserRemoteViewport"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["BrowserScreenshotImage"].waitForExistence(timeout: 5))
        assertNoBrowserError(in: app)
    }

    func assertTerminalSurfaceHidden(in app: XCUIApplication) {
        XCTAssertFalse(app.scrollViews["TerminalViewport"].exists)
        XCTAssertFalse(app.otherElements["TerminalAccessoryPanel"].exists)
        XCTAssertFalse(app.buttons["TerminalScrollToBottomButton"].exists)
    }

    func assertNoBrowserError(in app: XCUIApplication) {
        XCTAssertFalse(app.descendants(matching: .any)["BrowserErrorMessage"].exists)
    }
}

extension XCUIElement {
    func waitForValue(_ expected: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForValueContaining(_ marker: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", marker)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

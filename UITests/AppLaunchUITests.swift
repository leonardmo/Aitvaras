import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
    func testAppOpensItsMainWindowAndCapturesIt() {
        let app = E2EApp.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        E2EApp.screenshot(app, named: "launch", in: self)
    }
}

import XCTest

/// Launches the real app with a throwaway profile. The bundle id comes from
/// `make e2e`, so the installed app is never touched.
@MainActor
enum E2EApp {
    static func launch(_ arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-e2e-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment = ["AITVARAS_STATE_DIR": state.path,
                                 "AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS": "1"]
            .merging(environment) { _, new in new }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// A real capture of the window as macOS draws it, kept in the result bundle.
    static func screenshot(_ app: XCUIApplication, named name: String, in test: XCTestCase) {
        let window = app.windows.firstMatch
        let image = window.exists ? window.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}

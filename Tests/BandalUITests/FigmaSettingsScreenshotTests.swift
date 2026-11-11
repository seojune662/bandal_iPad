import XCTest

/// Captures for the side-by-side comparison with the Figma settings frames (132:2769, 132:2998, 132:3229,
/// 132:3441, 132:3654, 132:3879, 132:4097 and their dark twins on 137:3093), and of each section's 더 보기 page.
/// Each test only drives and attaches; behaviour is asserted in `NativeSettingsParityUITests`.
final class FigmaSettingsScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor func testLight() throws { try capture("light") }
    @MainActor func testDark() throws { try capture("dark") }
    @MainActor func testMorePages() throws { try capture("light", more: true) }

    @MainActor private func capture(_ appearance: String, more: Bool = false) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing", "--native-settings-account-fixture", "--native-settings-plan-fixture",
                               "--native-ai-usage-fixture", "-native.appearance", appearance]
        app.launch()
        let settings = app.buttons["native-section-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25), app.debugDescription); settings.tap()
        for (index, id) in ["general", "appearance", "account", "subscription", "ai", "sync", "integrations"].enumerated() {
            let row = app.buttons["native-settings-category-" + id]
            XCTAssertTrue(row.waitForExistence(timeout: 15), id)
            for _ in 0..<5 where !row.isSelected { row.tap(); sleep(1) }
            sleep(1)
            if more {
                app.openNativeSettingsMore(); sleep(1)
            }
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "\(appearance) \(index + 1) \(id)" + (more ? " more" : ""); shot.lifetime = .keepAlways; add(shot)
        }
    }
}

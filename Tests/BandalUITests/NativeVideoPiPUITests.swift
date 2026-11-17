import XCTest

/// 영상 PiP inside the app, offline: a downloaded video and a web page's video move into the floating window,
/// keep playing, move and resize, and go back to their tab. Leaving a playing tab moves its video there by itself.
final class NativeVideoPiPUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testDownloadedVideoMovesToPiPAndBack() throws {
        let app = launch(["--native-video-fixture"])
        let material = app.buttons["native-material-PiP 테스트 영상.mp4"]
        XCTAssertTrue(material.waitForExistence(timeout: 60), app.debugDescription); material.tap()
        let start = app.buttons["native-video-pip-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), app.debugDescription)
        attach(app, "video tab with PiP button")
        start.tap()

        let window = app.otherElements["native-video-pip-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.otherElements["native-video-pip-placeholder"].waitForExistence(timeout: 3), "The tab says the video plays in PiP")
        XCTAssertTrue(app.buttons["native-video-pip-bring-back"].exists)
        let play = app.buttons["native-video-pip-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3), "The controls show when the window opens")
        if play.label == "재생" { play.tap() }
        let started = waitForProgress(app, atLeast: 2)
        attach(app, "playing in PiP")

        movesAndResizes(app, window: window, aspect: 16.0 / 9.0)

        // 돌아가기: the same player goes back to the tab, still playing, from where it was.
        showControls(app, window: window)
        app.buttons["native-video-pip-return"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.otherElements["native-video-pip-placeholder"].exists)
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        sleep(2)
        start.tap()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["native-video-pip-play"].label, "일시정지", "It kept playing in the tab")
        XCTAssertGreaterThanOrEqual(waitForProgress(app, atLeast: started + 2), started + 2, "It went on from where it was")

        // ✕ stops it; the tab shows its player again.
        app.buttons["native-video-pip-close"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["native-video-pip-placeholder"].exists)
        XCTAssertTrue(start.waitForExistence(timeout: 5))

        // Leaving the tab while it plays: the video goes on in PiP by itself (설정 › 일반 › 영상, on by default).
        start.tap(); XCTAssertTrue(window.waitForExistence(timeout: 5))
        if app.buttons["native-video-pip-play"].label == "재생" { app.buttons["native-video-pip-play"].tap() }
        app.buttons["native-video-pip-return"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5)); sleep(1)
        openMarkdownTab(app)
        XCTAssertTrue(window.waitForExistence(timeout: 8), "Choosing another tab moved the playing video to PiP\n" + app.debugDescription)
        attach(app, "auto PiP over a markdown tab")
        // With the software keyboard up, the window stays above it.
        if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            sleep(1)
            XCTAssertLessThanOrEqual(window.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "The window keeps clear of the keyboard")
            attach(app, "PiP above the keyboard")
        }
        showControls(app, window: window)
        app.buttons["native-video-pip-close"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
    }

    @MainActor func testWebVideoMovesToPiPAndBack() throws {
        let app = launch(["--native-browser-ui-fixture", "--native-video-web-fixture"])
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
        let heading = app.webViews.staticTexts["Video fixture"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20), app.debugDescription)
        // The address bar offers PiP once the page's video plays.
        let start = app.buttons["native-video-pip-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), app.debugDescription)
        attach(app, "browser with a playing video")
        start.tap()

        let window = app.otherElements["native-video-pip-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.otherElements["native-video-pip-placeholder"].waitForExistence(timeout: 3))
        let started = waitForProgress(app, atLeast: 1)
        XCTAssertEqual(app.buttons["native-video-pip-play"].label, "일시정지", "The page's video keeps playing in the window")
        attach(app, "web video in PiP")
        // The window shows only the video (640 × 360), not the page around it.
        movesAndResizes(app, window: window, aspect: 16.0 / 9.0)

        // Pause and play reach the page's video.
        showControls(app, window: window)
        app.buttons["native-video-pip-play"].tap()
        XCTAssertTrue(app.buttons["native-video-pip-play"].waitForLabel("재생", timeout: 3))
        app.buttons["native-video-pip-play"].tap()
        XCTAssertTrue(app.buttons["native-video-pip-play"].waitForLabel("일시정지", timeout: 3))

        // 돌아가기: the web view goes back into its tab and plays on.
        app.buttons["native-video-pip-return"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["native-video-pip-placeholder"].exists)
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        attach(app, "web video back in its tab")

        // Closing the tab while it plays: the video goes on in PiP, and 돌아가기 opens the tab again with the same page.
        app.buttons["native-close-document"].firstMatch.tap()
        XCTAssertTrue(window.waitForExistence(timeout: 8), "Closing a playing tab moved its video to PiP\n" + app.debugDescription)
        XCTAssertGreaterThanOrEqual(waitForProgress(app, atLeast: started + 1), started + 1)
        attach(app, "closed tab's video in PiP")
        showControls(app, window: window)
        app.buttons["native-video-pip-return"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(heading.waitForExistence(timeout: 8), "The tab came back with its page\n" + app.debugDescription)

        // Choosing another tab while it plays: PiP again; ✕ ends it.
        sleep(1)
        openMarkdownTab(app)
        XCTAssertTrue(window.waitForExistence(timeout: 8), "Choosing another tab moved the playing video to PiP\n" + app.debugDescription)
        showControls(app, window: window)
        app.buttons["native-video-pip-close"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
    }

    /// Opt-in, on the network: YouTube opens as its mobile site (a tap shows its controls instead of pausing),
    /// and its player goes into PiP and back. Set BANDAL_VERIFY_LIVE_YOUTUBE=1.
    @MainActor func testLiveYouTubeInPiP() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_VERIFY_LIVE_YOUTUBE"] == "1",
                          "Set BANDAL_VERIFY_LIVE_YOUTUBE=1 to try a real YouTube video.")
        let app = launch([])
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap(); app.buttons["native-new-tab-new-browser"].tap()
        let address = app.textFields["native-browser-address"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15)); sleep(3)
        address.tap(); address.typeText("https://www.youtube.com/watch?v=aqz-KE-bpKQ\n")
        let mobile = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] %@", "m.youtube.com"), object: address)
        XCTAssertEqual(XCTWaiter.wait(for: [mobile], timeout: 30), .completed, "YouTube opens as its mobile site\n" + app.debugDescription)
        sleep(8); attach(app, "YouTube mobile watch page")
        let web = app.webViews.firstMatch
        // The player sits at the top of the mobile watch page, as wide as the page.
        let player = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: web.frame.width / 2, dy: web.frame.width * 9 / 32))
        player.tap(); sleep(6); attach(app, "after a tap: playing")
        player.tap(); usleep(600_000); attach(app, "a tap while playing: controls, still playing")
        sleep(5); attach(app, "five seconds later")
        let start = app.buttons["native-video-pip-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), app.debugDescription)
        start.tap()
        let window = app.otherElements["native-video-pip-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let started = waitForProgress(app, atLeast: 1, timeout: 30)
        sleep(4); attach(app, "YouTube in PiP")
        XCTAssertGreaterThan(waitForProgress(app, atLeast: started + 3, timeout: 30), started, "It plays on in PiP")
        openMarkdownTab(app); sleep(3); attach(app, "YouTube in PiP over a note")
        showControls(app, window: window)
        app.buttons["native-video-pip-return"].tap()
        XCTAssertTrue(window.waitForNonExistence(timeout: 8), app.debugDescription)
        sleep(3); attach(app, "YouTube back in its tab")
    }

    // MARK: Steps

    @MainActor private func movesAndResizes(_ app: XCUIApplication, window: XCUIElement, aspect: CGFloat) {
        let before = window.frame
        XCTAssertEqual(before.width / before.height, aspect, accuracy: 0.06, "The window has the video's shape")
        // Drag it to the left edge: it lands against it (12 pt margin) and stays whole on screen.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.15, thenDragTo: origin.withOffset(CGVector(dx: 40 + before.width / 2, dy: 420)))
        sleep(1)
        let moved = window.frame
        XCTAssertLessThan(moved.minX, before.minX - 100, "It moved\n\(before) → \(moved)")
        XCTAssertLessThanOrEqual(moved.minX, 40, "It snapped to the left edge: \(moved)")
        XCTAssertGreaterThanOrEqual(moved.minX, 0)
        attach(app, "PiP moved to the left edge")
        // Drag its bottom-right corner outward: larger, same shape, top-left corner where it was.
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moved.width - 8, dy: moved.height - 8))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moved.width + 120, dy: moved.height + 68)))
        sleep(1)
        let resized = window.frame
        XCTAssertGreaterThan(resized.width, moved.width + 60, "It grew\n\(moved) → \(resized)")
        XCTAssertEqual(resized.width / resized.height, aspect, accuracy: 0.06, "It kept the video's shape")
        XCTAssertEqual(resized.minX, moved.minX, accuracy: 2); XCTAssertEqual(resized.minY, moved.minY, accuracy: 2)
        attach(app, "PiP resized from its corner")
        // Two fingers spread: larger still. (XCUITest's closing pinch starts on the element's very corners, outside it.)
        window.pinch(withScale: 1.5, velocity: 1)
        sleep(1)
        let pinched = window.frame
        XCTAssertGreaterThan(pinched.width, resized.width + 40, "A pinch made it larger\n\(resized) → \(pinched)")
        XCTAssertEqual(pinched.width / pinched.height, aspect, accuracy: 0.06)
        // The corner pushed far inward: it stops at the minimum width.
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: pinched.width - 8, dy: pinched.height - 8))
            .press(forDuration: 0.15, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 12)))
        sleep(1)
        XCTAssertEqual(window.frame.width, 200, accuracy: 1, "Not smaller than the minimum")
        attach(app, "PiP at its smallest")
    }
    /// The controls hide a while into playback; a tap brings them back.
    @MainActor private func showControls(_ app: XCUIApplication, window: XCUIElement) {
        if app.buttons["native-video-pip-close"].exists { return }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(app.buttons["native-video-pip-close"].waitForExistence(timeout: 3), app.debugDescription)
    }
    /// Seconds played, read from the window's progress line; waits until it reaches `seconds`.
    @discardableResult
    @MainActor private func waitForProgress(_ app: XCUIApplication, atLeast seconds: Int, timeout: TimeInterval = 20) -> Int {
        let progress = app.descendants(matching: .any)["native-video-pip-progress"]
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        while Date() < deadline {
            if !progress.exists, let window = Optional(app.otherElements["native-video-pip-window"]), window.exists {
                showControls(app, window: window)
            }
            if let value = progress.value as? String, let played = value.split(separator: "/").first.map({ Self.seconds(String($0)) }) {
                last = played
                if played >= seconds { return played }
            }
            usleep(500_000)
        }
        XCTFail("Progress stayed at \(last) s, expected \(seconds) s\n" + app.debugDescription)
        return last
    }
    private static func seconds(_ clock: String) -> Int {
        clock.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }
    @MainActor private func openMarkdownTab(_ app: XCUIApplication) {
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-dock-add-")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let markdown = app.buttons["native-new-tab-new-note"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 5), app.debugDescription); markdown.tap()
    }
    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-testing", "--reset-native-ui-testing"] + arguments
        app.launch()
        let addCourse = app.buttons["native-course-add-menu"]
        XCTAssertTrue(addCourse.waitForExistence(timeout: 25), app.debugDescription); addCourse.tap()
        let name = app.textFields["native-course-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("영상")
        app.buttons["native-create-course"].tap()
        return app
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: self)], timeout: timeout) == .completed
    }
}

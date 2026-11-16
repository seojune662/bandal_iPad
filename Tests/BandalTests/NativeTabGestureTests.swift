import XCTest
@testable import Bandal

/// The three-finger rules, fed recorded positions. Fingers sit on a circle round (500, 400); `radius` is their spread.
final class NativeTabGestureTests: XCTestCase {
    private static let centre = CGPoint(x: 500, y: 400)
    private static func ring(_ radius: CGFloat, turn: CGFloat = 0) -> [CGPoint] {
        (0..<3).map { index in
            let angle = turn + CGFloat(index) * 2 * .pi / 3
            return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
    }
    /// Lands three fingers at `radius` (`gaps` apart in time), moves them through `path` and lifts the first one.
    private func run(start radius: CGFloat, path: [CGFloat], gaps: [TimeInterval] = [0, 0.03, 0.06], duration: TimeInterval = 0.4,
                     tracker: inout NativeTabGestureTracker) -> (started: Bool, outcome: NativeTabGestureTracker.Outcome?) {
        var started = false
        for (index, point) in Self.ring(radius).enumerated() {
            if case .started = tracker.began(index, at: point, time: 10 + gaps[index]) { started = true }
        }
        for step in path { for (index, point) in Self.ring(step).enumerated() { tracker.moved(index, to: point) } }
        let end = Self.ring(path.last ?? radius)
        let outcome = tracker.ended(0, at: end[0], time: 10 + gaps[2] + duration)
        tracker.ended(1, at: end[1], time: 10 + gaps[2] + duration + 0.02)
        tracker.ended(2, at: end[2], time: 10 + gaps[2] + duration + 0.03)
        return (started, outcome)
    }
    private func decide(start: CGFloat, path: [CGFloat], gaps: [TimeInterval] = [0, 0.03, 0.06], duration: TimeInterval = 0.4) -> NativeTabGestureTracker.Outcome? {
        var tracker = NativeTabGestureTracker()
        return run(start: start, path: path, gaps: gaps, duration: duration, tracker: &tracker).outcome
    }

    func testSpreadIsTheMeanDistanceFromTheCentre() {
        XCTAssertEqual(NativeTabGestureTracker.spread(Self.ring(120)), 120, accuracy: 0.001)
        XCTAssertEqual(NativeTabGestureTracker.centroid(Self.ring(80)).x, Self.centre.x, accuracy: 0.001)
        XCTAssertEqual(NativeTabGestureTracker.spread([]), 0)
    }

    func testPinchClosesTheTab() {
        XCTAssertEqual(decide(start: 140, path: [120, 100, 80, 70]), .decided(.close))
        // Exactly at 65 %.
        XCTAssertEqual(decide(start: 100, path: [80, 65]), .decided(.close))
    }

    func testSpreadFromFingersHeldTogetherOpensATab() {
        XCTAssertEqual(decide(start: 50, path: [60, 70, 80]), .decided(.open))
    }

    func testPinchThenSpreadBackOpensATab() {
        XCTAssertEqual(decide(start: 140, path: [110, 80, 60, 90, 130, 145]), .decided(.open))
    }

    func testPinchThenSpreadThatStopsShortOfTheStartDoesNothing() {
        // Back up to 130 of 140: wider than 1.5 × the narrowest, yet narrower than at the start.
        XCTAssertEqual(decide(start: 140, path: [100, 60, 130]), .decided(nil))
    }

    func testSmallMovementAndTremorDoNothing() {
        XCTAssertEqual(decide(start: 120, path: [115, 110, 105]), .decided(nil))
        XCTAssertEqual(decide(start: 120, path: [123, 117, 124, 118, 121]), .decided(nil))
        // Fingers close together: a 65 % pinch of a 40-point spread is a tremor, under the 20-point minimum.
        XCTAssertEqual(decide(start: 40, path: [30, 25]), .decided(nil))
    }

    func testTooSlowDoesNothing() {
        XCTAssertEqual(decide(start: 140, path: [100, 70], duration: 2.5), .decided(nil))
    }

    func testArmedFollowsTheFingersBeforeLifting() {
        var tracker = NativeTabGestureTracker()
        for (index, point) in Self.ring(140).enumerated() { tracker.began(index, at: point, time: Double(index) * 0.02) }
        XCTAssertEqual(tracker.phase, .tracking)
        XCTAssertNil(tracker.armed)
        for (index, point) in Self.ring(80).enumerated() { tracker.moved(index, to: point) }
        XCTAssertEqual(tracker.armed, .close)
        // Back where they started: the preview goes away.
        for (index, point) in Self.ring(135).enumerated() { tracker.moved(index, to: point) }
        XCTAssertNil(tracker.armed)
        for (index, point) in Self.ring(150).enumerated() { tracker.moved(index, to: point) }
        XCTAssertEqual(tracker.armed, .open)
    }

    func testLateThirdFingerStartsNothing() {
        var tracker = NativeTabGestureTracker()
        let result = run(start: 140, path: [70], gaps: [0, 0.05, 0.2], tracker: &tracker)
        XCTAssertFalse(result.started)
        XCTAssertNil(result.outcome)
        XCTAssertEqual(tracker.phase, .idle, "Once every finger is up the next touch starts afresh")
    }

    func testFourthFingerAbandonsTheGesture() {
        var tracker = NativeTabGestureTracker()
        for (index, point) in Self.ring(140).enumerated() { tracker.began(index, at: point, time: Double(index) * 0.02) }
        XCTAssertEqual(tracker.began(3, at: CGPoint(x: 700, y: 400), time: 0.1), .abandoned)
        for (index, point) in Self.ring(60).enumerated() { tracker.moved(index, to: point) }
        XCTAssertNil(tracker.ended(0, at: .zero, time: 0.4), "A pinch after the fourth finger closes nothing")
    }

    func testFingerLiftedBeforeTheThirdLandsStartsNothing() {
        var tracker = NativeTabGestureTracker()
        let ring = Self.ring(140)
        tracker.began(0, at: ring[0], time: 0); tracker.began(1, at: ring[1], time: 0.02)
        tracker.ended(1, at: ring[1], time: 0.04)
        XCTAssertNil(tracker.began(2, at: ring[2], time: 0.06))
        XCTAssertEqual(tracker.phase, .ignored)
    }

    func testCancelledTouchAbandonsTheGesture() {
        var tracker = NativeTabGestureTracker()
        for (index, point) in Self.ring(140).enumerated() { tracker.began(index, at: point, time: Double(index) * 0.02) }
        for (index, point) in Self.ring(60).enumerated() { tracker.moved(index, to: point) }
        XCTAssertEqual(tracker.ended(0, at: Self.ring(60)[0], time: 0.3, cancelled: true), .abandoned)
    }

    func testPencilDownOrJustLiftedIgnoresFingers() {
        var tracker = NativeTabGestureTracker()
        tracker.pencil(down: true, time: 5)
        tracker.pencil(down: false, time: 5.2)
        // 0.3 s after the Pencil lifted: a palm, not a gesture.
        for (index, point) in Self.ring(140).enumerated() { XCTAssertNil(tracker.began(index, at: point, time: 5.5 + Double(index) * 0.02)) }
        XCTAssertEqual(tracker.phase, .ignored)
        for (index, point) in Self.ring(60).enumerated() { XCTAssertNil(tracker.ended(index, at: point, time: 5.9)) }
        // Well after it: a gesture again.
        var started = false
        for (index, point) in Self.ring(140).enumerated() { if case .started = tracker.began(index, at: point, time: 7 + Double(index) * 0.02) { started = true } }
        XCTAssertTrue(started)
        tracker.reset()
        // The event says the Pencil is on the screen, though this tracker never saw it land.
        XCTAssertNil(tracker.began(0, at: Self.ring(140)[0], time: 20, pencilDown: true))
        XCTAssertEqual(tracker.phase, .ignored)
    }

    func testPencilLandingDuringTheGestureAbandonsIt() {
        var tracker = NativeTabGestureTracker()
        for (index, point) in Self.ring(140).enumerated() { tracker.began(index, at: point, time: Double(index) * 0.02) }
        tracker.pencil(down: true, time: 0.2)
        for (index, point) in Self.ring(60).enumerated() { tracker.moved(index, to: point) }
        XCTAssertNil(tracker.ended(0, at: Self.ring(60)[0], time: 0.4))
    }

    func testDecideIsThePureRule() {
        XCTAssertEqual(NativeTabGestureTracker.decide(start: 100, narrowest: 60, end: 60, duration: 0.5), .close)
        XCTAssertEqual(NativeTabGestureTracker.decide(start: 100, narrowest: 60, end: 100, duration: 0.5), .open)
        XCTAssertNil(NativeTabGestureTracker.decide(start: 100, narrowest: 60, end: 95, duration: 0.5))
        XCTAssertNil(NativeTabGestureTracker.decide(start: 100, narrowest: 60, end: 60, duration: 1.6))
        XCTAssertNil(NativeTabGestureTracker.decide(start: 0, narrowest: 0, end: 0, duration: 0.1))
    }
}

/// Where the spread opens to and how its choice is saved.
final class NativeTabGesturePreferencesTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NativeTabGesturePreferences.enabledKey)
        UserDefaults.standard.removeObject(forKey: NativeTabGesturePreferences.openKindKey)
        super.tearDown()
    }

    func testOnByDefaultAndSaved() {
        UserDefaults.standard.removeObject(forKey: NativeTabGesturePreferences.enabledKey)
        XCTAssertTrue(NativeTabGesturePreferences.enabled)
        XCTAssertEqual(NativeTabGesturePreferences.editingInteraction, .none, "On: the app's editors hand three fingers to the tab gesture")
        UserDefaults.standard.set(false, forKey: NativeTabGesturePreferences.enabledKey)
        XCTAssertFalse(NativeTabGesturePreferences.enabled)
        XCTAssertEqual(NativeTabGesturePreferences.editingInteraction, .default, "Off: iPadOS's copy, paste and undo come back")
    }

    func testSpreadOpensTheMenuUntilAKindIsChosen() {
        UserDefaults.standard.removeObject(forKey: NativeTabGesturePreferences.openKindKey)
        XCTAssertNil(NativeTabGesturePreferences.openAction)
        UserDefaults.standard.set("new-browser", forKey: NativeTabGesturePreferences.openKindKey)
        XCTAssertEqual(NativeTabGesturePreferences.openAction, .browser(url: nil))
        UserDefaults.standard.set("new-note", forKey: NativeTabGesturePreferences.openKindKey)
        XCTAssertEqual(NativeTabGesturePreferences.openAction, .markdown(title: nil))
        UserDefaults.standard.set(NativeTabGesturePreferences.choose, forKey: NativeTabGesturePreferences.openKindKey)
        XCTAssertNil(NativeTabGesturePreferences.openAction)
        // A kind that is no longer offered falls back to the menu.
        UserDefaults.standard.set("gone", forKey: NativeTabGesturePreferences.openKindKey)
        XCTAssertNil(NativeTabGesturePreferences.openAction)
    }

    func testKindsAreTheNewTabMenusRows() {
        XCTAssertEqual(NativeTabGesturePreferences.kinds.map(\.id), NativeNewTabCatalog.items(query: "").map(\.id))
        XCTAssertEqual(NativeTabGesturePreferences.kinds.contains { $0.id == "recording" }, NativeReleaseFlags.showsRecording)
    }

    func testSettingsSearchFindsTheGesture() {
        for word in ["세 손가락", "손가락", "제스처", "탭"] {
            XCTAssertTrue(NativeSettingsCatalog.matching(word).contains { $0.id == "general" }, word)
        }
        XCTAssertTrue(NativeSettingsCatalog.matching("gesture", locale: "en-US").contains { $0.id == "general" })
        XCTAssertEqual(NativeSettingsCatalog.resolve("tab-gestures"), "general")
        XCTAssertEqual(NativeSettingsCatalog.subpage("tab-gestures"), "more")
    }
}

/// 되돌리기 after a three-finger close: the same document back in the same pane, at the same place.
@MainActor
final class NativeClosedTabTests: XCTestCase {
    private func document(_ path: String) -> NativeDocumentReference {
        .init(courseID: "course-a", relativePath: path, title: path, kind: "note")
    }

    func testReopenPutsTheTabBackWhereItWas() throws {
        let navigation = NativeWorkspaceNavigation()
        let a = document("a.md"), b = document("b.md"), c = document("c.md")
        navigation.open(a); navigation.open(b); navigation.open(c)
        let group = try XCTUnwrap(navigation.layout?.focused)
        navigation.select(b.id, in: group.id)
        let record = try XCTUnwrap(navigation.closedTab(b.id))
        XCTAssertEqual(record.index, 1)
        navigation.closeTab(b.id)
        XCTAssertEqual(navigation.groups.first?.tabs, [a.id, c.id])
        XCTAssertNil(navigation.document(b.id))
        XCTAssertTrue(navigation.reopen(record))
        XCTAssertEqual(navigation.groups.first?.tabs, [a.id, b.id, c.id])
        XCTAssertEqual(navigation.activeID, b.id)
        XCTAssertEqual(navigation.document(b.id), b)
    }

    func testReopenAfterTheLastTabOfASplitPane() throws {
        let navigation = NativeWorkspaceNavigation()
        let a = document("a.md"), b = document("b.md")
        navigation.open(a); navigation.open(b)
        navigation.move(b.id, to: try XCTUnwrap(navigation.layout?.focused?.id), direction: .right)
        let pane = try XCTUnwrap(navigation.group(containing: b.id))
        XCTAssertEqual(navigation.groups.count, 2)
        let record = try XCTUnwrap(navigation.closedTab(b.id))
        navigation.closeTab(b.id)
        XCTAssertTrue(navigation.groups.contains { $0.id == pane.id && $0.tabs.isEmpty }, "✕ on a pane's last tab leaves the pane, empty")
        XCTAssertTrue(navigation.reopen(record))
        XCTAssertEqual(navigation.group(containing: b.id)?.id, pane.id)
        XCTAssertEqual(navigation.focusedGroupID, pane.id)
    }

    func testReopenIntoTheFocusedPaneWhenItsOwnIsGone() throws {
        let navigation = NativeWorkspaceNavigation()
        let a = document("a.md"), b = document("b.md")
        navigation.open(a); navigation.open(b)
        navigation.move(b.id, to: try XCTUnwrap(navigation.layout?.focused?.id), direction: .right)
        let pane = try XCTUnwrap(navigation.group(containing: b.id))
        let record = try XCTUnwrap(navigation.closedTab(b.id))
        navigation.closeTab(b.id)
        navigation.removeEmptyGroup(pane.id)
        XCTAssertEqual(navigation.groups.count, 1)
        XCTAssertTrue(navigation.reopen(record))
        XCTAssertEqual(navigation.groups.first?.tabs, [a.id, b.id])
    }

    func testReopenOfATabStillOpenOnlyChoosesIt() throws {
        let navigation = NativeWorkspaceNavigation()
        let a = document("a.md"), b = document("b.md")
        navigation.open(a); navigation.open(b)
        let record = try XCTUnwrap(navigation.closedTab(a.id))
        XCTAssertTrue(navigation.reopen(record))
        XCTAssertEqual(navigation.groups.first?.tabs, [a.id, b.id], "Never placed twice")
        XCTAssertEqual(navigation.activeID, a.id)
    }
}

import XCTest
@testable import Bandal

final class NativePlannerBoardTests: XCTestCase {
    private func task(_ id: String = "task", due: String?, allDay: Bool = true, status: String = "todo") throws -> NativePlannerTask {
        try NativeToolJSON.decode([
            "id": id, "courseId": NSNull(), "title": id, "notes": "", "status": status, "kind": "task", "color": "none",
            "dueAt": due.map { $0 as Any } ?? NSNull(), "startAt": NSNull(), "allDay": allDay
        ])
    }
    private func day(_ value: String) throws -> Date { try XCTUnwrap(NativePlannerTask.dayFormatter.date(from: value)) }

    func testDueBadgeCountsWholeDaysAndTurnsUrgentFromTheDayBefore() throws {
        // Arrange: 3 pm on the 10th.
        let now = try day("2026-11-10").addingTimeInterval(15 * 3600)

        // Act
        let far = try XCTUnwrap(task(due: "2026-11-14").dueBadge(now: now))
        let tomorrow = try XCTUnwrap(task(due: "2026-11-11").dueBadge(now: now))
        let today = try XCTUnwrap(task(due: "2026-11-10").dueBadge(now: now))
        let overdue = try XCTUnwrap(task(due: "2026-11-08").dueBadge(now: now))

        // Assert
        XCTAssertEqual(far.label, "D-4"); XCTAssertFalse(far.urgent)
        XCTAssertEqual(tomorrow.label, "D-1"); XCTAssertTrue(tomorrow.urgent)
        XCTAssertEqual(today.label, "D-DAY"); XCTAssertTrue(today.urgent)
        XCTAssertEqual(overdue.label, "D+2"); XCTAssertTrue(overdue.urgent)
    }

    func testDueBadgeIsAbsentWithoutADueDateOrOnceDone() throws {
        let now = try day("2026-11-10")
        XCTAssertNil(try task(due: nil).dueBadge(now: now))
        XCTAssertNil(try task(due: "2026-11-11", status: "done").dueBadge(now: now), "A finished task has no countdown")
    }

    func testTimedDueLateTomorrowIsOneDayAwayNotTwo() throws {
        let now = try day("2026-11-10").addingTimeInterval(9 * 3600)
        let due = ISO8601DateFormatter().string(from: try day("2026-11-11").addingTimeInterval(23 * 3600 + 59 * 60))
        XCTAssertEqual(try task(due: due, allDay: false).dueBadge(now: now)?.label, "D-1")
    }

    func testBoardOrderPutsTheNearestDueFirstAndUndatedLast() throws {
        let tasks = [try task("undated", due: nil), try task("later", due: "2026-11-16"), try task("sooner", due: "2026-11-11")]
        XCTAssertEqual(tasks.sorted(by: NativePlannerTask.boardOrder).map(\.id), ["sooner", "later", "undated"])
    }

    func testUpcomingSkipsDoneUndatedAndOverdueAndKeepsTheNearestTwo() throws {
        let now = try day("2026-11-10").addingTimeInterval(12 * 3600)
        let tasks = [try task("third", due: "2026-11-13"), try task("done", due: "2026-11-11", status: "done"), try task("overdue", due: "2026-11-09"),
                     try task("undated", due: nil), try task("second", due: "2026-11-12"), try task("first", due: "2026-11-11")]
        XCTAssertEqual(NativePlannerTask.upcoming(tasks, now: now).map(\.id), ["first", "second"])
    }

    func testStackedSectionsSplitTheHeightEquallyWhileEverythingFits() {
        XCTAssertEqual(NativePlannerSectionStack.heights(ideal: [298, 208, 219], available: 942), [314, 314, 314])
        XCTAssertEqual(NativePlannerSectionStack.heights(ideal: [], available: 942), [])
    }

    func testStackedSectionTallerThanItsShareKeepsItsHeightWhileThereIsRoom() {
        // Ten tasks in 할 일 need more than a third, and the three still fit: the spare goes to the shortest section.
        XCTAssertEqual(NativePlannerSectionStack.heights(ideal: [527, 182, 223], available: 947), [527, 197, 223])
        XCTAssertEqual(NativePlannerSectionStack.heights(ideal: [300, 300, 347], available: 947), [300, 300, 347])
    }

    func testStackedSectionThatOverflowsTakesWhatTheShortOnesLeave() {
        // The portrait frame with thirteen tasks: the two short sections keep their own height, 할 일 scrolls in the rest.
        XCTAssertEqual(NativePlannerSectionStack.heights(ideal: [1500, 208, 216], available: 941), [517, 208, 216])
        XCTAssertEqual(NativePlannerSectionStack.heights(ideal: [900, 700, 100], available: 900), [400, 400, 100])
    }

    func testDueStripStartsTodayOrAtAnEarlierDueDay() throws {
        let today = try day("2026-11-10")
        XCTAssertEqual(NativeTaskEditor.stripDays(today: today, due: nil).first, today)
        XCTAssertEqual(NativeTaskEditor.stripDays(today: today, due: try day("2026-11-14")).first, today)
        XCTAssertEqual(NativeTaskEditor.stripDays(today: today, due: try day("2026-11-03").addingTimeInterval(3600)).first, try day("2026-11-03"))
        XCTAssertTrue(NativeTaskEditor.stripDays(today: today, due: try day("2027-03-01")).contains(try day("2027-03-01")), "A far due day is still on the strip")
    }

    func testEditorLeavesAnUntouchedDueDateOutOfTheRequest() throws {
        // A timed task with seconds the sheet cannot show: saving a rename must not rewrite it.
        let stored = ISO8601DateFormatter().string(from: try day("2026-11-11").addingTimeInterval(10 * 3600 + 30))
        let timed = try task(due: stored, allDay: false), original = try XCTUnwrap(timed.dueDate)
        XCTAssertTrue(NativeTaskEditor.dueFields(task: timed, day: Calendar.current.startOfDay(for: original), allDay: false, time: original).isEmpty)
        // No due date, whatever the stored flag.
        XCTAssertTrue(NativeTaskEditor.dueFields(task: try task(due: nil, allDay: false), day: nil, allDay: true, time: Date()).isEmpty)
        XCTAssertTrue(NativeTaskEditor.dueFields(task: try task(due: "2026-11-11"), day: try day("2026-11-11"), allDay: true, time: Date()).isEmpty)
    }

    func testEditorSendsTheDayAloneForAllDayAndTheChosenMinuteOtherwise() throws {
        let chosen = try day("2026-11-14")
        let allDay = NativeTaskEditor.dueFields(task: nil, day: chosen, allDay: true, time: Date())
        XCTAssertEqual(allDay["dueAt"] as? String, "2026-11-14"); XCTAssertEqual(allDay["allDay"] as? Bool, true)

        let timed = NativeTaskEditor.dueFields(task: nil, day: chosen, allDay: false, time: chosen.addingTimeInterval(23 * 3600 + 59 * 60 + 40))
        XCTAssertEqual(timed["allDay"] as? Bool, false)
        XCTAssertEqual(ISO8601DateFormatter().date(from: try XCTUnwrap(timed["dueAt"] as? String)), chosen.addingTimeInterval(23 * 3600 + 59 * 60), "Seconds are dropped")

        // Moving, clearing and re-timing an existing task's date all go into the request.
        let existing = try task(due: "2026-11-11")
        XCTAssertEqual(NativeTaskEditor.dueFields(task: existing, day: chosen, allDay: true, time: Date())["dueAt"] as? String, "2026-11-14")
        XCTAssertTrue(NativeTaskEditor.dueFields(task: existing, day: nil, allDay: true, time: Date())["dueAt"] is NSNull)
        XCTAssertEqual(NativeTaskEditor.dueFields(task: existing, day: try day("2026-11-11"), allDay: false, time: chosen)["allDay"] as? Bool, false)
        XCTAssertNil(NativeTaskEditor.dueFields(task: nil, day: nil, allDay: true, time: Date())["dueAt"] as? String, "A new task without a due date")
    }
}

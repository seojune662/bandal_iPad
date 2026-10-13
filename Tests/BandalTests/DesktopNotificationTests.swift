import XCTest
import UserNotifications
@testable import Bandal

@MainActor
final class DesktopNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var preferences: [String: Any] { ["enabled": true, "deadlines": true, "deadlineLeadDays": [1, 3, 7], "agentComplete": true, "downloads": true, "pluginNotices": true, "sound": false, "suppressWhileFocused": true, "sent": [String: String]()] }
    private func task(_ id: String = "task", days: Double = 2) -> [String: Any] { ["id": id, "courseId": "course", "courseName": "과학", "title": "시험", "dueAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(days * 86400)), "allDay": false] }
    func testNearestEligibleDeadlineAvoidsStaleReminderBurstAndRetainsFuture() {
        let plan = DesktopNotificationService.deadlines(tasks: [task()], preferences: preferences, activeCourse: nil, focused: false, now: now, locale: "ko-KR")
        XCTAssertEqual(Set(plan.requests.map { $0.content.userInfo["deadlineKey"] as? String }), Set(["task:3", "task:1"]))
        XCTAssertTrue(plan.requests.allSatisfy { $0.content.sound == nil })
        var ledger = preferences; ledger["sent"] = ["task:3": ISO8601DateFormatter().string(from: now)]
        let next = DesktopNotificationService.deadlines(tasks: [task()], preferences: ledger, activeCourse: nil, focused: false, now: now, locale: "ko-KR")
        XCTAssertEqual(next.requests.count, 1); XCTAssertEqual(next.requests[0].content.userInfo["deadlineKey"] as? String, "task:1")
    }
    func testFocusedCourseSuppressionAndPendingLimit() {
        let current = DesktopNotificationService.deadlines(tasks: [task()], preferences: preferences, activeCourse: "course", focused: true, now: now, locale: "ko-KR")
        XCTAssertEqual(current.suppressed, ["task:3"]); XCTAssertEqual(current.requests.count, 1)
        let many = DesktopNotificationService.deadlines(tasks: (0..<80).map { task("task\($0)", days: Double($0 + 10)) }, preferences: preferences, activeCourse: nil, focused: false, now: now, locale: "en-US")
        XCTAssertEqual(many.requests.count, 60)
        XCTAssertEqual(Set(many.requests.map(\.identifier)).count, 60)
    }
    func testActualReconcileRemovesCompletedAndDisabledTaskRequests() async throws {
        var environment = DesktopNotificationEnvironment(), pending: [UNNotificationRequest] = [], tasks = [task()]
        var settings: [String: Any] = ["notifications": preferences, "locale": "ko-KR"]
        environment.now = { self.now }; environment.focused = { false }; environment.authorization = { .authorized }
        environment.pending = { pending }; environment.delivered = { [] }
        environment.add = { request in pending.removeAll { $0.identifier == request.identifier }; pending.append(request) }
        environment.remove = { ids in pending.removeAll { ids.contains($0.identifier) } }
        let service = DesktopNotificationService(invokePrivate: { channel, _ in
            XCTAssertEqual(channel, "nativeNotification:snapshot"); return ["settings": settings, "tasks": tasks]
        }, environment: environment)
        try await service.reconcile(); XCTAssertEqual(pending.count, 2)
        tasks = []; try await service.reconcile(); XCTAssertTrue(pending.isEmpty)
        tasks = [self.task()]; try await service.reconcile(); XCTAssertEqual(pending.count, 2)
        var disabled = self.preferences; disabled["enabled"] = false; settings["notifications"] = disabled
        try await service.reconcile(); XCTAssertTrue(pending.isEmpty)
    }
    func testCompletionEventsHonorActualSettingsFocusAndDedupe() async throws {
        var environment = DesktopNotificationEnvironment(), posted: [UNNotificationRequest] = []
        environment.now = { self.now }; environment.focused = { true }; environment.authorization = { .authorized }
        environment.pending = { [] }; environment.delivered = { [] }; environment.remove = { _ in }; environment.add = { posted.append($0) }
        let service = DesktopNotificationService(invokePrivate: { _, _ in ["settings": ["notifications": self.preferences, "lastActiveCourseId": "course"], "tasks": []] }, environment: environment)
        try await service.reconcile()
        await service.notice(kind: "agentComplete", title: "완료", body: "", courseId: "course", id: "suppressed")
        XCTAssertTrue(posted.isEmpty)
        await service.notice(kind: "agentComplete", title: "완료", body: "", courseId: "other", id: "real")
        await service.notice(kind: "agentComplete", title: "완료", body: "", courseId: "other", id: "real")
        XCTAssertEqual(posted.count, 1); XCTAssertNil(posted[0].content.sound)
    }
}

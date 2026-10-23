import EventKit
import UIKit
import UserNotifications

/// Native boundary of the original desktop calendar service. Configuration,
/// task intervals, reconnect rules and export receipts stay in its TS service.
@MainActor
final class DesktopSystemServices {
    var emit: ((String, Any) -> Void)?
    private let store: EKEventStore
    private let iso = ISO8601DateFormatter()
    private let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
    private var observer: NSObjectProtocol?
    private let permissions: DesktopPermissionAccess
    private let scheduleTestNotification: () async throws -> Void
    private static let permissionIDs = ["screen", "accessibility", "notifications", "microphone", "calendar", "documents"]

    init(permissionAccess: DesktopPermissionAccess? = nil, scheduleTestNotification: (() async throws -> Void)? = nil) {
        let store = EKEventStore()
        self.store = store
        permissions = permissionAccess ?? .live(calendar: store)
        self.scheduleTestNotification = scheduleTestNotification ?? Self.scheduleNotification
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.emit?("appleCalendar:changed", [:]) }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func canHandle(_ channel: String) -> Bool {
        ["native:calendarState", "native:calendarEvents", "native:calendarExport", "appleCalendar:permissions", "permissions:status", "permissions:request", "permissions:openSettings", "notifications:test"].contains(channel)
    }

    func handle(channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "native:calendarState":
            if request["connect"] as? Bool == true { _ = try await store.requestFullAccessToEvents() }
            return calendarState(includeCalendars: request["includeCalendars"] as? Bool ?? false)
        case "native:calendarEvents": return try calendarEvents(request)
        case "native:calendarExport": return try exportCalendarEvent(request)
        case "appleCalendar:permissions", "permissions:openSettings":
            if channel == "permissions:openSettings" {
                guard let id = request["id"] as? String, Self.permissionIDs.contains(id) else { throw DesktopRuntimeError("권한 항목을 확인해 주세요.") }
            }
            guard await permissions.openSettings() else { throw DesktopRuntimeError("시스템 설정을 열지 못했습니다.") }
            return ["ok": true]
        case "permissions:status":
            var rows: [[String: Any]] = []
            for id in Self.permissionIDs { rows.append(await permission(id)) }
            return ["platform": "ios", "permissions": rows, "checkedAt": iso.string(from: Date())]
        case "permissions:request":
            guard let id = request["id"] as? String, Self.permissionIDs.contains(id) else { throw DesktopRuntimeError("권한 항목을 확인해 주세요.") }
            let current = await permission(id)
            if current["canRequest"] as? Bool == true { try await permissions.request(id) }
            return await permission(id)
        case "notifications:test":
            if await permissions.state("notifications") == "not-determined" { try await permissions.request("notifications") }
            guard await permissions.state("notifications") == "granted" else {
                throw DesktopRuntimeError("설정 앱의 반달 → 알림에서 알림을 허용해 주세요.")
            }
            try await scheduleTestNotification()
            return ["ok": true, "reason": NSNull()]
        default: throw DesktopRuntimeError("Unknown system service: \(channel)", code: "ENOSYS")
        }
    }

    private static func scheduleNotification() async throws {
        let content = UNMutableNotificationContent()
        content.title = "반달"
        content.body = "알림이 정상적으로 연결되었습니다."
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bandal-settings-test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    private func permission(_ id: String) async -> [String: Any] {
        if ["notifications", "calendar"].contains(id) {
            let state = await permissions.state(id)
            return ["id": id, "state": state, "canRequest": state == "not-determined", "canOpenSettings": true]
        }
        // iPad grants external documents individually through its file picker.
        // It offers no global desktop screen/accessibility automation grant.
        return ["id": id, "state": "not-applicable", "canRequest": false, "canOpenSettings": false]
    }

    private func authorization() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return "authorized"
        case .writeOnly: return "write-only"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not-determined"
        }
    }

    private func color(_ calendar: EKCalendar) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard let cgColor = calendar.cgColor, UIColor(cgColor: cgColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#7f8c8d" }
        return String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    private func calendarState(includeCalendars: Bool) -> [String: Any] {
        let permitted = includeCalendars && authorization() == "authorized"
        let calendars: [[String: Any]] = permitted ? store.calendars(for: .event).map {
            ["id": $0.calendarIdentifier, "title": $0.title, "source": $0.source.title, "color": color($0), "writable": $0.allowsContentModifications]
        } : []
        return ["authorization": authorization(), "calendars": calendars,
                "defaultCalendarId": (permitted ? store.defaultCalendarForNewEvents?.calendarIdentifier : nil) as Any? ?? NSNull()]
    }

    private func instant(_ value: String) -> Date? {
        if let date = iso.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private func calendarEvents(_ request: [String: Any]) throws -> [[String: Any]] {
        guard authorization() == "authorized" else { throw DesktopRuntimeError("설정에서 Apple 캘린더의 접근 권한을 허용해 주세요.") }
        guard let from = request["from"] as? String, let to = request["to"] as? String,
              let start = instant(from), let end = instant(to), end > start, end.timeIntervalSince(start) <= 366 * 86400,
              let ids = request["calendarIds"] as? [String] else { throw DesktopRuntimeError("조회할 날짜와 캘린더를 확인해 주세요.") }
        let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { $0.startDate < end && ($0.endDate > start || ($0.startDate == $0.endDate && $0.startDate >= start)) }
            .map { event in
                let address = event.url?.absoluteString ?? "", prefix = "bandal://calendar/task/"
                return ["id": "\(event.eventIdentifier ?? event.calendarItemIdentifier):\(iso.string(from: event.startDate))",
                        "calendarId": event.calendar.calendarIdentifier, "calendarTitle": event.calendar.title,
                        "title": event.title ?? "제목 없음", "start": event.isAllDay ? day.string(from: event.startDate) : iso.string(from: event.startDate),
                        "end": event.isAllDay ? day.string(from: event.endDate) : iso.string(from: event.endDate),
                        "allDay": event.isAllDay, "location": event.location ?? "", "color": color(event.calendar),
                        "bandalTaskId": address.hasPrefix(prefix) ? String(address.dropFirst(prefix.count)) as Any : NSNull()]
            }
    }

    private func exportCalendarEvent(_ request: [String: Any]) throws -> [String: Any] {
        guard authorization() == "authorized" else { throw DesktopRuntimeError("설정에서 Apple 캘린더의 접근 권한을 허용해 주세요.") }
        guard let calendarID = request["calendarId"] as? String, let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications,
              let taskID = request["taskId"] as? String, !taskID.isEmpty, let title = request["title"] as? String, !title.isEmpty,
              let startValue = request["start"] as? String, let endValue = request["end"] as? String else { throw DesktopRuntimeError("저장할 캘린더와 일정의 제목·날짜를 확인해 주세요.") }
        let allDay = request["allDay"] as? Bool ?? true
        guard let start = allDay ? day.date(from: startValue) : instant(startValue), let end = allDay ? day.date(from: endValue) : instant(endValue), allDay ? end > start : end >= start else { throw DesktopRuntimeError("날짜 형식이 올바르지 않습니다.") }
        let marker = "bandal://calendar/task/\(taskID)"
        var existing: EKEvent?
        if let id = request["eventId"] as? String, let found = store.event(withIdentifier: id), found.url?.absoluteString == marker { existing = found }
        if existing == nil {
            let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(2 * 86400), calendars: [calendar])
            existing = store.events(matching: predicate).first { $0.url?.absoluteString == marker }
        }
        if existing?.hasRecurrenceRules == true { throw DesktopRuntimeError("Apple 캘린더에서 반복 일정으로 바뀐 항목은 해당 앱에서 수정해 주세요.") }
        let event = existing ?? EKEvent(eventStore: store)
        if existing != nil && !event.calendar.allowsContentModifications { throw DesktopRuntimeError("기존 일정의 캘린더가 읽기 전용입니다.") }
        event.calendar = calendar; event.title = title; event.notes = request["notes"] as? String ?? ""
        event.url = URL(string: marker); event.isAllDay = allDay; event.startDate = start; event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
        return ["eventId": event.eventIdentifier ?? event.calendarItemIdentifier, "updated": existing != nil]
    }
}

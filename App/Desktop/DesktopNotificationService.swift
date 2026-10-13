import Foundation
import UIKit
import UserNotifications

@MainActor
struct DesktopNotificationEnvironment {
    var authorization: () async -> UNAuthorizationStatus = { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    var pending: () async -> [UNNotificationRequest] = { await UNUserNotificationCenter.current().pendingNotificationRequests() }
    var delivered: () async -> [String] = { await UNUserNotificationCenter.current().deliveredNotifications().compactMap { $0.request.content.userInfo["deadlineKey"] as? String } }
    var add: (UNNotificationRequest) async throws -> Void = { try await UNUserNotificationCenter.current().add($0) }
    var remove: ([String]) -> Void = { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) }
    var now: () -> Date = Date.init
    var focused: () -> Bool = { UIApplication.shared.applicationState == .active }
}

/// Real iPad notification delivery for the unchanged desktop settings. The
/// original SQL task set and sent ledger remain owned by the desktop backend.
@MainActor
final class DesktopNotificationService: NSObject, UNUserNotificationCenterDelegate {
    typealias Invoke = (String, [String: Any]) async throws -> Any
    private static let prefix = "bandal.desktop."
    private let invoke: Invoke
    private var environment: DesktopNotificationEnvironment
    private var settings: [String: Any] = [:]
    private var refreshing: Task<Void, Never>?
    private var dirty = false
    private var seenEvents = Set<String>()
    private var observers: [NSObjectProtocol] = []
    var onError: ((String) -> Void)?
    init(invokePrivate: @escaping Invoke, environment: DesktopNotificationEnvironment? = nil) {
        invoke = invokePrivate; self.environment = environment ?? DesktopNotificationEnvironment(); super.init()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); refreshing?.cancel() }
    func start() {
        UNUserNotificationCenter.current().delegate = self
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.significantTimeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
        refresh()
    }
    func receive(_ channel: String, _ payload: Any) {
        if ["settings:changed", "board:changed", "courses:changed"].contains(channel) { refresh(); return }
        guard let value = payload as? [String: Any] else { return }
        if channel == "runtime:notification" {
            Task { await self.notice(kind: value["kind"] as? String ?? "", title: value["title"] as? String ?? "반달", body: value["body"] as? String ?? "", courseId: value["courseId"] as? String, id: value["id"] as? String ?? UUID().uuidString) }
        } else if channel == "browser:download", value["state"] as? String == "completed", let id = value["id"] as? String {
            Task { await self.notice(kind: "download", title: "다운로드 완료", body: value["fileName"] as? String ?? "", courseId: nil, id: "download-" + id) }
        } else if channel == "plugins:notice" {
            Task { await self.notice(kind: "plugin", title: value["pluginName"] as? String ?? "반달", body: value["message"] as? String ?? "", courseId: nil, id: UUID().uuidString) }
        }
    }
    func refresh() {
        dirty = true
        guard refreshing == nil else { return }
        refreshing = Task { [weak self] in
            guard let self else { return }
            while dirty && !Task.isCancelled {
                dirty = false
                do { try await reconcile() } catch { onError?(error.localizedDescription) }
            }
            refreshing = nil
        }
    }
    /// Exposed internally for deterministic fixture validation; production uses
    /// the single-flight refresh loop for all concurrent mutation pushes.
    func reconcile() async throws {
        guard let snapshot = try await invoke("nativeNotification:snapshot", [:]) as? [String: Any] else { throw DesktopRuntimeError("알림 설정을 읽지 못했습니다.") }
        settings = snapshot["settings"] as? [String: Any] ?? [:]
        var preferences = settings["notifications"] as? [String: Any] ?? [:]
        let old = await environment.pending().filter { $0.identifier.hasPrefix(Self.prefix + "deadline.") }
        let status = await environment.authorization()
        guard [.authorized, .provisional, .ephemeral].contains(status), preferences["enabled"] as? Bool == true, preferences["deadlines"] as? Bool == true else {
            environment.remove(old.map(\.identifier)); return
        }
        var sent = preferences["sent"] as? [String: String] ?? [:]
        let delivered = await environment.delivered().filter { sent[$0] == nil }
        if !delivered.isEmpty { try await markSent(delivered); for key in delivered { sent[key] = ISO8601DateFormatter().string(from: environment.now()) } }
        preferences["sent"] = sent
        let plan = Self.deadlines(tasks: snapshot["tasks"] as? [[String: Any]] ?? [], preferences: preferences,
                                  activeCourse: settings["lastActiveCourseId"] as? String, focused: environment.focused(), now: environment.now(), locale: settings["locale"] as? String ?? "ko-KR")
        if !plan.suppressed.isEmpty { try await markSent(plan.suppressed) }
        let wanted = Dictionary(uniqueKeysWithValues: plan.requests.map { ($0.identifier, $0) })
        environment.remove(old.filter { wanted[$0.identifier] == nil }.map(\.identifier))
        for request in plan.requests {
            if let existing = old.first(where: { $0.identifier == request.identifier }), existing.content.userInfo["signature"] as? String == request.content.userInfo["signature"] as? String { continue }
            try Task.checkCancellation()
            try await environment.add(request)
        }
    }
    private func markSent(_ keys: [String]) async throws {
        _ = try await invoke("nativeNotification:markSent", ["keys": Array(Set(keys)), "at": ISO8601DateFormatter().string(from: environment.now())])
    }
    private func allowed(kind: String, courseId: String?) -> Bool {
        let preferences = settings["notifications"] as? [String: Any] ?? [:]
        let field = ["deadline": "deadlines", "agentComplete": "agentComplete", "download": "downloads", "plugin": "pluginNotices"][kind]
        guard let field, preferences["enabled"] as? Bool == true, preferences[field] as? Bool == true else { return false }
        let sameCourse = courseId == nil || courseId == settings["lastActiveCourseId"] as? String
        return !(preferences["suppressWhileFocused"] as? Bool == true && environment.focused() && sameCourse)
    }
    func notice(kind: String, title: String, body: String, courseId: String?, id: String) async {
        guard seenEvents.insert(id).inserted else { return }
        if seenEvents.count > 1000 { seenEvents = [id] }
        guard allowed(kind: kind, courseId: courseId) else { return }
        let status = await environment.authorization()
        guard [.authorized, .provisional, .ephemeral].contains(status) else { return }
        let content = UNMutableNotificationContent(); content.title = String(title.prefix(500)); content.body = String(body.prefix(4000))
        content.userInfo = ["kind": kind, "courseId": courseId ?? ""]
        if (settings["notifications"] as? [String: Any])?["sound"] as? Bool == true { content.sound = .default }
        do { try await environment.add(UNNotificationRequest(identifier: Self.prefix + "event." + id, content: content, trigger: nil)) }
        catch { onError?(error.localizedDescription) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let info = notification.request.content.userInfo
            if let key = info["deadlineKey"] as? String { do { try await markSent([key]) } catch { onError?(error.localizedDescription) } }
            let kind = info["kind"] as? String ?? "test", course = (info["courseId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard kind == "test" || allowed(kind: kind, courseId: course) else { completionHandler([]); return }
            var options: UNNotificationPresentationOptions = [.banner, .list]
            if notification.request.content.sound != nil { options.insert(.sound) }
            completionHandler(options)
        }
    }

    struct DeadlinePlan { var requests: [UNNotificationRequest]; var suppressed: [String] }
    static func deadlines(tasks: [[String: Any]], preferences: [String: Any], activeCourse: String?, focused: Bool, now: Date, locale: String) -> DeadlinePlan {
        let leadDays = Set((preferences["deadlineLeadDays"] as? [Int] ?? []).filter { [1, 3, 7].contains($0) }).sorted()
        let sent = preferences["sent"] as? [String: String] ?? [:], calendar = Calendar.current
        let iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        let dateOnly = DateFormatter(); dateOnly.locale = Locale(identifier: "en_US_POSIX"); dateOnly.calendar = Calendar(identifier: .gregorian); dateOnly.dateFormat = "yyyy-MM-dd"; dateOnly.isLenient = false
        var candidates: [(Date, UNNotificationRequest)] = [], suppressed: [String] = []
        for task in tasks {
            guard let id = task["id"] as? String, let dueText = task["dueAt"] as? String else { continue }
            let allDay = (task["allDay"] as? Bool) ?? ((task["allDay"] as? Int) == 1)
            guard let due = allDay && dueText.count == 10 ? dateOnly.date(from: dueText) : fractional.date(from: dueText) ?? iso.date(from: dueText), due > now else { continue }
            let course = task["courseId"] as? String
            let eligible = leadDays.filter { now >= due.addingTimeInterval(-Double($0) * 86400) }
            let nearest = eligible.min()
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: locale); formatter.dateStyle = .medium; formatter.timeStyle = allDay ? .none : .short
            for lead in leadDays {
                let key = "\(id):\(lead)"
                if sent[key] != nil { continue }
                let when = due.addingTimeInterval(-Double(lead) * 86400)
                if when <= now && lead != nearest { continue }
                let immediate = when <= now
                if immediate && preferences["suppressWhileFocused"] as? Bool == true && focused && (course == nil || course == activeCourse) { suppressed.append(key); continue }
                let content = UNMutableNotificationContent()
                content.title = "마감 D-\(lead): \(task["title"] as? String ?? "")"
                content.body = "\(task["courseName"] as? String ?? "반달") · \(formatter.string(from: due))"
                if preferences["sound"] as? Bool == true { content.sound = .default }
                let signature = [content.title, content.body, String(when.timeIntervalSince1970), String(preferences["sound"] as? Bool == true)].joined(separator: "\0")
                content.userInfo = ["kind": "deadline", "deadlineKey": key, "courseId": course ?? "", "signature": signature]
                let trigger: UNNotificationTrigger = immediate ? UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false) : UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when), repeats: false)
                candidates.append((max(now, when), UNNotificationRequest(identifier: prefix + "deadline." + key, content: content, trigger: trigger)))
            }
        }
        // iOS allows a bounded pending queue. Reserve slots for immediate events;
        // foreground/setting/task/time changes replenish the nearest deadlines.
        return DeadlinePlan(requests: candidates.sorted { $0.0 < $1.0 }.prefix(60).map(\.1), suppressed: suppressed)
    }
}

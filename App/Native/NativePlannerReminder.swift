import Foundation
import UserNotifications

/// 알림: one local notification per task, on this iPad only. The choice is kept here and not on the task
/// because the synced task record has no field for it.
enum NativePlannerReminder: String, CaseIterable {
    case off, morning, dayBefore, threeDaysBefore
    var title: String {
        switch self { case .off: "없음"; case .morning: "당일 오전 9시"; case .dayBefore: "하루 전 오후 6시"; case .threeDaysBefore: "3일 전 오후 6시" }
    }
    /// When the reminder for a task due at `due` goes off.
    func fireDate(due: Date, calendar: Calendar = .current) -> Date? {
        let lead: (days: Int, hour: Int)
        switch self { case .off: return nil; case .morning: lead = (0, 9); case .dayBefore: lead = (1, 18); case .threeDaysBefore: lead = (3, 18) }
        return calendar.date(byAdding: .day, value: -lead.days, to: due).flatMap { calendar.date(bySettingHour: lead.hour, minute: 0, second: 0, of: $0) }
    }

    private static let key = "native.planner.reminders", prefix = "bandal.reminder."
    private static var stored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func choice(for taskID: String) -> Self { stored[taskID].flatMap { Self(rawValue: $0) } ?? .off }
    /// Asks for permission the first time; false when notifications are refused.
    static func authorized() async -> Bool {
        // The system's prompt would sit on top of the app for the rest of a UI test run.
        if ProcessInfo.processInfo.arguments.contains("--native-ui-testing") { return true }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    /// Keeps the choice for a task and replaces its pending notification.
    static func set(_ choice: Self, for task: NativePlannerTask) {
        stored[task.id] = choice == .off ? nil : choice.rawValue
        schedule(task)
    }
    /// Called with every task whenever the board loads: forgets tasks that are gone and brings each pending
    /// notification in line with the task's due date and status (a task can change on another device).
    static func reconcile(_ tasks: [NativePlannerTask]) {
        let gone = Set(stored.keys).subtracting(tasks.map(\.id))
        if !gone.isEmpty {
            stored = stored.filter { !gone.contains($0.key) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: gone.map { prefix + $0 })
        }
        for task in tasks where stored[task.id] != nil { schedule(task) }
    }
    private static func schedule(_ task: NativePlannerTask, now: Date = Date()) {
        let center = UNUserNotificationCenter.current(), identifier = prefix + task.id
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard !task.completed, let due = task.dueDate, let date = choice(for: task.id).fireDate(due: due), date > now else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title; content.body = "마감 " + (task.dueText(now: date) ?? ""); content.sound = .default; content.userInfo = ["taskID": task.id]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // Without permission the request is refused, and there is nobody to tell from here: the editor asks first.
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
}

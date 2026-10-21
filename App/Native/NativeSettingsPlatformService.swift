import AVFoundation
import EventKit
import Foundation
import UIKit
import UserNotifications

/// Device-backed settings. Merely opening settings never requests permission.
@MainActor
final class NativeSettingsPlatformService: NSObject, UNUserNotificationCenterDelegate {
    private weak var store: NativeWorkspaceStore?
    private let files: DesktopFileServices
    private let notifications = UNUserNotificationCenter.current()
    private lazy var calendarStore = EKEventStore()
    private var preferences: [String:Any] = [:]
    private var refreshTask: Task<Void,Never>?
    private var scheduleGeneration = UUID()
    init(store: NativeWorkspaceStore, files: DesktopFileServices) {
        self.store = store; self.files = files
        super.init()
        notifications.delegate = self
    }
    deinit { refreshTask?.cancel() }
    func apply(_ settings: [String:Any]) {
        preferences = settings
        scheduleRefresh()
    }
    func receive(_ event: NativeWorkspaceEvent) {
        if ["board:changed","courses:changed","sync:changed","nativeWorkspace:externalMutationFinished"].contains(event.channel) { scheduleRefresh() }
        if event.channel == "chat:event-batch", let payload = event.payload as? [String:Any], let events = payload["events"] as? [[String:Any]],
           events.contains(where: { $0["type"] as? String == "turn-complete" && $0["stopReason"] as? String == "success" }) {
            Task { try? await post(kind:"agentComplete",title:"AI 응답이 완료됐어요",body:"반달에서 응답을 확인하세요.") }
        }
    }
    func downloaded(_ title: String) { Task { try? await post(kind:"downloads",title:"다운로드 완료",body:title) } }
    private var notificationPreferences: [String:Any] { preferences["notifications"] as? [String:Any] ?? [:] }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        let previous = refreshTask
        let generation = UUID(); scheduleGeneration = generation
        refreshTask = Task { [weak self] in
            do { await previous?.value; try Task.checkCancellation(); try await Task.sleep(for:.milliseconds(250)); try Task.checkCancellation(); guard self?.scheduleGeneration == generation else { return }; try await self?.refreshDeadlines() }
            catch is CancellationError {}
            catch { self?.store?.runtime.log.record("notifications.schedule.failed") }
        }
    }
    private func refreshDeadlines() async throws {
        guard let store, store.isReady else { return }
        let pending = await notifications.pendingNotificationRequests()
        try Task.checkCancellation()
        let authorization = await notifications.notificationSettings().authorizationStatus
        let enabled = [.authorized,.provisional,.ephemeral].contains(authorization) && notificationPreferences["enabled"] as? Bool != false
        let tasks = enabled ? (try await store.invoke("board:listTasks",["includeDone":false]) as? [[String:Any]] ?? []) : []
        let plans = NativeNotificationPlan.deadlines(tasks:tasks,settings:notificationPreferences)
        try Task.checkCancellation()
        let keep = Set(plans.map(\.id))
        notifications.removePendingNotificationRequests(withIdentifiers:pending.filter { (!enabled && $0.identifier.hasPrefix("bandal.")) || ($0.identifier.hasPrefix("bandal.deadline.") && !keep.contains($0.identifier)) }.map(\.identifier))
        for plan in plans {
            try Task.checkCancellation()
            let content = UNMutableNotificationContent(); content.title = plan.title; content.body = plan.body
            content.userInfo = ["taskID":plan.taskID]
            if notificationPreferences["sound"] as? Bool != false { content.sound = .default }
            var components = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second],from:plan.date)
            components.calendar = Calendar.current; components.timeZone = Calendar.current.timeZone
            try await notifications.add(UNNotificationRequest(identifier:plan.id,content:content,trigger:UNCalendarNotificationTrigger(dateMatching:components,repeats:false)))
        }
    }
    private func post(kind: String, title: String, body: String, test: Bool = false) async throws {
        guard test || (notificationPreferences["enabled"] as? Bool != false && notificationPreferences[kind] as? Bool != false) else { return }
        let authorization = await notifications.notificationSettings().authorizationStatus
        guard [.authorized,.provisional,.ephemeral].contains(authorization) else { if test { throw DesktopRuntimeError("먼저 알림 권한을 허용해 주세요.") }; return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.userInfo = ["test":test]
        if notificationPreferences["sound"] as? Bool != false { content.sound = .default }
        try await notifications.add(UNNotificationRequest(identifier:"bandal.\(kind).\(UUID().uuidString)",content:content,trigger:UNTimeIntervalNotificationTrigger(timeInterval:1,repeats:false)))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["test"] as? Bool != true,
           notificationPreferences["enabled"] as? Bool == false || notificationPreferences["suppressWhileFocused"] as? Bool != false { return [] }
        return notificationPreferences["sound"] as? Bool == false ? [.banner,.list] : [.banner,.list,.sound]
    }
    func handle(_ channel: String, _ request: [String:Any]) async throws -> Any {
        guard let store else { throw CancellationError() }
        switch channel {
        case "nativeSettings:status": return await status()
        case "nativeSettings:requestPermission":
            switch request["id"] as? String {
            case "notifications": _ = try await notifications.requestAuthorization(options:[.alert,.badge,.sound]); scheduleRefresh()
            case "camera": _ = await AVCaptureDevice.requestAccess(for:.video)
            case "calendar": _ = try await calendarStore.requestFullAccessToEvents()
            default: throw DesktopRuntimeError("권한 종류를 확인해 주세요.")
            }
            return await status()
        case "nativeSettings:openSystemSettings":
            let success = await UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!)
            return ["ok":success]
        case "nativeSettings:testNotification":
            try await post(kind:"test",title:"반달 알림",body:"알림이 정상적으로 연결됐습니다.",test:true); return NativeValue.ok
        case "nativeSettings:clearCache":
            let cache = store.root.appendingPathComponent("NativePDFCache",isDirectory:true)
            let size = await Self.bytes(cache)
            _ = try await store.withExternalMutation {
                _ = try DesktopRenderCacheReset.removePDFCopies(root:store.root)
                URLCache.shared.removeAllCachedResponses()
                return [:]
            }
            return ["ok":true,"removedBytes":size]
        case "nativeSettings:exportDiagnostics":
            let snapshot = await status()
            // No document names, account details, API keys or full file paths.
            let data = try JSONSerialization.data(withJSONObject:["platform":"iPadOS","osVersion":UIDevice.current.systemVersion,"version":snapshot["version"] ?? "","build":snapshot["build"] ?? "","permissions":snapshot["permissions"] ?? [],"documentsBytes":(snapshot["storage"] as? [String:Any])?["documentsBytes"] ?? 0,"generatedAt":ISO8601DateFormatter().string(from:Date())],options:[.prettyPrinted,.sortedKeys])
            return try await files.handle(channel:"native:saveFile",request:["suggestedName":"Bandal-diagnostics.json","data":data.base64EncodedString()])
        case "nativeSettings:configureCalendar":
            guard Self.calendarAuthorized else { throw DesktopRuntimeError("먼저 캘린더 접근을 허용해 주세요.") }
            let available = Set(calendarStore.calendars(for:.event).map(\.calendarIdentifier))
            let selected = request["selectedCalendarIds"] as? [String] ?? []
            guard selected.allSatisfy(available.contains) else { throw DesktopRuntimeError("캘린더 목록이 변경되었습니다. 다시 선택해 주세요.") }
            if let destination = request["destinationCalendarId"] as? String {
                guard let calendar = calendarStore.calendar(withIdentifier:destination), calendar.allowsContentModifications else { throw DesktopRuntimeError("일정을 추가할 수 있는 캘린더를 선택하세요.") }
            }
            var update: [String:Any] = ["selectedCalendarIds":selected]
            if let destination = request["destinationCalendarId"] { update["destinationCalendarId"] = destination }
            _ = try await store.invoke("settings:set",["calendar":update])
            return await status()
        case "nativeSettings:disconnectCalendar":
            _ = try await store.invoke("settings:set",["calendar":["selectedCalendarIds":[String](),"destinationCalendarId":NSNull()]])
            return await status()
        case "nativeSettings:calendarEvents": return try calendarEvents(request)
        case "nativeSettings:exportCalendar":
            var query: [String:Any] = ["includeDone":true]
            if let course = request["courseId"] { query["courseId"] = course }
            let tasks = try await store.invoke("board:listTasks",query) as? [[String:Any]] ?? []
            return try await files.handle(channel:"native:saveFile",request:["suggestedName":"Bandal-calendar.ics","data":NativeCalendarExport.data(tasks:tasks).base64EncodedString()])
        case "nativeSettings:openCalendar":
            let date = (request["date"] as? String).flatMap { NativeNotificationPlan.date($0) } ?? Date()
            return ["ok":await UIApplication.shared.open(URL(string:"calshow:\(date.timeIntervalSinceReferenceDate)")!)]
        default: throw DesktopRuntimeError("지원하지 않는 기기 설정 작업입니다.")
        }
    }
    private static var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for:.event) == .fullAccess }
    private func calendarEvents(_ request: [String:Any]) throws -> [[String:Any]] {
        guard Self.calendarAuthorized else { return [] }
        guard let rawFrom = request["from"] as? String, let from = NativeNotificationPlan.date(rawFrom),
              let rawTo = request["to"] as? String, let to = NativeNotificationPlan.date(rawTo), from < to, to.timeIntervalSince(from) <= 366*86400 else { throw DesktopRuntimeError("캘린더 조회 범위를 확인해 주세요.") }
        let selected = (preferences["calendar"] as? [String:Any])?["selectedCalendarIds"] as? [String] ?? []
        let calendars = selected.compactMap { calendarStore.calendar(withIdentifier:$0) }
        guard !calendars.isEmpty else { return [] }
        return calendarStore.events(matching:calendarStore.predicateForEvents(withStart:from,end:to,calendars:calendars)).prefix(2000).map {
            ["id":($0.eventIdentifier ?? "calendar") + ":" + String($0.startDate.timeIntervalSince1970),"title":$0.title ?? "일정","startAt":ISO8601DateFormatter().string(from:$0.startDate),"dueAt":ISO8601DateFormatter().string(from:$0.endDate),"allDay":$0.isAllDay,"calendarTitle":$0.calendar.title]
        }
    }
    private func status() async -> [String:Any] {
        guard let store else { return [:] }
        let notice = await notifications.notificationSettings()
        let pending = await notifications.pendingNotificationRequests()
        let notificationStatus: String
        switch notice.authorizationStatus { case .notDetermined:notificationStatus = "notDetermined"; case .denied:notificationStatus = "denied"; case .authorized:notificationStatus = "authorized"; default:notificationStatus = "provisional" }
        let camera: String
        switch AVCaptureDevice.authorizationStatus(for:.video) { case .notDetermined:camera = "notDetermined"; case .authorized:camera = "authorized"; default:camera = "denied" }
        let calendar = Self.calendarAuthorized ? "authorized" : EKEventStore.authorizationStatus(for:.event) == .notDetermined ? "notDetermined" : "denied"
        let calendarSettings = preferences["calendar"] as? [String:Any] ?? [:]
        let calendars: [[String:Any]] = Self.calendarAuthorized ? calendarStore.calendars(for:.event).map { ["id":$0.calendarIdentifier,"title":$0.title,"writable":$0.allowsContentModifications] } : []
        async let documentsSize = Self.bytes(store.root)
        async let cacheSize = Self.bytes(store.root.appendingPathComponent("NativePDFCache",isDirectory:true))
        return ["platform":"iPadOS","version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "","build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "",
                "permissions":[["id":"notifications","title":"알림","status":notificationStatus,"detail":"마감·다운로드·AI 응답 알림"],["id":"camera","title":"카메라","status":camera,"detail":"웹사이트의 사진·화상 기능"],["id":"calendar","title":"캘린더","status":calendar,"detail":"선택한 기기 캘린더의 일정 표시"]],
                "storage":["documentsBytes":await documentsSize,"cacheBytes":await cacheSize,"rootPath":store.root.path],
                "notifications":["authorization":notificationStatus,"pendingCount":pending.count],
                "calendar":["authorization":calendar,"calendars":calendars,"enabled":!(calendarSettings["selectedCalendarIds"] as? [String] ?? []).isEmpty,"selectedCalendarIds":calendarSettings["selectedCalendarIds"] ?? [],"destinationCalendarId":calendarSettings["destinationCalendarId"] ?? NSNull()]]
    }
    private static func bytes(_ url: URL) async -> Int64 {
        await Task.detached(priority:.utility) {
            guard let enumerator = FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey],options:[.skipsHiddenFiles]) else { return Int64(0) }
            var total: Int64 = 0
            for case let item as URL in enumerator {
                guard let value = try? item.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]), value.isSymbolicLink != true, value.isRegularFile == true else { continue }
                total += Int64(value.fileSize ?? 0)
            }
            return total
        }.value
    }
}

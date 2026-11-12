import SwiftUI

struct NativeSettingsSystemPanels: View {
    let section: String
    var store: NativeWorkspaceStore
    let settings: [String: Any]
    let save: @MainActor ([String: Any]) async throws -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: [String: Any] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmation: String?
    private var notifications: [String: Any] { settings["notifications"] as? [String: Any] ?? [:] }
    private var calendar: [String: Any] { status["calendar"] as? [String: Any] ?? [:] }
    private var calendarSettings: [String: Any] { settings["calendar"] as? [String: Any] ?? [:] }
    private var selectedCalendars: [String] { calendarSettings["selectedCalendarIds"] as? [String] ?? [] }
    private var calendars: [[String: Any]] { calendar["calendars"] as? [[String: Any]] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let error { NativeToolError(message: error) }
            if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green).font(NativeDesktopTheme.font(12)) }
            switch section {
            case "notifications": notificationPanel
            case "calendar": calendarPanel
            default: advancedPanel
            }
        }.disabled(busy)
            .task(id: section) { await reload() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
    }
    private var notificationPanel: some View {
        NativeSettingsGroup(title: "알림") {
            Toggle("알림 사용", isOn: boolean("enabled", fallback: true)).accessibilityIdentifier("native-settings-notifications-enabled")
            if ["denied", "restricted"].contains((status["notifications"] as? [String: Any])?["authorization"] as? String) {
                HStack { Text("iPad 설정에서 알림이 꺼져 있어요").foregroundStyle(NativeDesktopTheme.secondary); Spacer(); Button("설정 열기") { systemSettings() } }
            }
            Group {
                Toggle("마감 알림", isOn: boolean("deadlines", fallback: true))
                let leadDays = notifications["leadDays"] as? [Int] ?? [3, 1]
                HStack { Text("미리 알림"); Spacer(); ForEach([7, 3, 1, 0], id: \.self) { day in
                    Button(day == 0 ? "당일" : "\(day)일 전") {
                        persist(["notifications": ["leadDays": leadDays.contains(day) ? leadDays.filter { $0 != day } : (leadDays + [day]).sorted(by: >)]])
                    }.buttonStyle(NativeToolButtonStyle(primary: leadDays.contains(day), compact: true))
                } }
                Toggle("AI 응답 완료", isOn: boolean("agentComplete", fallback: true))
                Toggle("다운로드 완료", isOn: boolean("downloads", fallback: true))
                Toggle("알림 소리", isOn: boolean("sound", fallback: true))
                Toggle("반달을 쓰는 동안 숨기기", isOn: boolean("suppressWhileFocused", fallback: true))
            }.disabled(notifications["enabled"] as? Bool == false)
        }
    }
    private var calendarPanel: some View {
        VStack(spacing: 28) {
            NativeSettingsGroup(title: "Apple 캘린더", description: "고른 캘린더의 일정을 반달에서 보여 줘요.") {
                LabeledContent("접근 권한", value: authorization(calendar["authorization"]))
                HStack { Button("캘린더 접근 허용") { permission("calendar") }; Button("Apple 캘린더 열기") { run { _ = try await store.invokePrivate("nativeSettings:openCalendar") } } }
                if calendar["authorization"] as? String == "denied" { Button("시스템 설정에서 변경") { systemSettings() } }
                if !calendars.isEmpty {
                    Text("표시할 캘린더").fontWeight(.medium)
                    ForEach(Array(calendars.enumerated()), id: \.offset) { _, item in
                        if let id = item["id"] as? String {
                            Toggle(item["title"] as? String ?? "캘린더", isOn: Binding(get: { selectedCalendars.contains(id) }, set: { enabled in configureCalendars(enabled ? selectedCalendars + [id] : selectedCalendars.filter { $0 != id }) }))
                        }
                    }

                } else if calendar["authorization"] as? String == "authorized" { Text("사용할 수 있는 캘린더가 없습니다. Apple 캘린더 앱에서 계정을 확인하세요.").foregroundStyle(NativeDesktopTheme.secondary) }
                if !selectedCalendars.isEmpty { Button("캘린더 연결 해제", role: .destructive) { run { _ = try await store.invokePrivate("nativeSettings:disconnectCalendar"); await reload() } } }
            }
            NativeSettingsGroup(title: "반달 일정 내보내기", description: ".ics 파일로 저장하거나 공유해요.") {
                Button("모든 폴더 일정 내보내기", systemImage: "square.and.arrow.up") { run { _ = try await store.invokePrivate("nativeSettings:exportCalendar") } }
                if let course = store.selectedCourseID { Button("현재 폴더 일정 내보내기") { run { _ = try await store.invokePrivate("nativeSettings:exportCalendar", ["courseId": course]) } } }
        }
    }
    }
    /// 일반 › 고급: the three maintenance actions; the two destructive ones confirm on the button.
    private var advancedPanel: some View {
        NativeSettingsGroup(title: "고급") {
            Button("진단 파일 내보내기", systemImage: "square.and.arrow.up") { exportDiagnostics() }.accessibilityIdentifier("native-settings-export-diagnostics")
            Button("캐시 비우기", systemImage: "trash") { confirmation = "cache" }
                .bandalConfirm("캐시를 비울까요?", isPresented: confirming("cache"), message: "다시 만들 수 있는 임시 파일만 지워요.", action: "캐시 비우기", destructive: true) { maintain("cache") }
            Button("설정 초기화", role: .destructive) { confirmation = "reset" }.accessibilityIdentifier("native-settings-reset")
                .bandalConfirm("설정을 초기화할까요?", isPresented: confirming("reset"), message: "환경설정만 기본값으로 돌아가요. 자료·계정·학교·언어는 그대로예요.", action: "설정 초기화", destructive: true) { maintain("reset") }
        }
    }
    private func confirming(_ id: String) -> Binding<Bool> { Binding(get: { confirmation == id }, set: { if !$0 && confirmation == id { confirmation = nil } }) }
    private func maintain(_ action: String) {
        confirmation = nil
        run {
            if action == "reset" {
                let result = try await store.invoke("settings:reset") as? [String: Any] ?? [:]
                NativeAppearancePreference.apply(result); notice = "설정을 초기화했어요."
            } else {
                let result = try await store.invokePrivate("nativeSettings:clearCache") as? [String: Any] ?? [:]
                notice = "캐시 \(Self.bytes(result["removedBytes"]))를 비웠어요."
            }
            await reload()
        }
    }
    private func boolean(_ key: String, fallback: Bool) -> Binding<Bool> { Binding(get: { notifications[key] as? Bool ?? fallback }, set: { persist(["notifications": [key: $0]]) }) }
    private func persist(_ patch: [String: Any]) { run { try await save(patch) } }
    private func permission(_ id: String) { run { status = try await store.invokePrivate("nativeSettings:requestPermission", ["id": id]) as? [String: Any] ?? status } }
    private func systemSettings() { run { _ = try await store.invokePrivate("nativeSettings:openSystemSettings") } }
    private func exportDiagnostics() { run { _ = try await store.invokePrivate("nativeSettings:exportDiagnostics") } }
    private func configureCalendars(_ selected: [String]) {
        run {
            _ = try await store.invokePrivate("nativeSettings:configureCalendar", ["selectedCalendarIds": selected])
            await reload()
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) { guard !busy else { return }; busy = true; error = nil; notice = nil; Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } } }
    private func reload() async {
        do { status = try await store.invokePrivate("nativeSettings:status") as? [String: Any] ?? [:] }
        catch { self.error = error.localizedDescription }
    }
    private func authorization(_ value: Any?) -> String { switch value as? String { case "authorized", "granted": return "허용됨"; case "provisional": return "임시 허용"; case "denied", "restricted": return "허용되지 않음"; case "unsupported", "unavailable": return "지원되지 않음"; default: return "요청 전" } }
    static func bytes(_ value: Any?) -> String { guard let value = value as? NSNumber else { return "확인 중" }; return ByteCountFormatter.string(fromByteCount: value.int64Value, countStyle: .file) }
}

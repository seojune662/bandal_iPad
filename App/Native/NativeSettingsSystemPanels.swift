import SwiftUI

struct NativeSettingsSystemPanels: View {
    let section: String
    @ObservedObject var store: NativeWorkspaceStore
    let settings: [String: Any]
    let save: @MainActor ([String: Any]) async throws -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: [String: Any] = [:]
    @State private var usage: [String: Any] = [:]
    @State private var windowDays = 30
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
        VStack(alignment: .leading, spacing: 24) {
            if let error { NativeToolError(message: error) }
            if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green).font(NativeDesktopTheme.font(12)) }
            switch section {
            case "notifications": notificationPanel
            case "permissions": permissionPanel
            case "calendar": calendarPanel
            case "usage": usagePanel
            case "privacy": privacyPanel
            case "advanced": advancedPanel
            default: aboutPanel
            }
        }.disabled(busy)
            .task(id: section) { await reload() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
            .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button(confirmation == "reset" ? "설정 초기화" : "캐시 비우기", role: .destructive) {
                    let action = confirmation; confirmation = nil
                    run {
                        if action == "reset" {
                            let result = try await store.invoke("settings:reset") as? [String: Any] ?? [:]
                            NativeAppearancePreference.apply(result); notice = "설정을 초기화했습니다. 자료와 계정은 유지됩니다."
                        } else {
                            let result = try await store.invokePrivate("nativeSettings:clearCache") as? [String: Any] ?? [:]
                            notice = "캐시 \(Self.bytes(result["removedBytes"]))를 비웠습니다."
                        }
                        await reload()
                    }
                }
            } message: { Text(confirmation == "reset" ? "화면·탭·알림 등 환경설정을 기본값으로 되돌립니다. 자료·계정·학교와 언어는 유지됩니다." : "다시 만들 수 있는 임시 캐시를 삭제합니다. 자료 원본과 필기는 유지됩니다.") }
    }
    private var confirmationTitle: String { confirmation == "reset" ? "설정을 초기화할까요?" : "캐시를 비울까요?" }
    private var notificationPanel: some View {
        VStack(spacing: 24) {
            NativeSettingsCard(title: "OS 알림", description: "iPad의 알림 설정과 반달에서 보낼 알림 종류를 선택합니다.") {
                LabeledContent("알림 권한", value: authorization((status["notifications"] as? [String: Any])?["authorization"]))
                Toggle("알림 사용", isOn: boolean("enabled", fallback: true)).accessibilityIdentifier("native-settings-notifications-enabled")
                HStack { Button("알림 허용 요청") { permission("notifications") }; Button("시스템 설정 열기") { systemSettings() } }
                Button("테스트 알림 보내기") { run { _ = try await store.invokePrivate("nativeSettings:testNotification"); notice = "테스트 알림을 요청했습니다." } }
                if let count = (status["notifications"] as? [String: Any])?["pendingCount"] as? Int { LabeledContent("예약된 알림", value: String(count)) }
            }
            NativeSettingsCard(title: "알림 종류") {
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
                Toggle("반달을 사용하는 동안 알림 숨기기", isOn: boolean("suppressWhileFocused", fallback: true))
            }.disabled(notifications["enabled"] as? Bool == false)
        }
    }
    private var permissionPanel: some View {
        NativeSettingsCard(title: "시스템 권한", description: "기능을 사용하기 전에 현재 기기의 권한 상태를 확인합니다.") {
            ForEach(Array((status["permissions"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, permission in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(permission["title"] as? String ?? "권한").fontWeight(.medium); Spacer(); Text(authorization(permission["status"])).foregroundStyle(NativeDesktopTheme.secondary) }
                    if let detail = permission["detail"] as? String { Text(detail).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted) }
                    if let id = permission["id"] as? String, ["notifications", "microphone", "calendar", "camera"].contains(id) {
                        Button("권한 요청") { self.permission(id) }.accessibilityIdentifier("native-settings-permission-" + id)
                    }
                    Divider()
                }
            }
            Button("시스템 설정 열기", systemImage: "arrow.up.forward.app") { systemSettings() }
            Button("권한 상태 새로고침", systemImage: "arrow.clockwise") { Task { await reload() } }
        }
    }
    private var calendarPanel: some View {
        VStack(spacing: 24) {
            NativeSettingsCard(title: "Apple 캘린더", description: "선택한 캘린더의 일정을 반달에서 읽습니다. 반달 일정은 파일로 내보내 Apple 캘린더에 추가할 수 있습니다.") {
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
            NativeSettingsCard(title: "반달 일정 내보내기", description: "일정이 담긴 .ics 파일을 만들고 저장 또는 공유할 위치를 직접 선택합니다.") {
                Button("모든 과목 일정 내보내기", systemImage: "square.and.arrow.up") { run { _ = try await store.invokePrivate("nativeSettings:exportCalendar") } }
                if let course = store.selectedCourseID { Button("현재 과목 일정 내보내기") { run { _ = try await store.invokePrivate("nativeSettings:exportCalendar", ["courseId": course]) } } }
        }
    }
    }
    private var usagePanel: some View {
        NativeSettingsCard(title: "AI 사용 통계", description: "이 기기에 저장된 대화 기록을 기준으로 표시합니다. 제공자의 과금 내역과 다를 수 있습니다.") {
            Picker("기간", selection: $windowDays) { Text("7일").tag(7); Text("30일").tag(30); Text("전체").tag(0) }.pickerStyle(.segmented).onChange(of: windowDays) { _, _ in Task { await loadUsage() } }
            LabeledContent("대화", value: metric(usage["sessions"]))
            LabeledContent("입력 토큰", value: metric(usage["inputTokens"]))
            LabeledContent("출력 토큰", value: metric(usage["outputTokens"]))
            ForEach(Array((usage["providers"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, provider in
                Divider(); Text(provider["provider"] as? String ?? "AI").fontWeight(.medium)
                LabeledContent("대화", value: metric(provider["sessions"]))
                LabeledContent("입력 / 출력 토큰", value: metric(provider["inputTokens"]) + " / " + metric(provider["outputTokens"]))
            }
            Button("새로고침", systemImage: "arrow.clockwise") { Task { await loadUsage() } }
        }
    }
    private var privacyPanel: some View {
        VStack(spacing: 24) {
            NativeSettingsCard(title: "데이터 처리") {
                Text(!NativeReleaseFlags.legacyCloudSync ? (NativeReleaseFlags.showsRecording ? "자료 원본, 필기, 녹음과 대화 기록은 기기에 저장됩니다." : "자료 원본, 필기와 대화 기록은 기기에 저장됩니다.") : "자료 원본, 필기, 녹음과 대화 기록은 기기에 저장됩니다. 계정 동기화를 사용하면 연결한 동기화 서버에도 저장됩니다.")
                if NativeReleaseFlags.showsAccount { Text("반달 계정 로그인은 선택 사항입니다. 로그인하면 이메일과 닉네임이 반달 계정 서버에 저장됩니다. 자료와 필기는 올라가지 않습니다.") }
                Text("AI 기능은 선택 사항입니다. 제공자별로 처음 보내기 전에 동의를 받고, 질문과 AI가 읽은 자료를 이 기기에서 선택한 제공자에게 직접 전송합니다. 크런치맬로 서버를 거치지 않습니다. API 키는 이 기기의 Keychain에 저장됩니다.")
                Text(NativeReleaseFlags.showsRecording ? "음성 전사는 다운로드한 모델로 기기에서 처리합니다. 학교 웹사이트와 브라우저는 방문한 서비스의 정책을 따릅니다." : "학교 웹사이트와 브라우저는 방문한 서비스의 정책을 따릅니다.")
            }
            NativeSettingsCard(title: "진단 파일", description: "문제 해결에 필요한 앱 버전과 상태 정보를 파일로 공유합니다. 저장 위치를 직접 선택할 수 있습니다.") {
                Button("진단 파일 내보내기", systemImage: "square.and.arrow.up") { exportDiagnostics() }.accessibilityIdentifier("native-settings-export-diagnostics")
            }
        }
    }
    private var advancedPanel: some View {
        VStack(spacing: 24) {
            NativeSettingsCard(title: "자료 저장 위치") {
                Text((status["storage"] as? [String: Any])?["rootPath"] as? String ?? store.root.path).font(NativeDesktopTheme.font(12, design: .monospaced)).textSelection(.enabled)
                LabeledContent("문서 데이터", value: Self.bytes((status["storage"] as? [String: Any])?["documentsBytes"]))
                LabeledContent("캐시", value: Self.bytes((status["storage"] as? [String: Any])?["cacheBytes"]))
                Text("과목별 외부 폴더는 과목 설정에서 연결합니다. 저장 경로만 바꾸어 기존 자료를 이동하지 않습니다.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary)
            }
            NativeSettingsCard(title: "유지 관리") {
                Button("진단 파일 내보내기", systemImage: "square.and.arrow.up") { exportDiagnostics() }
                Button("캐시 비우기", systemImage: "trash") { confirmation = "cache" }
                Button("설정 초기화", role: .destructive) { confirmation = "reset" }.accessibilityIdentifier("native-settings-reset")
            }
        }
    }
    private var aboutPanel: some View {
        NativeSettingsCard(title: "업데이트와 실행 환경") {
            LabeledContent("플랫폼", value: status["platform"] as? String ?? "iPadOS")
            Text("이 설치는 서명된 iPad 앱입니다. 새 버전은 배포 경로에서 설치하며 데스크톱 자동 업데이터나 로그인 시 실행 기능은 사용하지 않습니다.").foregroundStyle(NativeDesktopTheme.secondary)
            Button("진단 파일 내보내기") { exportDiagnostics() }
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
        do { status = try await store.invokePrivate("nativeSettings:status") as? [String: Any] ?? [:]; if section == "usage" { await loadUsage() } }
        catch { self.error = error.localizedDescription }
    }
    private func loadUsage() async { do { usage = try await store.invokePrivate("nativeSettings:usage", ["windowDays": windowDays]) as? [String: Any] ?? [:] } catch { self.error = error.localizedDescription } }
    private func authorization(_ value: Any?) -> String { switch value as? String { case "authorized", "granted": return "허용됨"; case "provisional": return "임시 허용"; case "denied", "restricted": return "허용되지 않음"; case "unsupported", "unavailable": return "지원되지 않음"; default: return "요청 전" } }
    private func metric(_ value: Any?) -> String { (value as? NSNumber).map { NumberFormatter.localizedString(from: $0, number: .decimal) } ?? "수집되지 않음" }
    static func bytes(_ value: Any?) -> String { guard let value = value as? NSNumber else { return "확인 중" }; return ByteCountFormatter.string(fromByteCount: value.int64Value, countStyle: .file) }
}

import SwiftUI

struct NativeSettingsBrowserPanel: View {
    @ObservedObject var store: NativeWorkspaceStore
    let settings: [String: Any]
    let save: @MainActor ([String: Any]) async throws -> Void
    @State private var homePage = ""
    @State private var profiles: [[String: String]] = []
    @State private var profile = "default"
    @State private var profileName = ""
    @State private var sites: [[String: Any]] = []
    @State private var permissions: [[String: Any]] = []
    @State private var history: [[String: Any]] = []
    @State private var historyQuery = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var deletion: Deletion?
    private struct Deletion { let title: String; let channel: String; let request: [String: Any] }
    private var browser: [String: Any] { settings["browser"] as? [String: Any] ?? [:] }
    var body: some View {
        VStack(spacing: 24) {
            if let error { NativeToolError(message: error) }
            if let notice { Text(notice).foregroundStyle(.green).font(NativeDesktopTheme.font(12)) }
            navigation
            protection
            profilePanel
            siteData
            permissionPanel
        }.disabled(busy)
            .task { homePage = browser["homePage"] as? String ?? ""; await loadProfiles(); await loadData() }
            .onChange(of: profile) { _, _ in Task { await loadData() } }
            .confirmationDialog(deletion?.title ?? "데이터를 삭제할까요?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("삭제", role: .destructive) {
                    guard let choice = deletion else { return }; deletion = nil
                    run { _ = try await store.invoke(choice.channel, choice.request); await loadProfiles(); await loadData(); notice = "선택한 데이터를 삭제했습니다." }
                }
            } message: { Text("선택한 프로필에만 적용됩니다. 로그인 정보나 사이트 데이터가 삭제되면 다시 로그인해야 할 수 있습니다.") }
    }
    private var navigation: some View {
        NativeSettingsCard(title: "홈페이지·검색·확대/축소", description: "새 브라우저 페이지에서 사용할 기본값입니다.") {
            TextField("홈페이지 · 비워두면 빈 페이지", text: $homePage).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().nativeToolField().accessibilityIdentifier("native-settings-browser-home")
            Button("홈페이지 저장") { run { let value = homePage.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { _ = try NativeSettingsValidation.webURL(value) }; try await save(["browser": ["homePage": value]]) } }
            Picker("검색 엔진", selection: Binding(get: { settings["browserSearchEngine"] as? String ?? "google" }, set: { value in persist(["browserSearchEngine": value]) })) { Text("Google").tag("google"); Text("네이버").tag("naver"); Text("다음").tag("daum"); Text("DuckDuckGo").tag("duckduckgo") }.accessibilityIdentifier("native-settings-search-engine")
            Picker("기본 확대/축소", selection: Binding(get: { (browser["defaultZoomLevel"] as? NSNumber)?.doubleValue ?? 0 }, set: { persist(["browser": ["defaultZoomLevel": $0]]) })) {
                ForEach([-2.0, -1.0, 0.0, 1.0, 2.0, 3.0], id: \.self) { level in Text("\(Int((pow(1.2, level) * 100).rounded()))%").tag(level) }
            }
            Picker("앱에서 누른 웹 링크", selection: string("linkRouting", fallback: "in-app")) { Text("반달 브라우저").tag("in-app"); Text("시스템 브라우저").tag("system") }
            Toggle("스와이프로 뒤로·앞으로 이동", isOn: boolean("swipeNavigation", fallback: true))
        }
    }
    private var protection: some View {
        NativeSettingsCard(title: "웹 탐색과 보호") {
            Toggle("AI의 브라우저 접근 허용", isOn: boolean("agentUse", fallback: true))
            Toggle("추적 거부 요청", isOn: boolean("doNotTrack", fallback: true))
            Picker("추적 방지", selection: string("trackingProtection", fallback: "balanced")) { Text("사용 안 함").tag("off"); Text("균형").tag("balanced"); Text("엄격").tag("strict") }
            Picker("팝업", selection: string("popupBehavior", fallback: "balanced")) { Text("균형").tag("balanced"); Text("허용한 사이트만").tag("strict") }
            Text("사이트 권한은 프로필별로 저장됩니다. 엄격한 추적 방지는 일부 사이트의 로그인이나 동영상 재생에 영향을 줄 수 있습니다.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary)
        }
    }
    private var profilePanel: some View {
        NativeSettingsCard(title: "브라우저 프로필", description: "로그인·방문 기록·사이트 권한을 프로필별로 구분합니다.") {
            Picker("프로필", selection: $profile) { ForEach(profiles, id: \.profileID) { Text($0["name"] ?? "프로필").tag($0["id"] ?? "default") } }.accessibilityIdentifier("native-settings-browser-profile")
            TextField("새 프로필 이름", text: $profileName).nativeToolField()
            HStack {
                Button("프로필 추가") { run { _ = try await store.invoke("browser:saveProfile", ["name": profileName, "color": "blue", "icon": "globe"]); profileName = ""; await loadProfiles() } }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if profile != "default" { Button("선택한 프로필 삭제", role: .destructive) { deletion = .init(title: "프로필과 저장된 웹 데이터를 삭제할까요?", channel: "browser:deleteProfile", request: ["id": profile]) } }
            }
        }
    }
    private var siteData: some View {
        NativeSettingsCard(title: "브라우징 데이터", description: "선택한 프로필의 방문 기록과 사이트 로그인을 관리합니다.") {
            DisclosureGroup("사이트 로그인 · \(sites.count)개") {
                if sites.isEmpty { Text("저장된 사이트 쿠키가 없습니다.").foregroundStyle(NativeDesktopTheme.muted) }
                ForEach(Array(sites.enumerated()), id: \.offset) { _, site in
                    if let origin = site["origin"] as? String {
                        HStack { Text(origin).lineLimit(2); Spacer(); Button("로그아웃") { deletion = .init(title: "\(origin)의 쿠키를 삭제할까요?", channel: "browser:clearSession", request: ["profileId": profile, "origin": origin]) } }
                    }
                }
            }
            DisclosureGroup("방문 기록") {
                HStack { TextField("기록 검색", text: $historyQuery).nativeToolField(); Button("검색") { Task { await loadHistory() } } }
                ForEach(Array(history.enumerated()), id: \.offset) { _, visit in
                    VStack(alignment: .leading, spacing: 3) { Text(visit["title"] as? String ?? ""); Text(visit["url"] as? String ?? "").font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted).textSelection(.enabled) }
                }
                if history.isEmpty { Text("방문 기록이 없습니다.").foregroundStyle(NativeDesktopTheme.muted) }
                Button("이 프로필의 방문 기록 삭제", role: .destructive) { deletion = .init(title: "방문 기록을 삭제할까요?", channel: "browser:clearHistory", request: ["profileId": profile]) }
            }
            Button("쿠키·사이트 저장소·캐시 삭제", role: .destructive) { deletion = .init(title: "이 프로필의 모든 웹 데이터를 삭제할까요?", channel: "browser:clearStorage", request: ["profileId": profile, "cache": true]) }
        }
    }
    private var permissionPanel: some View {
        NativeSettingsCard(title: "사이트 권한") {
            if permissions.isEmpty { Text("저장된 사이트 권한이 없습니다.").foregroundStyle(NativeDesktopTheme.muted) }
            ForEach(Array(permissions.enumerated()), id: \.offset) { _, permission in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(permission["origin"] as? String ?? ""); Text((permission["permission"] as? String ?? "권한") + " · " + (permission["decision"] as? String == "granted" ? "허용" : "차단")).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary) }
                    Spacer()
                    Button("재설정") { run { guard let id = permission["id"] as? String else { return }; _ = try await store.invoke("browser:forgetPermission", ["profileId": profile, "id": id]); await loadData() } }
                }
            }
        }
    }
    private func boolean(_ key: String, fallback: Bool) -> Binding<Bool> { Binding(get: { browser[key] as? Bool ?? fallback }, set: { persist(["browser": [key: $0]]) }) }
    private func string(_ key: String, fallback: String) -> Binding<String> { Binding(get: { browser[key] as? String ?? fallback }, set: { persist(["browser": [key: $0]]) }) }
    private func persist(_ patch: [String: Any]) { run { try await save(patch) } }
    private func run(_ action: @escaping @MainActor () async throws -> Void) { guard !busy else { return }; busy = true; error = nil; notice = nil; Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } } }
    private func loadProfiles() async { do { profiles = try await store.invoke("browser:profiles") as? [[String: String]] ?? []; if !profiles.contains(where: { $0["id"] == profile }) { profile = "default" } } catch { self.error = error.localizedDescription } }
    private func loadData() async {
        let expected = profile
        do {
            let cookies = try await store.invoke("browser:sessionSites", ["profileId": expected]) as? [String: Any] ?? [:]
            let rights = try await store.invoke("browser:sitePermissions", ["profileId": expected]) as? [String: Any] ?? [:]
            guard profile == expected else { return }; sites = cookies["sites"] as? [[String: Any]] ?? []; permissions = rights["permissions"] as? [[String: Any]] ?? []; await loadHistory()
        } catch { self.error = error.localizedDescription }
    }
    private func loadHistory() async {
        let expected = profile, query = historyQuery
        do { let result = try await store.invoke("browser:searchHistory", ["profileId": expected, "query": query, "limit": 100]) as? [String: Any] ?? [:]; guard expected == profile, query == historyQuery else { return }; history = result["entries"] as? [[String: Any]] ?? [] }
        catch { self.error = error.localizedDescription }
    }
}
private extension Dictionary where Key == String, Value == String { var profileID: String { self["id"] ?? "" } }

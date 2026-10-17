import SwiftUI

struct NativeUniversityService: Identifiable {
    let id: String
    let label: String
    let kind: String
    let url: String
    let opensExternally: Bool
    let secondary: Bool
    let note: String?
    let custom: Bool
    let hidden: Bool
}
enum NativeUniversityCatalog {
    static let data: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "universities", withExtension: "json", subdirectory: "DesktopNative"),
              let data = try? Data(contentsOf: url), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }()
    static var universities: [[String: Any]] { data["universities"] as? [[String: Any]] ?? [] }
    static func university(_ settings: [String: Any]) -> [String: Any]? {
        let value = settings["university"] as? [String: Any] ?? [:]
        guard let id = value["universityId"] as? String else { return nil }
        if id.hasPrefix("custom:"), let custom = value["customUniversity"] as? [String: Any], custom["id"] as? String == id { return custom }
        return universities.first { $0["id"] as? String == id }
    }
    static func resolvedServices(settings: [String: Any], includeHidden: Bool = false) -> [NativeUniversityService] {
        let value = settings["university"] as? [String: Any] ?? [:]
        let base = (university(settings)?["services"] as? [[String: Any]] ?? []) + (data["common"] as? [[String: Any]] ?? [])
        let custom = value["customServices"] as? [[String: Any]] ?? []
        let hidden = Set(value["hiddenServiceIds"] as? [String] ?? [])
        let external = value["openExternallyOverrides"] as? [String: Bool] ?? [:]
        let secondary = value["secondaryOverrides"] as? [String: Bool] ?? [:]
        let order = value["serviceOrder"] as? [String] ?? []
        var seen = Set<String>()
        let result: [NativeUniversityService] = (base + custom).compactMap { item in
            guard let id = item["id"] as? String, seen.insert(id).inserted, let url = item["url"] as? String,
                  (try? NativeSettingsValidation.webURL(url)) != nil, includeHidden || !hidden.contains(id) else { return nil }
            return NativeUniversityService(id: id, label: item["label"] as? String ?? url, kind: item["kind"] as? String ?? "other", url: url, opensExternally: external[id] ?? item["opensExternally"] as? Bool ?? false, secondary: secondary[id] ?? item["secondary"] as? Bool ?? false, note: item["note"] as? String, custom: custom.contains { $0["id"] as? String == id }, hidden: hidden.contains(id))
        }
        return result.enumerated().sorted { left, right in
            let l = order.firstIndex(of: left.element.id) ?? (order.count + left.offset), r = order.firstIndex(of: right.element.id) ?? (order.count + right.offset)
            return l < r
        }.map(\.element)
    }
}

struct NativeSettingsUniversityPanel: View {
    @ObservedObject var store: NativeWorkspaceStore
    let settings: [String: Any]
    let save: @MainActor ([String: Any]) async throws -> Void
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @State private var customName = ""
    @State private var label = ""
    @State private var url = ""
    @State private var kind = "other"
    @State private var busy = false
    @State private var error: String?
    private var university: [String: Any] { settings["university"] as? [String: Any] ?? [:] }
    private var services: [NativeUniversityService] { NativeUniversityCatalog.resolvedServices(settings: settings, includeHidden: true) }
    private var results: [[String: Any]] {
        NativeUniversityCatalog.universities.filter { item in
            query.isEmpty || ([item["nameKo"] as? String ?? "", item["nameEn"] as? String ?? "", item["domain"] as? String ?? ""] + (item["aliases"] as? [String] ?? [])).contains { $0.localizedStandardContains(query) }
        }
    }
    var body: some View {
        VStack(spacing: 24) {
            if let error { NativeToolError(message: error) }
            NativeSettingsCard(title: "내 학교", description: "학교를 선택하면 학사·강의실·도서관 바로가기가 표시됩니다.") {
                if let chosen = NativeUniversityCatalog.university(settings) {
                    Label(chosen["nameKo"] as? String ?? "내 학교", systemImage: "building.columns").fontWeight(.medium)
                    Button("선택 해제") { persist(["universityId": NSNull(), "customUniversity": NSNull()]) }
                }
                TextField("학교 이름 또는 약칭 검색", text: $query).nativeToolField().accessibilityIdentifier("native-settings-university-search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                            Button {
                                persist(["universityId": item["id"] ?? NSNull(), "customUniversity": NSNull()])
                            } label: {
                                HStack { Text(item["nameKo"] as? String ?? ""); Spacer(); if item["id"] as? String == university["universityId"] as? String { Image(systemName: "checkmark") } }
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("native-settings-university-" + (item["id"] as? String ?? ""))
                        }
                    }
                }.frame(maxHeight: 200)
                DisclosureGroup("학교 직접 추가") {
                    TextField("학교 이름", text: $customName).nativeToolField()
                    Button("학교 추가") {
                        let id = "custom:" + UUID().uuidString
                        persist(["universityId": id, "customUniversity": ["id": id, "nameKo": customName.trimmingCharacters(in: .whitespacesAndNewlines), "nameEn": "", "domain": "", "aliases": [], "services": [], "verifiedAt": ""]])
                    }.disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            NativeSettingsCard(title: "학교 사이트", description: "표시 순서와 열리는 위치를 선택합니다. 보안 프로그램이 필요한 일부 사이트는 iPad에서 제공되지 않을 수 있습니다.") {
                ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(service.label).fontWeight(.medium); Spacer(); Button("열기", systemImage: "arrow.up.right") { open(service) } }
                        Text(service.url).font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted).textSelection(.enabled)
                        if let note = service.note { Text(note).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary) }
                        Toggle("사이드바에 표시", isOn: Binding(get: { !service.hidden }, set: { visible in
                            let hidden = university["hiddenServiceIds"] as? [String] ?? []
                            persist(["hiddenServiceIds": visible ? hidden.filter { $0 != service.id } : hidden + [service.id]])
                        }))
                        Toggle("시스템 브라우저에서 열기", isOn: Binding(get: { service.opensExternally }, set: { value in var overrides = university["openExternallyOverrides"] as? [String: Bool] ?? [:]; overrides[service.id] = value; persist(["openExternallyOverrides": overrides]) }))
                        Toggle("더보기에 표시", isOn: Binding(get: { service.secondary }, set: { value in var overrides = university["secondaryOverrides"] as? [String: Bool] ?? [:]; overrides[service.id] = value; persist(["secondaryOverrides": overrides]) }))
                        HStack {
                            Button("위로", systemImage: "arrow.up") { move(index, by: -1) }.disabled(index == 0)
                            Button("아래로", systemImage: "arrow.down") { move(index, by: 1) }.disabled(index == services.count - 1)
                            Spacer()
                            if service.custom { Button("삭제", role: .destructive) { persist(["customServices": (university["customServices"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != service.id }]) } }
                        }
                        Divider()
                    }
                }
                DisclosureGroup("사이트 직접 추가") {
                    TextField("사이트 이름", text: $label).nativeToolField()
                    TextField("https://", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().nativeToolField()
                    Picker("종류", selection: $kind) { ForEach([("portal", "학사·포털"), ("lms", "강의실"), ("registration", "수강신청"), ("library", "도서관"), ("mail", "메일"), ("homepage", "홈페이지"), ("community", "커뮤니티"), ("other", "기타")], id: \.0) { Text($0.1).tag($0.0) } }
                    Button("사이트 추가") { add() }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.isEmpty)
                }
            }
        }.disabled(busy)
    }
    private func move(_ index: Int, by delta: Int) { var ids = services.map(\.id); guard ids.indices.contains(index + delta) else { return }; ids.swapAt(index, index + delta); persist(["serviceOrder": ids]) }
    private func add() {
        do { let address = try NativeSettingsValidation.webURL(url); var custom = university["customServices"] as? [[String: Any]] ?? []; custom.append(["id": "custom:" + UUID().uuidString, "label": label, "url": address.absoluteString, "kind": kind, "verification": "unverified"]); persist(["customServices": custom]) }
        catch { self.error = error.localizedDescription }
    }
    private func open(_ service: NativeUniversityService) {
        guard let url = URL(string: service.url) else { return }
        if service.opensExternally { openURL(url) }
        else { store.events.send(.init(channel: "nativeWorkspace:openBrowserURL", payload: ["url": service.url])) }
    }
    private func persist(_ patch: [String: Any]) { guard !busy else { return }; busy = true; error = nil; Task { defer { busy = false }; do { try await save(["university": patch]) } catch { self.error = error.localizedDescription } } }
}

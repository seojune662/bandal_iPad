import SwiftUI

/// Shared controls keep the desktop category layout while using native input,
/// focus and accessibility. Persistence is supplied by the owning workspace.
/// Cursor-density settings group: an 11pt grey caps header (and at most one line of help) over a
/// card with 12pt padding and 36pt rows.
struct NativeSettingsCard<Content: View>: View {
    let title: String
    var description = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BandalSectionHeader(title).padding(.horizontal, 4)
            if !description.isEmpty { BandalText(description).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1).padding(.horizontal, 4) }
            VStack(alignment: .leading, spacing: 8) { content() }
                .font(.system(size: BandalMetrics.bodySize))
                .controlSize(.small)
                .padding(BandalMetrics.padding).frame(maxWidth: .infinity, alignment: .leading)
                .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: BandalMetrics.radius))
                .overlay(RoundedRectangle(cornerRadius: BandalMetrics.radius).strokeBorder(NativeDesktopTheme.border))
        }
        .buttonStyle(NativeToolButtonStyle()).tint(NativeDesktopTheme.accent)
    }
}

struct NativeSettingsSections: View {
    let section: String
    var store: NativeWorkspaceStore
    let settings: [String: Any]
    let save: @MainActor ([String: Any]) async throws -> Void
    let navigate: (String) -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var titlePrefix = ""
    @State private var mailURL = ""
    @State private var tab = "note"
    @State private var devices: [[String: Any]] = []
    @AppStorage(NativeLocalPreferences.newDocumentKind) private var newDocumentKind = "note"
    private var tabs: [String: Any] { settings["tabs"] as? [String: Any] ?? [:] }
    private var widgets: [String: Any] { settings["widgets"] as? [String: Any] ?? [:] }
    private var enabledWidgets: [String] { widgets["enabled"] as? [String] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error { NativeToolError(message: error) }
            switch section {
            case "general": general
            case "tabs": tabPanel
            case "widgets": widgetPanel
            case "university": NativeSettingsUniversityPanel(store: store, settings: settings, save: save)
            case "browser": NativeSettingsBrowserPanel(store: store, settings: settings, save: save)
            case "shortcuts": NativeSettingsShortcutsPanel(settings: settings, save: save)
            default: NativeSettingsSystemPanels(section: section, store: store, settings: settings, save: save)
            }
        }.disabled(busy)
            .task(id: section) {
                titlePrefix = tabs["markdownTitlePrefix"] as? String ?? "새 마크다운"
                mailURL = widgets["mailUrl"] as? String ?? ""
                if section == "tabs" {
                    do { devices = try await store.invoke("runtime:recordingDevices") as? [[String: Any]] ?? [] }
                    catch { self.error = error.localizedDescription }
                }
            }
    }
    private var general: some View {
        VStack(spacing: 24) {
            NativeSettingsCard(title: "언어") {
                Picker("언어", selection: string("locale", fallback: "ko-KR")) { Text("한국어").tag("ko-KR"); Text("English").tag("en-US") }
                    .accessibilityIdentifier("native-settings-locale")
            }
            NativeSettingsCard(title: "학교") {
                Button { navigate("university") } label: {
                    BandalSettingRow(title: "학교") { HStack(spacing: 4) { Text("계정에서 고르기"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }.foregroundStyle(NativeDesktopTheme.secondary) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("native-settings-school")
            }
            NativeSettingsCard(title: "새 문서") {
                BandalSettingRow(title: "새 탭 기본 문서", note: "홈의 새 노트 버튼과 새 탭 메뉴의 첫 선택") {
                    BandalSegmented(options: [("note", "노트"), ("markdown", "마크다운")], selection: $newDocumentKind, identifierPrefix: "native-settings-new-document-")
                }
                Divider()
                BandalSettingRow(title: "앱을 열면") {
                    BandalSegmented(options: [("restore", "이어서 쓰기"), ("home", "첫 화면")],
                        selection: Binding(get: { boolean("restoreLastCourse", fallback: true).wrappedValue ? "restore" : "home" }, set: { boolean("restoreLastCourse", fallback: true).wrappedValue = $0 == "restore" }),
                        identifierPrefix: "native-settings-launch-")
                }
                Divider()
                Toggle("새 탭을 현재 탭 옆에서 열기", isOn: boolean("openAdjacentTab", fallback: false)).accessibilityIdentifier("native-settings-adjacent-tabs")
            }
        }
    }
    private var tabPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach([("note", "마크다운"), ("recording", "녹음"), ("whiteboard", "노트"), ("board", "학업 보드")].filter { NativeReleaseFlags.showsRecording || $0.0 != "recording" }, id: \.0) { id, title in
                        Button(title) { tab = id }.buttonStyle(NativeToolButtonStyle(primary: tab == id, compact: true)).accessibilityIdentifier("native-settings-tab-" + id)
                    }
                }
            }
            switch tab {
            case "note":
                NativeSettingsCard(title: "새 마크다운") {
                    // Applies when the field loses focus or on Enter; no save button.
                    LabeledContent("제목 접두사") {
                        TextField("새 마크다운", text: $titlePrefix).multilineTextAlignment(.trailing).frame(maxWidth: 220)
                            .onSubmit { savePrefix() }.onChange(of: prefixFocused) { _, focused in if !focused { savePrefix() } }.focused($prefixFocused)
                            .accessibilityIdentifier("native-settings-markdown-prefix")
                    }
                }
            case "recording": recording
            case "whiteboard": NativeSettingsCard(title: "노트", description: "새로 만드는 노트의 배경을 선택합니다.") {
                Picker("기본 배경", selection: string("whiteboardBackground", group: "tabs", fallback: "grid")) {
                    Text("격자").tag("grid"); Text("점").tag("dots"); Text("줄").tag("lines"); Text("빈 배경").tag("blank")
                }.accessibilityIdentifier("native-settings-whiteboard-background")
            }
            default: NativeSettingsCard(title: "학업 보드", description: "새로 여는 보드의 기본 화면을 선택합니다.") {
                Picker("기본 보기", selection: string("boardDefaultView", group: "tabs", fallback: "calendar")) { Text("달력").tag("calendar"); Text("목록").tag("board") }
                Toggle("완료된 일정 숨기기", isOn: boolean("boardHideDone", group: "tabs", fallback: false))
            }
            }
        }
    }
    private var recording: some View {
        NativeSettingsCard(title: "녹음") {
            Picker("음성 모델", selection: string("recordingModel", group: "tabs", fallback: "zipformer-ko")) {
                Text("한국어 · Zipformer").tag("zipformer-ko"); Text("다국어 · SenseVoice").tag("sensevoice")
                if tabs["recordingModel"] as? String == "whisper-large-v3-turbo" { Text("Whisper · iPad에서 사용할 수 없음").tag("whisper-large-v3-turbo") }
            }
            Picker("마이크", selection: string("recordingDeviceId", group: "tabs", fallback: "default")) {
                Text("시스템 기본 마이크").tag("default")
                ForEach(devices.filter { $0["deviceId"] as? String != "default" }, id: \.stableID) { device in Text(device["label"] as? String ?? "마이크").tag(device["deviceId"] as? String ?? "default") }
            }
            Toggle("설정·자료 사이드바 열기", isOn: boolean("recordingSidebarOpen", group: "tabs", fallback: true))
            Toggle("새 자막을 자동으로 따라가기", isOn: boolean("recordingFollowTranscript", group: "tabs", fallback: true))
            Picker("재생 속도", selection: number("recordingPlaybackRate", group: "tabs", fallback: 1)) {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
        }
    }
    private var widgetPanel: some View {
        VStack(spacing: 24) {
            NativeSettingsCard(title: "오른쪽 위젯") {
                ForEach([("todo", "투두"), ("board", "학업 보드"), ("mail", "메일함")], id: \.0) { id, title in
                    HStack {
                        Toggle(title, isOn: Binding(get: { enabledWidgets.contains(id) }, set: { enabled in
                            let next = enabled ? enabledWidgets + [id] : enabledWidgets.filter { $0 != id }
                            let active = widgets["active"] as? String ?? "todo"
                            persist(["widgets": ["enabled": next, "active": next.contains(active) ? active : next.first ?? "todo"]])
                        })).accessibilityIdentifier("native-settings-widget-" + id)
                        if let position = enabledWidgets.firstIndex(of: id) {
                            Button("위로", systemImage: "arrow.up") { moveWidget(position, by: -1) }.labelStyle(.iconOnly).disabled(position == 0)
                            Button("아래로", systemImage: "arrow.down") { moveWidget(position, by: 1) }.labelStyle(.iconOnly).disabled(position == enabledWidgets.count - 1)
                        }
                    }
                }
                if enabledWidgets.contains("mail") {
                    LabeledContent("메일 주소") {
                        TextField("https://mail.example.edu", text: $mailURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing).frame(maxWidth: 260).onSubmit(saveMail)
                    }
                }
            }
        }
    }
    @FocusState private var prefixFocused: Bool
    private func savePrefix() {
        let value = titlePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != tabs["markdownTitlePrefix"] as? String else { return }
        persist(["tabs": ["markdownTitlePrefix": value]])
    }
    private func saveMail() {
        do { if !mailURL.isEmpty { _ = try NativeSettingsValidation.webURL(mailURL) }; persist(["widgets": ["mailUrl": mailURL]]) }
        catch { self.error = error.localizedDescription }
    }
    private func moveWidget(_ index: Int, by delta: Int) {
        var next = enabledWidgets; guard next.indices.contains(index + delta) else { return }; next.swapAt(index, index + delta); persist(["widgets": ["enabled": next]])
    }
    private func boolean(_ key: String, group: String? = nil, fallback: Bool) -> Binding<Bool> {
        Binding(get: { (group.flatMap { settings[$0] as? [String: Any] } ?? settings)[key] as? Bool ?? fallback }, set: { value in persist(group.map { [$0: [key: value]] } ?? [key: value]) })
    }
    private func string(_ key: String, group: String? = nil, fallback: String) -> Binding<String> {
        Binding(get: { (group.flatMap { settings[$0] as? [String: Any] } ?? settings)[key] as? String ?? fallback }, set: { value in persist(group.map { [$0: [key: value]] } ?? [key: value]) })
    }
    private func number(_ key: String, group: String, fallback: Double) -> Binding<Double> {
        Binding(get: { ((settings[group] as? [String: Any])?[key] as? NSNumber)?.doubleValue ?? fallback }, set: { persist([group: [key: $0]]) })
    }
    private func persist(_ patch: [String: Any]) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await save(patch) } catch { self.error = error.localizedDescription } }
    }
}

extension Dictionary where Key == String, Value == Any {
    fileprivate var stableID: String { self["id"] as? String ?? self["deviceId"] as? String ?? "" }
}

enum NativeSettingsValidation {
    static func webURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw DesktopRuntimeError("사용자 정보가 없는 HTTP 또는 HTTPS 주소를 입력하세요.") }
        return url
    }
}

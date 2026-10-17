import SwiftUI

/// Shared controls keep the desktop category layout while using native input,
/// focus and accessibility. Persistence is supplied by the owning workspace.
struct NativeSettingsCard<Content: View>: View {
    let title: String
    var description = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(NativeDesktopTheme.font(14, weight: .medium))
                if !description.isEmpty { Text(description).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(20)
            NativeDesktopTheme.border.frame(height: 1)
            VStack(alignment: .leading, spacing: NativeDesktopTheme.spacing(16)) { content() }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border))
            .buttonStyle(NativeToolButtonStyle()).tint(NativeDesktopTheme.accent)
    }
}

struct NativeSettingsSections: View {
    let section: String
    @ObservedObject var store: NativeWorkspaceStore
    let settings: [String: Any]
    let save: @MainActor ([String: Any]) async throws -> Void
    let navigate: (String) -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var titlePrefix = ""
    @State private var mailURL = ""
    @State private var tab = "note"
    @State private var devices: [[String: Any]] = []
    @State private var courseManager = false
    @State private var guide = false
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
            case "assistant": assistant
            case "packs", "experimental": extensions
            case "university": NativeSettingsUniversityPanel(store: store, settings: settings, save: save)
            case "browser": NativeSettingsBrowserPanel(store: store, settings: settings, save: save)
            case "shortcuts": NativeSettingsShortcutsPanel(settings: settings, save: save)
            case "courses": courses
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
            .sheet(isPresented: $courseManager) { NativeCourseManager(store: store) }
            .sheet(isPresented: $guide) { NativeSettingsGuide() }
    }
    private var general: some View {
        VStack(spacing: 24) {
            NativeSettingsCard(title: "언어", description: "설정의 분류와 메뉴 언어를 선택합니다. 아직 번역되지 않은 항목과 학습 화면은 한국어로 표시됩니다.") {
                Picker("언어", selection: string("locale", fallback: "ko-KR")) { Text("한국어").tag("ko-KR"); Text("English").tag("en-US") }
                    .accessibilityIdentifier("native-settings-locale")
            }
            NativeSettingsCard(title: "탭과 시작", description: "자료를 여는 위치와 다음 실행 시 복원할 내용을 선택합니다.") {
                Toggle("새 탭을 현재 탭 옆에서 열기", isOn: boolean("openAdjacentTab", fallback: false)).accessibilityIdentifier("native-settings-adjacent-tabs")
                Toggle("마지막 과목과 탭 복원", isOn: boolean("restoreLastCourse", fallback: true)).accessibilityIdentifier("native-settings-restore-course")
            }
            NativeSettingsCard(title: "반달 둘러보기", description: "자료 가져오기부터 필기와 여러 창 배치까지 사용 방법을 다시 확인하세요.") {
                Button("사용 방법 둘러보기", systemImage: "play.rectangle") { guide = true }.accessibilityIdentifier("native-settings-guide")
            }
        }
    }
    private var tabPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach([("note", "마크다운"), ("browser", "브라우저"), ("chat", "AI"), ("recording", "녹음"), ("whiteboard", "노트"), ("board", "학업 보드")], id: \.0) { id, title in
                        Button(title) { tab = id }.buttonStyle(NativeToolButtonStyle(primary: tab == id, compact: true)).accessibilityIdentifier("native-settings-tab-" + id)
                    }
                }
            }
            switch tab {
            case "note":
                NativeSettingsCard(title: "새 마크다운", description: "새로 만드는 텍스트 노트에 적용합니다.") {
                    TextField("제목 접두사", text: $titlePrefix).nativeToolField().accessibilityIdentifier("native-settings-markdown-prefix")
                    Button("제목 저장") { persist(["tabs": ["markdownTitlePrefix": titlePrefix]]) }.disabled(titlePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Picker("필기 글꼴", selection: string("editorFont", fallback: "sans")) { Text("산세리프").tag("sans"); Text("세리프").tag("serif"); Text("고정폭").tag("mono") }
                }
            case "browser": NativeSettingsCard(title: "브라우저", description: "홈페이지와 검색 엔진, 새 페이지의 배율을 관리합니다.") { Button("브라우저 설정으로 이동") { navigate("browser") } }
            case "chat": NativeSettingsCard(title: "AI", description: "제공자의 연결 상태와 모델을 확인합니다.") { Button("AI 엔진 설정으로 이동") { navigate("ai") } }
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
            NativeSettingsCard(title: "키보드로 탭 이동") { Text("⌘1–8로 탭을 선택하고, ⌘9로 마지막 탭을 엽니다. ⌘⇧[ / ⌘⇧]로 이전·다음 탭으로 이동합니다.").foregroundStyle(NativeDesktopTheme.secondary); Button("단축키 설정으로 이동") { navigate("shortcuts") } }
        }
    }
    private var recording: some View {
        NativeSettingsCard(title: "녹음", description: "다음에 여는 녹음 화면과 새 녹음에 적용합니다.") {
            Picker("음성 모델", selection: string("recordingModel", group: "tabs", fallback: "zipformer-ko")) {
                Text("한국어 · Zipformer").tag("zipformer-ko"); Text("다국어 · SenseVoice").tag("sensevoice")
                if tabs["recordingModel"] as? String == "whisper-large-v3-turbo" { Text("Whisper · iPad에서 사용할 수 없음").tag("whisper-large-v3-turbo") }
            }
            Text("iPad에서는 설치된 Zipformer와 SenseVoice 모델로 기기에서 전사합니다. 모델은 녹음 화면에서 다운로드할 수 있습니다.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary)
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
            NativeSettingsCard(title: "우측 사이드바 위젯", description: "사용할 위젯과 탭 순서를 선택합니다. 모두 끄면 위젯 영역이 숨겨집니다.") {
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
                Text("투두와 학업 보드는 기존 일정을 사용합니다. 메일함은 선택한 학교 메일 또는 아래 웹 주소를 엽니다.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary)
            }
            NativeSettingsCard(title: "메일 위젯 연결", description: "웹 메일의 전체 메일함을 표시합니다. Gmail API 계정 연결은 이 버전에서 제공되지 않습니다.") {
                TextField("https://mail.example.edu", text: $mailURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().nativeToolField()
                Button("메일 주소 저장") {
                    do { if !mailURL.isEmpty { _ = try NativeSettingsValidation.webURL(mailURL) }; persist(["widgets": ["mailUrl": mailURL]]) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }
    private var assistant: some View {
        NativeSettingsCard(title: "화면 읽기와 제어", description: "iPadOS는 다른 앱의 화면을 임의로 읽거나 클릭하는 권한을 제공하지 않습니다.") {
            Label("다른 앱 화면 제어 · 사용할 수 없음", systemImage: "rectangle.slash").foregroundStyle(NativeDesktopTheme.secondary)
            Text("반달의 AI는 선택한 과목의 자료를 읽고 답변합니다. 웹 접근 권한은 브라우저 설정에서 관리할 수 있습니다.")
            Button("브라우저의 AI 접근 설정") { navigate("browser") }
            Button("시스템 권한 확인") { navigate("permissions") }
        }
    }
    private var extensions: some View {
        NativeSettingsCard(title: section == "packs" ? "플러그인과 외부 서비스" : "확장 런타임", description: "데스크톱의 외부 명령·MCP 프로세스·Chromium 확장은 iPadOS 앱에서 실행할 수 없습니다.") {
            Label("데스크톱 확장 실행 · 지원되지 않음", systemImage: "shippingbox").foregroundStyle(NativeDesktopTheme.secondary)
            Text("동기화된 확장 설정은 보존됩니다. 이 기기에서 사용할 수 있는 연결은 AI API, 학교 웹사이트, Apple 캘린더입니다.")
            HStack { Button("AI 연결") { navigate("ai") }; Button("학교") { navigate("university") }; Button("달력") { navigate("calendar") } }
    }
    }
    private var courses: some View {
        NativeSettingsCard(title: "과목 관리", description: "과목 이름과 보관 상태, 파일 폴더 연결을 관리합니다.") {
            ForEach(store.courses) { course in Label(course.name, systemImage: "folder") }
            if store.courses.isEmpty { Text("등록된 과목이 없습니다.").foregroundStyle(NativeDesktopTheme.muted) }
            Button("과목 관리 열기", systemImage: "folder.badge.gearshape") { courseManager = true }
        }
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

private struct NativeSettingsGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("1 · 자료와 과목") { Text("왼쪽에서 과목을 만들거나 기존 폴더를 연결하세요. 자료실의 가져오기로 PDF·이미지·영상·음성을 추가합니다.") }
                Section("2 · 필기와 노트") { Text("PDF를 열고 Apple Pencil로 필기하세요. 새 필기 노트, 마크다운, 노트를 별도로 만들 수 있습니다.") }
                Section("3 · 여러 창 배치") { Text("탭 메뉴에서 이동·분할을 선택하거나 탭을 끌어 원하는 영역에 놓으세요. 영역의 경계를 끌면 비율을 바꿀 수 있습니다.") }
                Section("4 · AI와 녹음") { Text("AI 엔진에서 API 키를 연결하면 선택한 과목의 자료로 대화할 수 있습니다. 녹음은 모델을 설치한 뒤 기기에서 자막을 만듭니다.") }
                Section("5 · 저장과 동기화") { Text("편집 내용은 기기에 자동 저장됩니다. 계정에 로그인하면 다른 기기와 자료를 동기화할 수 있고, 충돌 사본은 계정 설정에서 확인할 수 있습니다.") }
            }.navigationTitle("반달 둘러보기").toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
    }
}

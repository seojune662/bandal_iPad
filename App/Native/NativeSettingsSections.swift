import SwiftUI

/// The help page's card: an 11pt grey caps header (and at most one line of help) over a card with
/// 12pt padding and 36pt rows. Settings draws `NativeSettingsGroup`.
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

/// A settings group as the design draws it (Figma 132:2769): a 13 pt Semibold header, a paper card
/// (radius 12, hairline, no padding) whose children are rows split by lines inset 16, and a 13 pt
/// footnote under the card. Every child of `content` is one row.
struct NativeSettingsGroup<Content: View>: View {
    var title = ""
    var description = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { BandalText(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityAddTraits(.isHeader) }
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(zip(rows.indices, rows)), id: \.1.id) { index, row in
                        if index > 0 { NativeDesktopTheme.border.frame(height: 1).padding(.leading, 16) }
                        // Its ideal height, always: a frame with only a minimum gives way when the stack is offered less.
                        row.padding(.horizontal, 16).padding(.vertical, NativeSettingsRowMetrics.inset).frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 16)).foregroundStyle(NativeDesktopTheme.text).padding(1)
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border))
            if !description.isEmpty { BandalText(description).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .buttonStyle(BandalButtonStyle(kind: .soft)).tint(NativeDesktopTheme.accent)
    }
}

enum NativeSettingsRowMetrics {
    /// What the group pads above and below every row; a row asks for its design height less this.
    static let inset: CGFloat = 6
    static let red = Color(uiColor: .systemRed)
    static let green = Color(uiColor: .systemGreen)
}

/// One row: title 16 (and a 13 pt note) on the left, the control on the right. `height` is the row's
/// height in the design: 47, 57 with a note, 61 around a segmented control.
struct NativeSettingsRow<Control: View>: View {
    let title: String
    var note: String?
    var tint = NativeDesktopTheme.text
    var height: CGFloat?
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                BandalText(title).foregroundStyle(tint)
                if let note { BandalText(note).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }.frame(minHeight: (height ?? (note == nil ? 47 : 57)) - 2 * NativeSettingsRowMetrics.inset).contentShape(Rectangle())
    }
}

extension NativeSettingsRow where Control == EmptyView {
    init(title: String, note: String? = nil, tint: Color = NativeDesktopTheme.text) { self.init(title: title, note: note, tint: tint) { EmptyView() } }
}

/// A row's value: 15 pt secondary, and the 13 pt chevron of a row that opens something.
struct NativeSettingsValue: View {
    var text = ""
    var chevron = true
    init(_ text: String = "", chevron: Bool = true) { self.text = text; self.chevron = chevron }
    var body: some View {
        HStack(spacing: 6) {
            if !text.isEmpty { BandalText(text).font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted) }
        }
    }
}

/// A switch row: 59 high, 57 with a note.
struct NativeSettingsToggle: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                BandalText(title)
                if let note { BandalText(note).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary) }
            }
        }.frame(minHeight: (note == nil ? 59 : 57) - 2 * NativeSettingsRowMetrics.inset)
    }
}

/// The row that ends a page: what the design leaves out of the page lives on the page it opens.
struct NativeSettingsMoreRow: View {
    let action: () -> Void
    var body: some View {
        NativeSettingsGroup {
            Button(action: action) { NativeSettingsRow(title: "더 보기") { NativeSettingsValue() } }.buttonStyle(.plain).accessibilityIdentifier("native-settings-more")
        }
    }
}

/// A destructive or plain action drawn as a 16 pt text row.
struct NativeSettingsActionRow: View {
    let title: String
    var note: String?
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { NativeSettingsRow(title: title, note: note, tint: destructive ? NativeSettingsRowMetrics.red : NativeDesktopTheme.text) }.buttonStyle(.plain)
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
    @State private var pickingLead = false
    @State private var pickingLocale = false
    @Environment(\.locale) private var locale
    private var tabs: [String: Any] { settings["tabs"] as? [String: Any] ?? [:] }
    private var widgets: [String: Any] { settings["widgets"] as? [String: Any] ?? [:] }
    private var enabledWidgets: [String] { widgets["enabled"] as? [String] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let error { NativeToolError(message: error) }
            switch section {
            case "general": general
            case "general-extra": generalExtra
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
    private var schoolName: String? { NativeUniversityCatalog.university(settings)?["nameKo"] as? String }
    private var notifications: [String: Any] { settings["notifications"] as? [String: Any] ?? [:] }
    private var leadDays: [Int] { notifications["leadDays"] as? [Int] ?? [3, 1] }
    private static func leadTitle(_ day: Int) -> String { day == 0 ? "당일" : day == 1 ? "하루 전" : "\(day)일 전" }
    /// 일반 as the design draws it (132:2769): 학교, 새 문서, 알림, 언어.
    private var general: some View {
        VStack(alignment: .leading, spacing: 28) {
            NativeSettingsGroup(title: "학교") {
                Button { navigate("university") } label: { NativeSettingsRow(title: "학교") { NativeSettingsValue(schoolName ?? "고르기") } }
                    .buttonStyle(.plain).accessibilityIdentifier("native-settings-school")
            }
            NativeSettingsGroup(title: "새 문서") {
                NativeSettingsRow(title: "새 탭 기본 문서", height: 61) {
                    BandalSegmented(options: [("note", "노트"), ("markdown", "마크다운")], selection: $newDocumentKind, identifierPrefix: "native-settings-new-document-")
                }
                NativeSettingsRow(title: "앱을 열면", height: 61) {
                    BandalSegmented(options: [("restore", "이어서 쓰기"), ("home", "첫 화면")],
                        selection: Binding(get: { boolean("restoreLastCourse", fallback: true).wrappedValue ? "restore" : "home" }, set: { boolean("restoreLastCourse", fallback: true).wrappedValue = $0 == "restore" }),
                        identifierPrefix: "native-settings-launch-")
                }
            }
            NativeSettingsGroup(title: "알림") {
                // Off also when all notifications are off; turning it on turns those on too.
                NativeSettingsToggle(title: "과제 마감 알림", isOn: Binding(get: { notifications["enabled"] as? Bool != false && notifications["deadlines"] as? Bool != false },
                                                                       set: { persist(["notifications": $0 ? ["enabled": true, "deadlines": true] : ["deadlines": false]]) }))
                    .accessibilityIdentifier("native-settings-deadline-alerts")
                Button { pickingLead = true } label: {
                    NativeSettingsRow(title: "알림 시간") { NativeSettingsValue(leadDays.isEmpty ? "없음" : leadDays.map { NativeAppLocale.string(Self.leadTitle($0), locale) }.joined(separator: " · ")) }
                }.buttonStyle(.plain).accessibilityIdentifier("native-settings-lead-days")
                    .bandalPopover(isPresented: $pickingLead, width: 220, radius: 16, padding: 8) {
                        VStack(spacing: 0) {
                            ForEach([7, 3, 1, 0], id: \.self) { day in
                                BandalMenuRow(Self.leadTitle(day), checked: leadDays.contains(day)) {
                                    persist(["notifications": ["leadDays": leadDays.contains(day) ? leadDays.filter { $0 != day } : (leadDays + [day]).sorted(by: >)]])
                                }.accessibilityIdentifier("native-settings-lead-day-\(day)")
                            }
                        }
                    }
            }
            NativeSettingsGroup {
                Button { pickingLocale = true } label: {
                    NativeSettingsRow(title: "언어") { NativeSettingsValue(settings["locale"] as? String == "en-US" ? "English" : "한국어") }
                }.buttonStyle(.plain).accessibilityIdentifier("native-settings-locale")
                    .bandalPopover(isPresented: $pickingLocale, width: 220, radius: 16, padding: 8) {
                        VStack(spacing: 0) {
                            ForEach([("ko-KR", "한국어"), ("en-US", "English")], id: \.0) { id, title in
                                BandalMenuRow(title, checked: (settings["locale"] as? String ?? "ko-KR") == id) { pickingLocale = false; persist(["locale": id]) }
                            }
                        }
                    }
            }
        }
    }
    /// 일반 › 더 보기: what the design's 새 문서 card leaves out.
    private var generalExtra: some View {
        NativeSettingsGroup(title: "탭") {
            NativeSettingsToggle(title: "새 탭을 현재 탭 옆에서 열기", isOn: boolean("openAdjacentTab", fallback: false)).accessibilityIdentifier("native-settings-adjacent-tabs")
        }
    }
    private var tabPanel: some View {
        VStack(alignment: .leading, spacing: 28) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach([("note", "마크다운"), ("recording", "녹음"), ("whiteboard", "노트"), ("board", "학업 보드")].filter { NativeReleaseFlags.showsRecording || $0.0 != "recording" }, id: \.0) { id, title in
                        Button(title) { tab = id }.buttonStyle(NativeToolButtonStyle(primary: tab == id, compact: true)).accessibilityIdentifier("native-settings-tab-" + id)
                    }
                }
            }
            switch tab {
            case "note":
                NativeSettingsGroup(title: "새 마크다운") {
                    // Applies when the field loses focus or on Enter; no save button.
                    LabeledContent("제목 접두사") {
                        TextField("새 마크다운", text: $titlePrefix).multilineTextAlignment(.trailing).frame(maxWidth: 220)
                            .onSubmit { savePrefix() }.onChange(of: prefixFocused) { _, focused in if !focused { savePrefix() } }.focused($prefixFocused)
                            .accessibilityIdentifier("native-settings-markdown-prefix")
                    }
                }
            case "recording": recording
            case "whiteboard": NativeSettingsGroup(title: "노트", description: "새로 만드는 노트의 배경을 선택합니다.") {
                Picker("기본 배경", selection: string("whiteboardBackground", group: "tabs", fallback: "grid")) {
                    Text("격자").tag("grid"); Text("점").tag("dots"); Text("줄").tag("lines"); Text("빈 배경").tag("blank")
                }.accessibilityIdentifier("native-settings-whiteboard-background")
            }
            default: NativeSettingsGroup(title: "학업 보드", description: "새로 여는 보드의 기본 화면을 선택합니다.") {
                Picker("기본 보기", selection: string("boardDefaultView", group: "tabs", fallback: "calendar")) { Text("달력").tag("calendar"); Text("목록").tag("board") }
                Toggle("완료된 일정 숨기기", isOn: boolean("boardHideDone", group: "tabs", fallback: false))
            }
            }
        }
    }
    private var recording: some View {
        NativeSettingsGroup(title: "녹음") {
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
        VStack(spacing: 28) {
            NativeSettingsGroup(title: "오른쪽 위젯") {
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

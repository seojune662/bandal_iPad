import SwiftUI

/// settings.json remains the portable preference. AppStorage is only the
/// synchronous rendering cache used by the native scene.
@MainActor
enum NativeAppearancePreference {
  static func normalize(_ value: Any?) -> String {
    switch value as? String {
    case "light", "sepia", "high-contrast": return "light"
    case "dark", "midnight", "graphite": return "dark"
    default: return "system"
    }
  }

  static func apply(_ settings: [String: Any], defaults: UserDefaults = .standard) {
    if settings["theme"] != nil {
      let preference = normalize(settings["theme"])
      if defaults.string(forKey: "native.appearance") != preference {
        defaults.set(preference, forKey: "native.appearance")
      }
    }
    if let scale = settings["fontScale"] as? NSNumber {
      defaults.set([0.9, 1, 1.1, 1.2].contains(scale.doubleValue) ? scale.doubleValue : 1, forKey: "native.fontScale")
    }
    if let font = settings["editorFont"] as? String { defaults.set(["sans", "serif", "mono"].contains(font) ? font : "sans", forKey: "native.editorFont") }
    if let density = settings["density"] as? String { defaults.set(density == "compact" ? "compact" : "comfortable", forKey: "native.density") }
    if settings["locale"] != nil { defaults.set(NativeAppLocale.normalize(settings["locale"]), forKey: NativeAppLocale.key) }
    defaults.set(settings["openAdjacentTab"] as? Bool ?? false, forKey: "native.openAdjacentTab")
    defaults.set(settings["restoreLastCourse"] as? Bool ?? true, forKey: "native.restoreLastCourse")
  }

  static func save(
    _ preference: String,
    invoke: @MainActor (String, [String: Any]) async throws -> Any,
    defaults: UserDefaults = .standard
  ) async throws -> [String: Any] {
    guard let saved = try await invoke("settings:set", ["theme": normalize(preference)]) as? [String: Any],
      saved["theme"] != nil
    else { throw DesktopRuntimeError("화면 모드의 저장 결과를 확인하지 못했습니다.") }
    apply(saved, defaults: defaults)
    return saved
  }
}

/// The settings sheet (Figma 132:2769…132:4097): the section list on the left, one page on the right.
/// What the design leaves out of a page stays one row away, on the page its 더 보기 row pushes.
struct NativeSettingsWorkspace: View {
  var store: NativeWorkspaceStore
  let initialCategory: String
  var close: () -> Void = {}
  @AppStorage("native.appearance") private var appearance = "system"
  @AppStorage("native.fontScale") private var fontScale = 1.0
  @AppStorage("native.density") private var density = "comfortable"
  @AppStorage(NativeLocalPreferences.homeTogglesSidebar) private var homeTogglesSidebar = true
  @AppStorage(NativeLocalPreferences.keyboardFoldsPanels) private var keyboardFoldsPanels = true
  private var pencilTapTitle: String {
    switch UIPencilInteraction.preferredTapAction {
    case .switchEraser: "지우개로 바꾸기"
    case .switchPrevious: "이전 도구로 바꾸기"
    case .showColorPalette, .showInkAttributes: "색 · 굵기 보기"
    case .ignore: "끔"
    default: "시스템 설정 따름"
    }
  }
  @State private var settings: [String: Any] = [:]
  @State private var account: [String: Any] = [:]
  @State private var sync: [String: Any] = [:]
  @State private var conflicts: [[String: Any]] = []
  @State private var billing: [String: Any] = [:]
  @State private var deleteAccountConfirmation = false
  @State private var newProfileConfirmation = false
  @State private var nickname = ""
  @State private var nicknameDraft = ""
  @State private var editingName = false
  @State private var loading = false
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  @State private var consentRevision = 0
  @State private var signOutConfirmation = false
  @State private var pendingRestore: ConflictChoice?
  private struct ConflictChoice {
    let id: String
    let variant: String
  }
  private var signedIn: Bool { account["phase"] as? String == "signed-in" }
  @State private var category: String
  /// The page pushed inside the sheet: "more" (what the design leaves out of this section) or "university".
  @State private var subpage: String?
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  private var locale: String { settings["locale"] as? String ?? "ko-KR" }
  private var english: Bool { locale == "en-US" }
  private var categories: [NativeSettingsCategory] { NativeSettingsCatalog.localized(locale) }
  private var activeCategory: NativeSettingsCategory { categories.first { $0.id == category } ?? categories[0] }
  private var matchingCategories: [NativeSettingsCategory] { NativeSettingsCatalog.matching(query, locale: locale) }
  private var schoolName: String? { NativeUniversityCatalog.university(settings)?["nameKo"] as? String }
  private static let navFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.05) : UIColor.black.withAlphaComponent(0.04) })
  init(store: NativeWorkspaceStore, initialCategory: String = "general", close: @escaping () -> Void = {}) {
    self.store = store
    self.initialCategory = initialCategory
    self.close = close
    _category = State(initialValue: NativeSettingsCatalog.resolve(initialCategory))
    _subpage = State(initialValue: NativeSettingsCatalog.subpage(initialCategory))
  }
  var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 620
      HStack(spacing: 0) {
        if wide { sidebar.frame(width: 250).disabled(loading || busy) }
        VStack(spacing: 0) {
          header(wide: wide).padding(.top, 24).padding(.horizontal, wide ? 32 : 20)
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 28) {
                if let error { NativeToolError(message: error) }
                if let notice { Label(notice, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(NativeSettingsRowMetrics.green) }
                page
              }.padding(.top, 28).padding(.bottom, 24).padding(.horizontal, wide ? 32 : 20).frame(maxWidth: .infinity, alignment: .topLeading).id("top")
            }
            .onChange(of: subpage) { _, _ in proxy.scrollTo("top", anchor: .top) }
            .onChange(of: category) { _, _ in proxy.scrollTo("top", anchor: .top) }
          }.disabled(loading || busy).refreshable { await load() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.foregroundStyle(NativeDesktopTheme.text).font(.system(size: 16))
    .overlay {
      if loading || busy {
        ProgressView().padding().background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .task { await load() }
    .task(id: signedIn) {
      aiModel = NativeAIPreferences.model; aiEffort = NativeAIPreferences.effort
      if signedIn, let config = try? await store.invokePrivate("native:aiConfig") as? [String: Any] { aiCatalog = NativeAIModelCatalog(config) }
      else { aiCatalog = NativeAIModelCatalog() }
    }
    .onChange(of: initialCategory) { _, value in open(value); searchFocused = false }
    .onReceive(store.events) { event in
      if event.channel == "nativeSettings:select", let value = (event.payload as? [String: Any])?["category"] as? String { open(value) }
      if event.channel == "auth:changed", let state = event.payload as? [String: Any] {
        account = state
        setNicknameFromAccount()
      }
      if event.channel == "runtime:syncChanged", let state = event.payload as? [String: Any] {
        sync = state
        Task { do { try await loadSync() } catch { self.error = error.localizedDescription } }
      }
      if event.channel == "billing:changed", let state = event.payload as? [String: Any] { billing = state }
      if event.channel == "settings:changed", let state = event.payload as? [String: Any] {
        settings = state["settings"] as? [String: Any] ?? state
        NativeAppearancePreference.apply(settings)
      }
    }
    .confirmationDialog("새 프로필을 만들까요? 현재 자료는 백업한 위치와 기존 폴더에 그대로 남고, 앱은 빈 프로필로 다시 시작합니다.", isPresented: $newProfileConfirmation, titleVisibility: .visible) {
      Button("새 프로필 시작") { run { _ = try await store.invoke("profile:new") } }
    }
    .confirmationDialog(
      "선택한 충돌 사본을 적용할까요?",
      isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    ) {
      Button("사본 적용") {
        guard let choice = pendingRestore else { return }
        pendingRestore = nil
        run {
          _ = try await store.invoke(
            "sync:restoreConflict", ["id": choice.id, "variant": choice.variant])
          try await loadSync()
          await store.refreshMaterials()
        }
      }
    }
  }
  /// A section id, or the id of a page that used to be one (deep links): its section and the page inside it.
  private func open(_ id: String) { category = NativeSettingsCatalog.resolve(id); subpage = NativeSettingsCatalog.subpage(id); query = "" }
  private func circleButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 32, height: 32)
        .background(NativeDesktopTheme.surface, in: Circle()).padding(6).contentShape(Rectangle()).padding(-6)
    }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(identifier)
  }
  /// The content's first row: the page title (24 Bold) and the close circle; a pushed page adds the way back.
  private func header(wide: Bool) -> some View {
    HStack(spacing: 12) {
      if subpage != nil { circleButton("chevron.left", label: "뒤로", identifier: "native-settings-back") { subpage = nil } }
      let title = Text(verbatim: subpage == "university" ? (english ? "School & shortcuts" : "학교와 바로가기") : subpage == "more" ? activeCategory.title + " · " + (english ? "More" : "더 보기") : activeCategory.title)
        .font(.system(size: 24, weight: .bold)).lineLimit(1)
      if wide { title.accessibilityAddTraits(.isHeader) } else {
        Menu { ForEach(categories) { item in Button(item.title) { category = item.id; subpage = nil } } } label: { HStack(spacing: 6) { title; Image(systemName: "chevron.down").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted) } }
          .foregroundStyle(NativeDesktopTheme.text)
      }
      Spacer(minLength: 8)
      circleButton("xmark", label: "설정 닫기", identifier: "native-settings-close", action: close)
    }.frame(height: 32)
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(english ? "Settings" : "설정").font(.system(size: 22, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 4).accessibilityAddTraits(.isHeader)
      Color.clear.frame(height: 10)
      ForEach(categories) { item in
        let on = category == item.id
        Button { category = item.id; subpage = nil } label: {
          HStack(spacing: 12) {
            Image(systemName: item.icon).font(.system(size: 16)).foregroundStyle(on ? NativeDesktopTheme.accent : NativeDesktopTheme.secondary).frame(width: 22, height: 22)
            Text(item.title).font(.system(size: 16, weight: on ? .semibold : .regular)).foregroundStyle(on ? NativeDesktopTheme.accent : NativeDesktopTheme.text)
              .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
          }.padding(.horizontal, 12).frame(height: 42)
            .background(on ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("native-settings-category-" + item.id)
          .accessibilityAddTraits(on ? .isSelected : [])
      }
    }.padding(.vertical, 20).padding(.horizontal, 12).frame(maxHeight: .infinity, alignment: .top).background { Rectangle().fill(Self.navFill) }
  }
  private var moreRow: some View { NativeSettingsMoreRow { subpage = "more" } }
  @ViewBuilder private var page: some View {
    let more = subpage == "more"
    if subpage == "university" { expandedPanel("university") } else {
      switch category {
      case "ai": if more { aiMore } else { aiPage; moreRow }
      case "account": if more { accountMore } else { accountPage; moreRow }
      // One view for the page and its 더 보기: a connection begun on one is finished on the other.
      case "sync": NativeSettingsSyncPanel(store: store, detail: more) { subpage = "more" }
      case "subscription": NativeSettingsSubscriptionPanel(store: store, detail: more) { subpage = "more" }
      case "integrations": if more { expandedPanel("calendar"); expandedPanel("browser") } else { integrationsPage; moreRow }
      case "appearance": if more { fontsGroup; expandedPanel("tabs"); expandedPanel("widgets") } else { appearancePage; moreRow }
      default:
        if more { searchGroup; expandedPanel("general-extra"); expandedPanel("notifications"); expandedPanel("shortcuts"); expandedPanel("advanced"); versionGroup }
        else { expandedPanel("general"); moreRow }
      }
    }
  }
  /// 일반 › 더 보기: the search the section list used to carry. A hit opens its section.
  private var searchGroup: some View {
    NativeSettingsGroup(title: "설정 검색") {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary)
        TextField(english ? "Search settings" : "설정 검색", text: $query).textFieldStyle(.plain).accessibilityIdentifier(
          "native-settings-search").focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 28, height: 35).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.muted).accessibilityLabel("검색 지우기").accessibilityIdentifier("native-settings-clear-search") }
      }
      if !query.isEmpty {
        ForEach(matchingCategories) { item in
          Button { searchFocused = false; open(item.id) } label: { NativeSettingsRow(title: item.title, note: item.description) { NativeSettingsValue() } }
            .buttonStyle(.plain).accessibilityIdentifier("native-settings-search-result-" + item.id)
        }
        if matchingCategories.isEmpty { Text(english ? "No results found." : "검색 결과가 없습니다.").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted) }
      }
    }
  }
  /// 일반 › 더 보기, last: the version the section list used to show at its foot.
  private var versionGroup: some View {
    NativeSettingsGroup(title: "정보") {
      NativeSettingsRow(title: "버전") {
        Text(verbatim: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
          .font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityIdentifier("native-settings-version")
      }
    }
  }
  /// 통합 (132:4097): 학교 사이트, the sidebar's AI sites and the services this iPad can connect to.
  @ViewBuilder private var integrationsPage: some View {
    let services = NativeUniversityCatalog.resolvedServices(settings: settings)
    let rest = services.count - 3
    let shortcuts = services.isEmpty ? NativeAppLocale.string("학교를 고르면 바로가기가 보여요", Locale(identifier: locale))
      : services.prefix(3).map(\.label).joined(separator: " · ") + (rest > 0 ? String(format: NativeAppLocale.string(" 외 %lld개", Locale(identifier: locale)), rest) : "")
    NativeSettingsGroup(title: "학교 사이트") {
      Button { subpage = "university" } label: { NativeSettingsRow(title: "학교") { NativeSettingsValue(schoolName ?? "고르기") } }
        .buttonStyle(.plain).accessibilityIdentifier("native-settings-integrations-school")
      Button { subpage = "university" } label: { NativeSettingsRow(title: "바로가기", note: shortcuts) { NativeSettingsValue("편집") } }
        .buttonStyle(.plain).accessibilityIdentifier("native-settings-integrations-shortcuts")
    }
    // 준비 중: the list of AI sites is fixed, and none of the three services has a connection yet.
    NativeSettingsGroup(title: "외부 AI 사이트") {
      NativeSettingsRow(title: "사이드바에 보이기", note: NativeAIWebShortcut.all.map(\.title).joined(separator: " · ")) { NativeSettingsValue("편집") }
        .accessibilityElement(children: .combine).accessibilityHint("준비 중")
    }
    NativeSettingsGroup(title: "연결된 서비스", description: "Google 캘린더 · Drive · Notion 연결은 준비 중이에요. Apple 캘린더는 더 보기에서 연결해요.") {
      ForEach([("Google 캘린더", "과제 마감 기한을 가져와요"), ("Google Drive", "자료로 가져오기"), ("Notion", "페이지를 자료로 가져오기")], id: \.0) { title, note in
        NativeSettingsRow(title: title, note: note) { Button("연결") {}.disabled(true).accessibilityLabel(title + " 연결").accessibilityHint("준비 중") }
      }
    }
  }
  private func expandedPanel(_ id: String) -> some View {
    NativeSettingsSections(section: id, store: store, settings: settings, save: { patch in
      guard let value = try await store.invoke("settings:set", patch) as? [String: Any] else {
        throw DesktopRuntimeError("설정 저장 결과를 확인하지 못했습니다.")
      }
      settings = value; NativeAppearancePreference.apply(value)
    }, navigate: { id in if id == "university" { subpage = "university" } else { open(id) } })
  }

  private static let fontScales = [0.9, 1, 1.1, 1.2]
  /// 글자 크기 as the design draws it: 가 13, a 180 × 6 bar, 가 19. Four steps; a touch or drag picks the nearest.
  private var fontScaleBar: some View {
    let index = Self.fontScales.firstIndex(of: fontScale) ?? 1
    let pick = { (step: Int) in let value = Self.fontScales[min(3, max(0, step))]; if value != fontScale { savePreference(["fontScale": value]) } }
    return HStack(spacing: 10) {
      Text("가").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityHidden(true)
      Capsule().fill(NativeDesktopTheme.surface).frame(width: 180, height: 6)
        .overlay(alignment: .leading) { Capsule().fill(NativeDesktopTheme.accent).frame(width: 45 * CGFloat(index + 1)) }
        .padding(.vertical, 19).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { pick(Int($0.location.x / 45)) })
        .padding(.vertical, -19)
        .accessibilityElement().accessibilityLabel("글자 크기").accessibilityValue("\(Int(fontScale * 100))%")
        .accessibilityAdjustableAction { pick(index + ($0 == .increment ? 1 : -1)) }.accessibilityIdentifier("native-settings-font-scale")
      Text("가").font(.system(size: 19)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityHidden(true)
    }
  }
  /// 화면 (132:2998): 테마, 사이드바, 펜슬.
  @ViewBuilder private var appearancePage: some View {
    NativeSettingsGroup(title: "테마") {
      NativeSettingsRow(title: "모양", height: 61) {
        BandalSegmented(options: [("light", "라이트"), ("dark", "다크"), ("system", "시스템")],
                        selection: Binding(get: { appearance }, set: { saveAppearance($0) }), identifierPrefix: "native-settings-theme-")
      }
      NativeSettingsRow(title: "글자 크기", height: 51) { fontScaleBar }
    }
    NativeSettingsGroup(title: "사이드바") {
      NativeSettingsToggle(title: "홈 버튼으로 접고 펼치기", isOn: $homeTogglesSidebar).accessibilityIdentifier("native-settings-home-toggles-sidebar")
      NativeSettingsToggle(title: "키보드를 쓰면 자동으로 접기", note: "마크다운에서 키보드가 올라올 때", isOn: $keyboardFoldsPanels).accessibilityIdentifier("native-settings-keyboard-folds-panels")
    }
    // 준비 중: finger drawing is a per-note tool option, with no app-wide default to switch here.
    NativeSettingsGroup(title: "펜슬", description: "‘손가락은 스크롤만’을 끄는 설정은 준비 중이에요.") {
      NativeSettingsToggle(title: "손가락은 스크롤만", note: "필기는 펜슬로만 해요", isOn: .constant(true)).disabled(true).accessibilityIdentifier("native-settings-finger-scrolls")
      // The double tap is the system's setting: the row shows it and opens Settings.
      Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
        NativeSettingsRow(title: "펜슬 두 번 탭") { NativeSettingsValue(pencilTapTitle) }
      }.buttonStyle(.plain).accessibilityIdentifier("native-settings-pencil-tap")
    }
  }
  /// 화면 › 더 보기.
  private var fontsGroup: some View {
    NativeSettingsGroup(title: "글꼴과 밀도") {
      LabeledContent("필기 글꼴") {
        Picker("필기 글꼴", selection: Binding(get: { settings["editorFont"] as? String ?? "sans" }, set: { savePreference(["editorFont": $0]) })) {
          Text("산세리프").tag("sans"); Text("세리프").tag("serif"); Text("고정폭").tag("mono")
        }.accessibilityIdentifier("native-settings-editor-font")
      }
      NativeSettingsRow(title: "밀도", height: 61) {
        BandalSegmented(options: [("comfortable", "편안하게"), ("compact", "촘촘하게")], selection: Binding(get: { density }, set: { savePreference(["density": $0]) }), identifierPrefix: "native-settings-density-")
      }
    }
  }
  @State private var aiCatalog = NativeAIModelCatalog()
  @State private var aiModel = NativeAIPreferences.model
  @State private var aiEffort = NativeAIPreferences.effort
  @State private var aiSignIn = false
  @State private var pickingModel = false
  @State private var pickingLanguage = false
  @AppStorage(NativeAIPreferences.answerLanguageKey) private var answerLanguage = "auto"
  @AppStorage(NativeAIPreferences.referenceScopeKey) private var referenceScope = "course"
  @AppStorage(NativeAIPreferences.showsSourcesKey) private var showsSources = true
  @AppStorage(NativeAIPreferences.savesHistoryKey) private var savesHistory = true
  @State private var deleteChatsConfirmation = false
  @State private var aiSignInError: String?
  private static let answerLanguages = [("auto", "질문 따라"), ("ko", "한국어"), ("en", "English")]
  /// AI (132:3654): 모델, 자료 참고, 대화 기록. Signed out, the model row asks to sign in instead.
  @ViewBuilder private var aiPage: some View {
    NativeSettingsGroup(title: "모델", description: "AI는 반달이 제공해요. 따로 API 키를 넣지 않아도 돼요.") {
      // Not one button: the note stays a text of its own for VoiceOver and the tests.
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("기본 모델")
          Text(signedIn ? "질문에 맞춰 알아서 골라요" : "로그인하면 바로 쓸 수 있어요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityIdentifier("native-ai-summary")
        }
        Spacer(minLength: 8)
        Button { if signedIn { pickingModel = true } else { aiSignIn = true } } label: {
          NativeSettingsValue(signedIn ? (aiModel == "default" ? "자동 (추천)" : aiCatalog.label(aiModel)) : "로그인").frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(signedIn ? "native-settings-ai-model" : "native-ai-settings-sign-in")
          .bandalPopover(isPresented: $aiSignIn, width: 260) { NativeSignInButtons(store: store, error: $aiSignInError, identifierPrefix: "native-ai-settings") }
          .background(Color.clear.bandalPopover(isPresented: $pickingModel, width: 320, radius: 14, padding: 8) {
            NativeAIModelPicker(catalog: aiCatalog, model: aiModel, effort: aiModel == "default" ? nil : aiEffort,
                                onSelect: { model, effort, closes in NativeAIPreferences.remember(model: model, effort: effort); aiModel = model; aiEffort = effort ?? aiEffort; if closes { pickingModel = false } })
              .accessibilityIdentifier("native-settings-ai-picker")
          })
      }.frame(minHeight: 45)
      Button { pickingLanguage = true } label: {
        NativeSettingsRow(title: "답변 언어") { NativeSettingsValue(Self.answerLanguages.first { $0.0 == answerLanguage }?.1 ?? "질문 따라") }
      }.buttonStyle(.plain).accessibilityIdentifier("native-settings-ai-language")
        .bandalPopover(isPresented: $pickingLanguage, width: 220, radius: 16, padding: 8) {
          VStack(spacing: 0) {
            ForEach(Self.answerLanguages, id: \.0) { id, title in
              BandalMenuRow(title, checked: answerLanguage == id) { answerLanguage = id; pickingLanguage = false }.accessibilityIdentifier("native-settings-ai-language-" + id)
            }
          }
        }
    }
    NativeSettingsGroup(title: "자료 참고") {
      NativeSettingsRow(title: "참고 범위", height: 61) {
        BandalSegmented(options: [("note", "지금 노트"), ("course", "과목 전체")], selection: $referenceScope, identifierPrefix: "native-settings-ai-scope-")
      }
      NativeSettingsToggle(title: "AI 답변 출처 표시", isOn: $showsSources).accessibilityIdentifier("native-settings-ai-sources")
    }
    NativeSettingsGroup(title: "대화 기록", description: savesHistory ? "" : "지금부터 시작하는 대화는 목록에 남지 않고, 앱을 다시 열면 지워져요") {
      NativeSettingsToggle(title: "대화 기록 저장", isOn: $savesHistory).accessibilityIdentifier("native-settings-ai-saves-history")
      NativeSettingsActionRow(title: "대화 기록 모두 지우기", destructive: true) { deleteChatsConfirmation = true }.accessibilityIdentifier("native-settings-delete-chats")
        .bandalConfirm("대화 기록을 모두 지울까요?", isPresented: $deleteChatsConfirmation, message: "모든 과목의 AI 대화가 지워져요. 노트와 자료는 그대로예요.", action: "모두 지우기", destructive: true, identifier: "native-settings-delete-chats-confirm") {
          run { _ = try await store.invoke("chat:deleteAll"); notice = "대화 기록을 지웠어요." }
        }
    }
  }
  /// AI › 더 보기: consent per provider and the fair-use page.
  private var aiMore: some View {
    NativeSettingsGroup(title: "전송 동의") {
      ForEach(NativeAIProvider.allCases.filter { $0 != .google || aiCatalog.providers.contains("google") }) { provider in consentRow(provider) }
      Link(destination: URL(string: "https://bandal.io/ko/docs/ai-fair-use")!) { NativeSettingsRow(title: "공정 이용 안내") { Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted) } }
        .buttonStyle(.plain).accessibilityIdentifier("native-ai-fair-use")
    }
  }
  private var loginMethod: String? {
    // The sign-in buttons carry these Korean labels in both languages; here English names the provider.
    switch account["provider"] as? String { case "apple": english ? "Apple" : "Apple로 로그인"; case "google": english ? "Google" : "Google로 로그인"; case "email": english ? "Email" : "이메일로 로그인"; default: nil }
  }
  /// 계정 (132:3229): the profile card, 계정 정보, then 로그아웃 and 계정 삭제. Signed out it offers the sign-in buttons.
  @ViewBuilder private var accountPage: some View {
    if signedIn {
      let email = account["email"] as? String
      HStack(spacing: 16) {
        Text(String((nickname.isEmpty ? (email ?? "반") : nickname).prefix(1))).font(.system(size: 20, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
          .frame(width: 56, height: 56).background(NativeDesktopTheme.border, in: Circle()).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(nickname.isEmpty ? "이름 없음" : nickname).font(.system(size: 20, weight: .semibold))
          if let email { Text(email).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary) }
        }
        Spacer(minLength: 0)
      }.padding(21).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border))
      if account["errorCode"] as? String == "reauthentication-required" {
        NativeSettingsGroup(description: "안전을 위해 다시 로그인해 주세요. 기기의 자료는 계속 사용할 수 있어요.") {
          NativeSettingsActionRow(title: "Apple로 다시 로그인") { signIn("apple") }
          NativeSettingsActionRow(title: "Google로 다시 로그인") { signIn("google") }
        }
      }
      NativeSettingsGroup(title: "계정 정보") {
        Button { nicknameDraft = nickname; editingName = true } label: { NativeSettingsRow(title: "이름") { NativeSettingsValue(nickname) } }
          .buttonStyle(.plain).accessibilityIdentifier("native-settings-nickname-row")
          .bandalPopover(isPresented: $editingName, width: 280) {
            // Saved on Enter, no save button.
            BandalField(prompt: "닉네임", text: $nicknameDraft, identifier: "native-settings-nickname") { editingName = false; saveNickname() }
          }
        if let email { NativeSettingsRow(title: "이메일") { NativeSettingsValue(email, chevron: false) } }
        if let loginMethod { NativeSettingsRow(title: "로그인 방식") { NativeSettingsValue(loginMethod, chevron: false) } }
      }
      NativeSettingsGroup {
        NativeSettingsActionRow(title: "로그아웃") { signOutConfirmation = true }.accessibilityIdentifier("native-settings-sign-out")
          .bandalConfirm("로그아웃할까요?", isPresented: $signOutConfirmation, action: "로그아웃") {
            run { _ = try await store.invoke("auth:signOut"); try await loadAccount(); try await loadSync() }
          }
        NativeSettingsActionRow(title: "계정 삭제", note: "서버의 계정 정보가 지워져요. 이 iPad의 자료는 남아요.", destructive: true) { deleteAccountConfirmation = true }
          .accessibilityIdentifier("native-settings-delete-account")
          .bandalConfirm("계정을 삭제할까요?", isPresented: $deleteAccountConfirmation, message: "서버의 계정 정보가 지워져요. 이 iPad의 자료는 남아요.", action: "계정 삭제", destructive: true, identifier: "native-settings-delete-account-confirm") {
            run { _ = try await store.invoke("auth:deleteAccount"); try await loadAccount(); try await loadSync(); notice = "계정을 삭제했어요." }
          }
      }
    } else {
      NativeSettingsGroup(title: "반달 계정") {
        VStack(alignment: .leading, spacing: 12) {
          Text(accountPhase).font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary)
          NativeSignInButtons(store: store, error: $error, identifierPrefix: "native-settings").frame(maxWidth: 280)
        }.padding(.vertical, 8)
      }
    }
  }
  /// 계정 › 더 보기: 친구 초대, linking another sign-in, and the cloud-sync panels of the older builds.
  @ViewBuilder private var accountMore: some View {
    NativeReferralSettingsCard(store: store)
    if signedIn {
      NativeSettingsGroup(title: "다른 로그인 방법 연결") {
        NativeSettingsActionRow(title: "Apple 연결") { linkProvider("apple") }
        NativeSettingsActionRow(title: "Google 연결") { linkProvider("google") }
      }
    }
    if NativeReleaseFlags.legacyCloudSync { subscriptionPanel; syncPanel; profilePanel }
  }
  private func consentRow(_ provider: NativeAIProvider) -> some View {
    let target: AIProvider = switch provider { case .openAI: .openai; case .anthropic: .claude; case .google: .gemini }
    let english = locale == "en-US"
    let granted = consentRevision >= 0 && AIConsent.anyGranted(target)
    return HStack {
      Text(granted
        ? (english ? "Consent to send to \(AIConsent.company(target)) given" : "\(AIConsent.company(target)) 전송에 동의함")
        : (english ? "\(AIConsent.company(target)): consent will be asked before the first send" : "\(AIConsent.company(target)): 처음 보낼 때 동의를 묻습니다"))
        .font(.system(size: BandalMetrics.bodySize)).foregroundStyle(NativeDesktopTheme.secondary)
      Spacer()
      if granted {
        Button(english ? "Withdraw consent" : "동의 철회", role: .destructive) {
          AIConsent.revokeAll(target); consentRevision += 1
        }.accessibilityIdentifier("native-ai-consent-revoke-\(provider.rawValue)")
      }
    }
  }
  private func saveNickname() {
    guard !nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    run { _ = try await store.invoke("auth:setNickname", ["nickname": nicknameDraft]); try await loadAccount(); notice = "이름을 바꿨어요." }
  }
  private var subscriptionPanel: some View {
    NativeSettingsGroup(title: "동기화 구독") {
      if !signedIn {
        Text("로그인하면 구독 상태를 확인할 수 있어요.").foregroundStyle(.secondary)
      } else {
        let subscription = billing["subscription"] as? [String: Any] ?? [:]
        LabeledContent("상태", value: subscription["active"] as? Bool == true ? "이용 중" : "구독 없음")
        if let provider = subscription["provider"] as? String, !provider.isEmpty { LabeledContent("결제 수단", value: provider) }
        if let until = subscription["currentPeriodEnd"] as? String ?? subscription["expiresAt"] as? String { LabeledContent("다음 갱신", value: String(until.prefix(10))) }
        let products = billing["products"] as? [[String: Any]] ?? []
        if subscription["active"] as? Bool != true {
          ForEach(Array(products.enumerated()), id: \.offset) { _, product in
            Button("\(product["displayName"] as? String ?? "구독") · \(product["displayPrice"] as? String ?? "")") {
              run {
                let result = try await store.invoke("billing:purchase", ["plan": product["plan"] as? String ?? "monthly"]) as? [String: Any]
                notice = result?["status"] as? String == "purchased" ? "구독을 시작했어요." : "구매를 완료하지 않았어요."
                try await loadSync()
              }
            }
          }
          if products.isEmpty { Text("App Store 구독 상품을 아직 사용할 수 없어요. 데스크톱 구독도 이 계정에 적용됩니다.").font(.caption).foregroundStyle(.secondary) }
        }
        Button("구매 복원") { run { _ = try await store.invoke("billing:restore"); try await loadSync(); notice = "구매를 확인했어요." } }
        Button("구독 관리") { run { _ = try await store.invoke("billing:manageApple") } }
        Text("구독은 Apple·데스크톱 결제 중 하나면 충분하며 같은 반달 계정에 적용됩니다. 구독이 없어도 기기의 자료와 기존 동기화 자료 다운로드는 계속 사용할 수 있어요.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var profilePanel: some View {
    NativeSettingsGroup(title: "기기 프로필") {
      LabeledContent("프로필", value: store.root.lastPathComponent)
      Button("현재 자료 백업", systemImage: "externaldrive") {
        run {
          let result = try await store.invoke("profile:backup") as? [String: Any]
          notice = result?["ok"] as? Bool == true ? "백업을 저장했어요." : "백업을 취소했어요."
        }
      }
      Button("새 프로필로 시작", systemImage: "person.badge.plus") { newProfileConfirmation = true }
      Text("다른 계정으로 쓰려면 먼저 현재 자료를 백업한 뒤 새 프로필을 만드세요. 기존 프로필 폴더는 지우지 않습니다.").font(.caption).foregroundStyle(.secondary)
    }
  }
  private var syncPanel: some View {
    NativeSettingsGroup(title: "자료 동기화") {
      Toggle("자료 동기화 사용", isOn: Binding(get: { sync["enabled"] as? Bool == true }, set: { value in
        run { sync = try await store.invoke("sync:setEnabled", ["enabled": value]) as? [String: Any] ?? sync; try await loadSync() }
      })).disabled(!signedIn)
      LabeledContent("상태", value: syncPhase)
      if let pending = (sync["pending"] as? NSNumber)?.intValue {
        LabeledContent("대기 중인 변경", value: String(pending))
      }
      if let used = (sync["storageUsedBytes"] as? NSNumber)?.int64Value, let limit = (sync["storageLimitBytes"] as? NSNumber)?.int64Value, limit > 0 {
        LabeledContent("저장 공간", value: ByteCountFormatter.string(fromByteCount: used, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))
      }
      if sync["writeAllowed"] as? Bool == false {
        Text(sync["blockedReason"] as? String == "storage_limit_exceeded" ? "동기화 저장 공간이 가득 찼어요. 기기의 변경은 보관되고 기존 자료 다운로드는 계속됩니다." : "동기화 구독이 필요해요. 기기의 변경은 보관되고 기존 자료 다운로드는 계속됩니다.").font(.caption).foregroundStyle(.orange)
      }
      if let message = sync["error"] as? String {
        Text(message).font(.caption).foregroundStyle(.red)
      }
      Button("지금 동기화", systemImage: "arrow.triangle.2.circlepath") {
        run {
          try await store.flushDocuments()
          _ = try await store.invoke("sync:run")
          try await loadSync()
          notice = "동기화를 마쳤어요."
        }
      }.disabled(!signedIn || sync["enabled"] as? Bool != true || sync["phase"] as? String == "syncing")
      ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
        DisclosureGroup("충돌 사본 · \(conflictTitle(conflict))") {
          Text("적용할 사본의 내용을 확인하세요. 선택하지 않은 사본도 복구 기록에 보관됩니다.").font(.caption).foregroundStyle(
            .secondary)
          ForEach(["local", "remote"], id: \.self) { variant in
            DisclosureGroup(variant == "local" ? "이 기기의 내용" : "서버의 내용") {
              Text(Self.variantDescription((conflict["variants"] as? [String: Any])?[variant] as? [String: Any])).font(.caption).textSelection(.enabled)
              Button(variant == "local" ? "이 기기의 사본 적용" : "서버 사본 적용") {
                if let id = conflict["id"] as? String {
                  pendingRestore = ConflictChoice(id: id, variant: variant)
                }
              }
            }
          }
        }
      }
    }
  }
  private var accountPhase: String {
    switch account["phase"] as? String {
    case "unconfigured": "계정 서버 설정이 필요합니다."
    case "signing-in": "로그인하는 중…"
    case "error": "로그인을 완료하지 못했습니다. 다시 시도하세요."
    default: NativeReleaseFlags.legacyCloudSync ? "로그인하면 다른 기기와 자료를 동기화할 수 있어요." : "로그인은 선택 사항이에요. 계정 프로필을 쓰고 싶을 때만 로그인하세요."
    }
  }
  private var syncPhase: String {
    switch sync["phase"] as? String {
    case "syncing": "동기화 중"
    case "waiting": "재시도 대기"
    default: signedIn ? "준비됨" : "로그인 필요"
    }
  }
  private func load() async {
    guard !loading else { return }
    loading = true
    defer { loading = false }
    error = nil
    do {
      settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
      NativeAppearancePreference.apply(settings)
      try await loadAccount()
      try await loadSync()
    } catch { self.error = error.localizedDescription }
  }
  private func loadAccount() async throws {
    account = try await store.invoke("auth:getState") as? [String: Any] ?? [:]
    #if DEBUG
    // A signed-in account for the design screenshots.
    if ProcessInfo.processInfo.arguments.contains("--native-settings-account-fixture") { account = ["phase": "signed-in", "email": "banddal@snu.ac.kr", "provider": "apple", "profile": ["nickname": "김반달"]] }
    #endif
    setNicknameFromAccount()
  }
  private func setNicknameFromAccount() {
    nickname = (account["profile"] as? [String: Any])?["nickname"] as? String ?? ""
  }
  private func loadSync() async throws {
    guard NativeReleaseFlags.legacyCloudSync else { return }
    sync = try await store.invoke("sync:status") as? [String: Any] ?? [:]
    conflicts = try await store.invoke("sync:conflicts") as? [[String: Any]] ?? []
    if signedIn { billing = (try? await store.invoke("billing:getState")) as? [String: Any] ?? billing }
  }
  static func variantDescription(_ summary: [String: Any]?) -> String {
    guard let summary, summary["exists"] as? Bool == true else { return "없음" }
    var lines: [String] = []
    if summary["deleted"] as? Bool == true { lines.append("삭제됨") }
    if let title = summary["title"] as? String { lines.append("제목: " + title) }
    if let page = summary["page"] as? NSNumber { lines.append("페이지: \(page.intValue)") }
    if let objects = summary["objects"] as? NSNumber { lines.append("필기·강조 개체: \(objects.intValue)개") }
    if let updated = summary["updatedAt"] as? String { lines.append("수정: " + String(updated.prefix(19)).replacingOccurrences(of: "T", with: " ")) }
    if let revision = summary["revision"] as? String { lines.append("버전: " + String(revision.prefix(12))) }
    if let text = summary["text"] as? String, !text.isEmpty { lines.append(text) }
    return lines.isEmpty ? "내용 요약이 없습니다." : lines.joined(separator: "\n")
  }
  private func linkProvider(_ provider: String) {
    run {
      let result = try await store.invoke("auth:linkProvider", ["provider": provider]) as? [String: Any]
      guard result?["ok"] as? Bool == true else { throw DesktopRuntimeError("로그인 방법을 연결하지 못했습니다. 다시 시도하세요.") }
      try await loadAccount()
      notice = "로그인 방법을 연결했어요."
    }
  }
  private func signIn(_ provider: String) {
    run {
      let result = try await store.invoke("auth:signIn", ["provider": provider]) as? [String: Any]
      guard result?["ok"] as? Bool == true else {
        throw DesktopRuntimeError("로그인을 시작하지 못했습니다. 서버 설정과 연결을 확인하세요.")
      }
      try await loadAccount()
    }
  }
  private func savePreference(_ patch: [String: Any]) {
    run {
      guard let value = try await store.invoke("settings:set", patch) as? [String: Any] else { throw DesktopRuntimeError("설정 저장 결과를 확인하지 못했습니다.") }
      settings = value; NativeAppearancePreference.apply(value)
    }
  }
  private func saveAppearance(_ value: String) {
    run {
      settings = try await NativeAppearancePreference.save(value) { channel, request in
        try await store.invoke(channel, request)
      }
    }
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    error = nil
    notice = nil
    Task {
      defer { busy = false }
      do { try await action() } catch { self.error = error.localizedDescription }
    }
  }
  private func conflictTitle(_ conflict: [String: Any]) -> String {
    let local = conflict["local"] as? [String: Any]
    let payload = local?["payload"] as? [String: Any]
    return payload?["title"] as? String ?? payload?["name"] as? String ?? local?["kind"] as? String
      ?? "자료"
  }
}

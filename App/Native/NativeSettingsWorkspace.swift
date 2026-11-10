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

struct NativeSettingsWorkspace: View {
  var store: NativeWorkspaceStore
  let initialCategory: String
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
  private var browserSettings: [String: Any] { settings["browser"] as? [String: Any] ?? [:] }
  @State private var category = "appearance"
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  private var locale: String { settings["locale"] as? String ?? "ko-KR" }
  private var categories: [NativeSettingsCategory] { NativeSettingsCatalog.localized(locale) }
  private var activeCategory: NativeSettingsCategory { categories.first { $0.id == category } ?? categories[0] }
  private var matchingCategories: [NativeSettingsCategory] { NativeSettingsCatalog.matching(query, locale: locale) }
  init(store: NativeWorkspaceStore, initialCategory: String = "appearance") {
    self.store = store
    self.initialCategory = NativeSettingsCatalog.resolve(initialCategory)
    _category = State(initialValue: self.initialCategory)
  }
  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        if geometry.size.width >= 620 { sidebar.frame(width: 232) }
        VStack(spacing: 0) {
          if geometry.size.width < 620 {
            HStack {
              Menu {
                ForEach(categories) { item in Button(item.title) { category = item.id } }
              } label: {
                Label(activeCategory.title, systemImage: "line.3.horizontal").font(
                  NativeDesktopTheme.font( 13))
              }
              Spacer()
            }.padding(16).background(NativeDesktopTheme.surface)
          }
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              VStack(alignment: .leading, spacing: 4) {
                Text(activeCategory.title).font(.system(size: 20, weight: .semibold))
                Text(activeCategory.description).font(NativeDesktopTheme.font( 13)).foregroundStyle(
                  NativeDesktopTheme.secondary)
              }.padding(.bottom, 8)
              if let error { NativeToolError(message: error) }
              if let notice {
                Label(notice, systemImage: "checkmark.circle").font(NativeDesktopTheme.font( 13))
                  .foregroundStyle(.green)
              }
              settingsPanel
            }.padding(geometry.size.width < 760 ? 24 : 48).frame(maxWidth: 960, alignment: .leading)
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.background(NativeDesktopTheme.bgApp).foregroundStyle(NativeDesktopTheme.text).font(
      NativeDesktopTheme.font( 13)
    )
    .disabled(loading || busy)
    .overlay {
      if loading || busy {
        ProgressView().padding().background(
          .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .task { await load() }
    .onChange(of: initialCategory) { _, value in
      category = NativeSettingsCatalog.resolve(value)
      query = ""
      searchFocused = false
    }
    .refreshable { await load() }
    .onReceive(store.events) { event in
      if event.channel == "nativeSettings:select", let value = (event.payload as? [String: Any])?["category"] as? String { category = NativeSettingsCatalog.resolve(value); query = "" }
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
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(locale == "en-US" ? "Settings" : "설정").font(NativeDesktopTheme.font( 18, weight: .medium)).padding(.horizontal, 8).padding(.top, 16)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(NativeDesktopTheme.muted)
        TextField(locale == "en-US" ? "Search settings" : "설정 검색", text: $query).textFieldStyle(.plain).accessibilityIdentifier(
          "native-settings-search").focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
        if !query.isEmpty { Button("검색 지우기", systemImage:"xmark.circle.fill") { query = "" }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.muted).accessibilityIdentifier("native-settings-clear-search") }
      }.font(NativeDesktopTheme.font( 13)).padding(.horizontal, 12).frame(height: 36).background(
        NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8))
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(NativeSettingsCatalog.groups, id: \.id) { group in
            let items = matchingCategories.filter { $0.group == group.id }
            if !items.isEmpty {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                  Button {
                    searchFocused = false; category = item.id
                  } label: {
                    HStack(spacing: 12) {
                      Image(systemName: item.icon).frame(width: 16)
                      Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(NativeDesktopTheme.font( 13, weight: .medium)).padding(.horizontal, 12).frame(
                      minHeight: 36
                    )
                    .foregroundStyle(
                      category == item.id ? NativeDesktopTheme.text : NativeDesktopTheme.secondary
                    )
                    .background(
                      category == item.id ? NativeDesktopTheme.accentMuted : .clear,
                      in: RoundedRectangle(cornerRadius: 6))
                  }.buttonStyle(.plain).accessibilityIdentifier(
                    "native-settings-category-" + item.id)
                  .accessibilityAddTraits(category == item.id ? .isSelected : [])
                }
              }
            }
          }
          if matchingCategories.isEmpty {
            Text(locale == "en-US" ? "No results found." : "검색 결과가 없습니다.").font(NativeDesktopTheme.font( 12)).foregroundStyle(NativeDesktopTheme.muted)
              .padding(12)
          }
        }
      }
      HStack(spacing: 8) {
        Image(systemName: "moon")
        Text("반달")
        Spacer()
        Text(
          (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
          .accessibilityIdentifier("native-settings-version")
      }
      .font(NativeDesktopTheme.font( 12)).foregroundStyle(NativeDesktopTheme.muted).padding(8).overlay(
        alignment: .top
      ) { NativeDesktopTheme.border.frame(height: 1) }
    }.padding(12).background(NativeDesktopTheme.surface).overlay(alignment: .trailing) {
      NativeDesktopTheme.border.frame(width: 1)
    }
  }
  @ViewBuilder private var settingsPanel: some View {
    // Seven sections; each stacks the panels that used to be separate pages.
    switch category {
    case "ai": aiPanel
    case "account": VStack(alignment: .leading, spacing: 20) { accountPanel; expandedPanel("university"); if NativeReleaseFlags.legacyCloudSync { subscriptionPanel; syncPanel; profilePanel } }
    case "sync": NativeSettingsSyncPanel(store: store)
    case "subscription": NativeSettingsSubscriptionPanel(store: store)
    case "integrations": VStack(alignment: .leading, spacing: 20) { expandedPanel("calendar"); expandedPanel("browser") }
    case "appearance": VStack(alignment: .leading, spacing: 20) { appearancePanel; expandedPanel("tabs"); expandedPanel("widgets") }
    default: VStack(alignment: .leading, spacing: 20) { expandedPanel("general"); expandedPanel("notifications"); expandedPanel("shortcuts"); expandedPanel("advanced") }
    }
  }
  private func expandedPanel(_ id: String) -> some View {
    NativeSettingsSections(section: id, store: store, settings: settings, save: { patch in
      guard let value = try await store.invoke("settings:set", patch) as? [String: Any] else {
        throw DesktopRuntimeError("설정 저장 결과를 확인하지 못했습니다.")
      }
      settings = value; NativeAppearancePreference.apply(value)
    }, navigate: { category = NativeSettingsCatalog.resolve($0) })
  }
  private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
    NativeSettingsCard(title: title, content: content)
  }

  private var appearancePanel: some View {
    VStack(spacing: 24) {
    settingsCard("테마") {
      BandalSettingRow(title: "모양") {
        BandalSegmented(options: [("light", "라이트"), ("dark", "다크"), ("system", "시스템")],
                        selection: Binding(get: { appearance }, set: { saveAppearance($0) }), identifierPrefix: "native-settings-theme-")
      }
      Divider()
      BandalSettingRow(title: "글자 크기") {
        HStack(spacing: 8) {
          Text("가").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
          Slider(value: Binding(get: { fontScale }, set: { value in let snapped = (value * 10).rounded() / 10; if snapped != fontScale { savePreference(["fontScale": snapped]) } }), in: 0.9...1.2, step: 0.1)
            .frame(width: 160).accessibilityLabel("글자 크기").accessibilityValue("\(Int(fontScale * 100))%").accessibilityIdentifier("native-settings-font-scale")
          Text("가").font(.system(size: 17)).foregroundStyle(NativeDesktopTheme.muted)
        }
      }
    }
    NativeSettingsCard(title: "사이드바") {
      Toggle("홈 버튼으로 접고 펼치기", isOn: $homeTogglesSidebar).accessibilityIdentifier("native-settings-home-toggles-sidebar")
      Divider()
      Toggle(isOn: $keyboardFoldsPanels) {
        VStack(alignment: .leading, spacing: 2) { Text("키보드를 쓰면 자동으로 접기"); Text("마크다운에서 키보드가 올라올 때").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted) }
      }.accessibilityIdentifier("native-settings-keyboard-folds-panels")
    }
    NativeSettingsCard(title: "펜슬") {
      BandalSettingRow(title: "손가락은 스크롤만", note: "필기는 펜슬로만 해요") { Text("항상").foregroundStyle(NativeDesktopTheme.secondary) }
      Divider()
      BandalSettingRow(title: "펜슬 두 번 탭", note: "iPad 설정 › Apple Pencil에서 바꿔요") { Text(pencilTapTitle).foregroundStyle(NativeDesktopTheme.secondary) }
    }
    NativeSettingsCard(title: "글꼴과 밀도") {
      Picker("필기 글꼴", selection: Binding(get: { settings["editorFont"] as? String ?? "sans" }, set: { savePreference(["editorFont": $0]) })) {
        Text("산세리프").tag("sans"); Text("세리프").tag("serif"); Text("고정폭").tag("mono")
      }.accessibilityIdentifier("native-settings-editor-font")
      Picker("밀도", selection: Binding(get: { density }, set: { savePreference(["density": $0]) })) {
        Text("편안하게").tag("comfortable"); Text("촘촘하게").tag("compact")
      }.pickerStyle(.segmented).accessibilityIdentifier("native-settings-density")
    }
    }
  }
  private func appearanceChoice(_ title: String, value: String) -> some View {
    Button {
      saveAppearance(value)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 0) {
          Rectangle().fill(value == "dark" ? Color(white: 0.1) : Color(white: 0.94)).frame(
            width: 22)
          VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(
              value == "dark" ? Color(white: 0.44) : Color(white: 0.75)
            ).frame(width: 32, height: 5)
            RoundedRectangle(cornerRadius: 2).fill(
              value == "dark" ? Color(white: 0.26) : Color(white: 0.9)
            ).frame(height: 17)
            RoundedRectangle(cornerRadius: 2).fill(
              value == "dark" ? Color(white: 0.26) : Color(white: 0.9)
            ).frame(height: 17)
          }.padding(10).frame(maxWidth: .infinity).background(
            value == "dark" ? Color(white: 0.13) : .white)
          if value == "system" { Rectangle().fill(Color(white: 0.13)).frame(width: 24) }
        }.frame(height: 76).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(
          RoundedRectangle(cornerRadius: 6).strokeBorder(NativeDesktopTheme.border))
        HStack(spacing: 4) {
          Text(title).font(NativeDesktopTheme.font( 12)).lineLimit(1).minimumScaleFactor(0.8)
          Spacer(minLength: 0)
          Image(systemName: appearance == value ? "checkmark.circle.fill" : "circle").font(
            NativeDesktopTheme.font( 13)
          ).foregroundStyle(
            appearance == value ? NativeDesktopTheme.accent : NativeDesktopTheme.muted)
        }
      }.padding(10).frame(maxWidth: .infinity)
        .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8).strokeBorder(
            appearance == value ? NativeDesktopTheme.accent : NativeDesktopTheme.border,
            lineWidth: appearance == value ? 2 : 1))
    }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(
      appearance == value ? .isSelected : []).accessibilityIdentifier("native-settings-theme-" + value)
  }
  /// 기본 모델·effort (the composer's picker), consent per provider, fair-use link. Signed out it
  /// is read-only under a one-line sign-in banner.
  private var aiPanel: some View {
    VStack(alignment: .leading, spacing: 20) {
      if !signedIn {
        HStack(spacing: 8) {
          Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(NativeDesktopTheme.secondary)
          Text("로그인하면 바로 쓸 수 있어요").font(.system(size: BandalMetrics.bodySize)).accessibilityIdentifier("native-ai-summary")
          Spacer()
          Button("로그인") { aiSignIn = true }.font(.system(size: BandalMetrics.bodySize, weight: .semibold)).accessibilityIdentifier("native-ai-settings-sign-in")
            .bandalPopover(isPresented: $aiSignIn, width: 260) { NativeSignInButtons(store: store, error: $aiSignInError, identifierPrefix: "native-ai-settings") }
        }.padding(.horizontal, BandalMetrics.padding).frame(minHeight: 40)
          .background(NativeDesktopTheme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: BandalMetrics.radius))
      }
      NativeSettingsCard(title: "기본 모델") {
        NativeAIModelPicker(catalog: aiCatalog, model: aiModel, effort: aiModel == "default" ? nil : aiEffort,
                            onSelect: { model, effort, _ in NativeAIPreferences.remember(model: model, effort: effort); aiModel = model; aiEffort = effort ?? aiEffort },
                            titled: false)
          .disabled(!signedIn).opacity(signedIn ? 1 : 0.6)
          .accessibilityIdentifier("native-settings-ai-picker")
      }
      NativeSettingsCard(title: "전송 동의") {
        ForEach(NativeAIProvider.allCases) { provider in consentRow(provider) }
        Link(destination: URL(string: "https://bandal.io/ko/docs/ai-fair-use")!) { Label("공정 이용 안내", systemImage: "arrow.up.right.square") }
          .font(.system(size: BandalMetrics.bodySize)).accessibilityIdentifier("native-ai-fair-use")
      }
    }
    .task(id: signedIn) {
      aiModel = NativeAIPreferences.model; aiEffort = NativeAIPreferences.effort
      if signedIn, let config = try? await store.invokePrivate("native:aiConfig") as? [String: Any] { aiCatalog = NativeAIModelCatalog(config) }
      else { aiCatalog = NativeAIModelCatalog() }
    }
  }
  @State private var aiCatalog = NativeAIModelCatalog()
  @State private var aiModel = NativeAIPreferences.model
  @State private var aiEffort = NativeAIPreferences.effort
  @State private var aiSignIn = false
  @State private var aiSignInError: String?
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
  private var accountPanel: some View {
    settingsCard("반달 계정") {
      if signedIn {
        HStack(spacing: 12) {
          Text(String((nickname.isEmpty ? (account["email"] as? String ?? "반") : nickname).prefix(1))).font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44).background(NativeDesktopTheme.text.opacity(0.08), in: Circle())
          VStack(alignment: .leading, spacing: 2) {
            Text(nickname.isEmpty ? "이름 없음" : nickname).font(.system(size: 16, weight: .semibold))
            if let email = account["email"] as? String { Text(email).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary) }
          }
        }.padding(.vertical, 4)
        Divider()
        if let email = account["email"] as? String { LabeledContent("이메일", value: email) }
        LabeledContent("이름") {
          // Saved on Enter, no save button.
          TextField("닉네임", text: $nickname).multilineTextAlignment(.trailing).frame(maxWidth: 220)
            .onSubmit { saveNickname() }.accessibilityIdentifier("native-settings-nickname")
        }
        if account["errorCode"] as? String == "reauthentication-required" {
          Text("안전을 위해 다시 로그인해 주세요. 기기의 자료는 계속 사용할 수 있어요.").font(.caption).foregroundStyle(.red)
          Button("Apple로 다시 로그인") { signIn("apple") }
          Button("Google로 다시 로그인") { signIn("google") }
        }
        DisclosureGroup("다른 로그인 방법 연결") {
          Button("Apple 연결") { linkProvider("apple") }
          Button("Google 연결") { linkProvider("google") }
        }
        Button("로그아웃") { signOutConfirmation = true }
          .bandalConfirm("로그아웃할까요?", isPresented: $signOutConfirmation, action: "로그아웃") {
            run { _ = try await store.invoke("auth:signOut"); try await loadAccount(); try await loadSync() }
          }
        Button(role: .destructive) { deleteAccountConfirmation = true } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("계정 삭제")
            Text("서버의 계정 정보가 지워져요. 이 iPad의 자료는 남아요.").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
          }
        }.accessibilityIdentifier("native-settings-delete-account")
          .bandalConfirm("계정을 삭제할까요?", isPresented: $deleteAccountConfirmation, message: "서버의 계정 정보가 지워져요. 이 iPad의 자료는 남아요.", action: "계정 삭제", destructive: true, identifier: "native-settings-delete-account-confirm") {
            run { _ = try await store.invoke("auth:deleteAccount"); try await loadAccount(); try await loadSync(); notice = "계정을 삭제했어요." }
          }
      } else {
        Text(accountPhase).foregroundStyle(.secondary)
        NativeSignInButtons(store: store, error: $error, identifierPrefix: "native-settings").frame(maxWidth: 280)
      }
    }
  }
  private func saveNickname() {
    guard !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    run { _ = try await store.invoke("auth:setNickname", ["nickname": nickname]); try await loadAccount(); notice = "이름을 바꿨어요." }
  }
  private var subscriptionPanel: some View {
    settingsCard("동기화 구독") {
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
    settingsCard("기기 프로필") {
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
    settingsCard("자료 동기화") {
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
  private var browserPanel: some View {
    settingsCard("웹 탐색과 보호") {
      Toggle("스와이프로 뒤로·앞으로 이동", isOn: browserBool("swipeNavigation", fallback: true))
      Toggle("추적 거부 요청", isOn: browserBool("doNotTrack", fallback: true))
      Picker("추적 방지", selection: browserString("trackingProtection", fallback: "balanced")) {
        Text("사용 안 함").tag("off")
        Text("균형").tag("balanced")
        Text("엄격").tag("strict")
      }
      Picker("팝업", selection: browserString("popupBehavior", fallback: "balanced")) {
        Text("균형").tag("balanced")
        Text("허용한 사이트만").tag("strict")
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
  private func browserBool(_ key: String, fallback: Bool) -> Binding<Bool> {
    Binding(
      get: { browserSettings[key] as? Bool ?? fallback },
      set: { value in saveBrowser(key, value: value) })
  }
  private func browserString(_ key: String, fallback: String) -> Binding<String> {
    Binding(
      get: { browserSettings[key] as? String ?? fallback },
      set: { value in saveBrowser(key, value: value) })
  }
  private func saveBrowser(_ key: String, value: Any) {
    run {
      settings =
        try await store.invoke("settings:set", ["browser": [key: value]]) as? [String: Any]
        ?? settings
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
  private static func pretty(_ value: Any?) -> String {
    guard let value,
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
      let text = String(data: data, encoding: .utf8)
    else { return "내용을 읽지 못했습니다." }
    return text
  }
}

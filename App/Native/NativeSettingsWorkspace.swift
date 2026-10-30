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
  @ObservedObject var store: NativeWorkspaceStore
  let initialCategory: String
  @AppStorage("native.appearance") private var appearance = "system"
  @AppStorage("native.fontScale") private var fontScale = 1.0
  @AppStorage("native.density") private var density = "comfortable"
  @State private var settings: [String: Any] = [:]
  @State private var account: [String: Any] = [:]
  @State private var sync: [String: Any] = [:]
  @State private var conflicts: [[String: Any]] = []
  @State private var billing: [String: Any] = [:]
  @State private var deleteAccountConfirmation = false
  @State private var newProfileConfirmation = false
  @State private var keyStatus: [String: [String: Any]] = [:]
  @State private var keys: [String: String] = [:]
  @State private var modelCatalog: [String: [String]] = [:]
  @State private var nickname = ""
  @State private var loading = false
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  @State private var removingKey: NativeAIProvider?
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
    self.initialCategory = NativeSettingsCatalog.categories.contains(where: { $0.id == initialCategory }) ? initialCategory : "appearance"
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
            VStack(alignment: .leading, spacing: 24) {
              VStack(alignment: .leading, spacing: 8) {
                Text(activeCategory.title).font(NativeDesktopTheme.font( 24, weight: .medium)).tracking(-0.6)
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
      category = value
      query = ""
      searchFocused = false
    }
    .refreshable { await load() }
    .onReceive(store.events) { event in
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
    .confirmationDialog(
      "API 키를 삭제할까요?",
      isPresented: Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } })
    ) {
      Button("API 키 삭제", role: .destructive) {
        guard let provider = removingKey else { return }
        removingKey = nil
        run {
          keyStatus[provider.rawValue] =
            try await store.invoke("agent:setApiKey", ["provider": provider.rawValue, "key": ""])
            as? [String: Any]
          keys[provider.rawValue] = ""
          modelCatalog[provider.rawValue] = nil
        }
      }
    }
    .confirmationDialog(NativeReleaseFlags.legacyCloudSync ? "계정을 삭제할까요? 서버의 동기화 자료와 구독 연결이 삭제됩니다. 이 기기의 파일은 남습니다." : "계정을 삭제할까요? 서버의 계정 정보가 삭제됩니다. 이 기기의 파일은 남습니다.", isPresented: $deleteAccountConfirmation, titleVisibility: .visible) {
      Button("계정 삭제", role: .destructive) {
        run {
          _ = try await store.invoke("auth:deleteAccount")
          try await loadAccount()
          try await loadSync()
          notice = "계정을 삭제했어요."
        }
      }
    }
    .confirmationDialog("새 프로필을 만들까요? 현재 자료는 백업한 위치와 기존 폴더에 그대로 남고, 앱은 빈 프로필로 다시 시작합니다.", isPresented: $newProfileConfirmation, titleVisibility: .visible) {
      Button("새 프로필 시작") { run { _ = try await store.invoke("profile:new") } }
    }
    .confirmationDialog("로그아웃할까요?", isPresented: $signOutConfirmation) {
      Button("로그아웃", role: .destructive) {
        run {
          _ = try await store.invoke("auth:signOut")
          try await loadAccount()
          try await loadSync()
        }
      }
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
                Text(NativeSettingsCatalog.groupTitle(group.id, locale: locale)).font(NativeDesktopTheme.font( 12, weight: .medium)).foregroundStyle(
                  NativeDesktopTheme.muted
                ).padding(.horizontal, 8)
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
          Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
      }
      .font(NativeDesktopTheme.font( 12)).foregroundStyle(NativeDesktopTheme.muted).padding(8).overlay(
        alignment: .top
      ) { NativeDesktopTheme.border.frame(height: 1) }
    }.padding(12).background(NativeDesktopTheme.surface).overlay(alignment: .trailing) {
      NativeDesktopTheme.border.frame(width: 1)
    }
  }
  @ViewBuilder private var settingsPanel: some View {
    switch category {
    case "ai": aiPanel
    case "account": VStack(alignment: .leading, spacing: 24) { accountPanel; if NativeReleaseFlags.legacyCloudSync { subscriptionPanel; syncPanel; profilePanel } }
    case "browser": expandedPanel("browser")
    case "advanced": VStack(spacing: 24) { expandedPanel("advanced"); storagePanel }
    case "appearance": appearancePanel
    case "about": VStack(spacing: 24) { aboutPanel; expandedPanel("about") }
    default: expandedPanel(category)
    }
  }
  private func expandedPanel(_ id: String) -> some View {
    NativeSettingsSections(section: id, store: store, settings: settings, save: { patch in
      guard let value = try await store.invoke("settings:set", patch) as? [String: Any] else {
        throw DesktopRuntimeError("설정 저장 결과를 확인하지 못했습니다.")
      }
      settings = value; NativeAppearancePreference.apply(value)
    }, navigate: { category = $0 })
  }
  private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(NativeDesktopTheme.font( 14, weight: .medium)).padding(20)
      NativeDesktopTheme.border.frame(height: 1)
      VStack(alignment: .leading, spacing: 16) { content() }.padding(20).frame(
        maxWidth: .infinity, alignment: .leading)
    }.background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border))
      .buttonStyle(NativeToolButtonStyle()).tint(NativeDesktopTheme.accent)
  }
  private var appearancePanel: some View {
    VStack(spacing: 24) {
    settingsCard("테마") {
      Text("기기의 설정을 따르거나 밝기를 직접 선택하세요.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
        appearanceChoice("시스템 설정", value: "system")
        appearanceChoice("라이트", value: "light")
        appearanceChoice("다크", value: "dark")
      }
    }
    NativeSettingsCard(title: "글자 크기", description: "앱의 글자와 여백 크기를 선택합니다. 노트의 확대/축소는 따로 적용됩니다.") {
      Picker("글자 크기", selection: Binding(get: { fontScale }, set: { value in savePreference(["fontScale": value]) })) {
        Text("작게 · 90%").tag(0.9); Text("기본 · 100%").tag(1.0); Text("크게 · 110%").tag(1.1); Text("더 크게 · 120%").tag(1.2)
      }.accessibilityIdentifier("native-settings-font-scale")
      Text("반달에서 읽고, 쓰고, 연결하세요.").font(NativeDesktopTheme.font(16))
    }
    NativeSettingsCard(title: "필기 글꼴", description: "노트 본문에 쓸 글꼴을 고릅니다. 메뉴와 사이드바는 그대로입니다.") {
      Picker("필기 글꼴", selection: Binding(get: { settings["editorFont"] as? String ?? "sans" }, set: { savePreference(["editorFont": $0]) })) {
        Text("산세리프").tag("sans"); Text("세리프").tag("serif"); Text("고정폭").tag("mono")
      }.accessibilityIdentifier("native-settings-editor-font")
    }
    NativeSettingsCard(title: "밀도", description: "여백과 버튼 높이를 고릅니다. 작은 화면에서는 촘촘하게가 한 줄 더 보여줍니다.") {
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
  private var aiPanel: some View {
    settingsCard("AI 제공자") {
      ForEach(NativeAIProvider.allCases) { provider in
        DisclosureGroup(provider.title) {
          let status = keyStatus[provider.rawValue]
          if status?["configured"] as? Bool == true {
            Label("키가 연결되어 있어요 · …\(status?["hint"] as? String ?? "")", systemImage: "key.fill")
              .font(.caption)
          } else {
            Text("등록된 API 키가 없어요.").font(.caption).foregroundStyle(.secondary)
          }
          SecureField(
            "새 API 키",
            text: Binding(
              get: { keys[provider.rawValue] ?? "" }, set: { keys[provider.rawValue] = $0 })
          )
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("native-key-\(provider.rawValue)")
          HStack {
            Button("키 저장") { saveKey(provider) }.disabled(
              (keys[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty)
            Spacer()
            if status?["configured"] as? Bool == true {
              Button("키 삭제", role: .destructive) { removingKey = provider }
            }
          }
          Button("사용 가능한 모델 확인") { fetchModels(provider) }.disabled(
            status?["configured"] as? Bool != true)
          if let models = modelCatalog[provider.rawValue] {
            Text(models.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
          }
          consentRow(provider)
        }
      }
      Text("API 키는 이 기기의 Keychain에 저장됩니다. 질문과 첨부 자료는 선택한 제공자에게 전송되며 해당 API 요금이 적용됩니다.").font(
        NativeDesktopTheme.font( 12)
      ).foregroundStyle(NativeDesktopTheme.muted)
    }
  }
  private func consentRow(_ provider: NativeAIProvider) -> some View {
    let target: AIProvider = switch provider { case .openAI: .openai; case .anthropic: .claude; case .google: .gemini }
    let english = locale == "en-US"
    let granted = consentRevision >= 0 && AIConsent.isGranted(target)
    return HStack {
      Text(granted
        ? (english ? "Consent to send to \(AIConsent.company(target)) given" : "\(AIConsent.company(target)) 전송에 동의함")
        : (english ? "Consent will be asked before the first send" : "처음 보낼 때 동의를 묻습니다"))
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      if granted {
        Button(english ? "Withdraw consent" : "동의 철회", role: .destructive) {
          AIConsent.set(target, granted: false); consentRevision += 1
        }.accessibilityIdentifier("native-ai-consent-revoke-\(provider.rawValue)")
      }
    }
  }
  private var accountPanel: some View {
    settingsCard("반달 계정") {
      if signedIn {
        if let email = account["email"] as? String {
          Label(email, systemImage: "person.crop.circle")
        }
        TextField("닉네임", text: $nickname)
        Button("닉네임 저장") {
          run {
            _ = try await store.invoke("auth:setNickname", ["nickname": nickname])
            try await loadAccount()
            notice = "닉네임을 저장했어요."
          }
        }.disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if account["errorCode"] as? String == "reauthentication-required" {
          Text("안전을 위해 다시 로그인해 주세요. 기기의 자료는 계속 사용할 수 있어요.").font(.caption).foregroundStyle(.red)
          Button("Apple로 다시 로그인") { signIn("apple") }
          Button("Google로 다시 로그인") { signIn("google") }
        }
        DisclosureGroup("다른 로그인 방법 연결") {
          Text("같은 반달 계정에 다른 로그인 수단을 추가합니다.").font(.caption).foregroundStyle(.secondary)
          Button("Apple 연결") { linkProvider("apple") }
          Button("Google 연결") { linkProvider("google") }
        }
        Button("로그아웃", role: .destructive) { signOutConfirmation = true }
        Button("계정 삭제", role: .destructive) { deleteAccountConfirmation = true }
      } else {
        Text(accountPhase).foregroundStyle(.secondary)
        Button("Apple로 로그인") { signIn("apple") }.disabled(account["phase"] as? String == "signing-in")
        Button("Google로 로그인") { signIn("google") }.disabled(
          account["phase"] as? String == "signing-in")
      }
    }
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
  private var storagePanel: some View {
    settingsCard("편집 내용 저장") {
      Button("저장 대기 중인 변경 다시 저장", systemImage: "arrow.clockwise") {
        run {
          try await store.flushDocuments()
          notice = "모든 변경을 저장했어요."
        }
      }
      Text("자료 원본과 노트는 기기에 저장됩니다. 저장에 실패한 편집은 복구 사본으로 보관됩니다.").font(.caption).foregroundStyle(
        .secondary)
    }
  }
  private var aboutPanel: some View {
    settingsCard("버전 정보") {
      LabeledContent(
        "버전",
        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "")
      LabeledContent(
        "빌드", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
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
      for provider in NativeAIProvider.allCases {
        keyStatus[provider.rawValue] =
          try await store.invoke("agent:apiKey", ["provider": provider.rawValue]) as? [String: Any]
      }
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
  private func saveKey(_ provider: NativeAIProvider) {
    let value = keys[provider.rawValue] ?? ""
    run {
      keyStatus[provider.rawValue] =
        try await store.invoke("agent:setApiKey", ["provider": provider.rawValue, "key": value])
        as? [String: Any]
      keys[provider.rawValue] = ""
      modelCatalog[provider.rawValue] = nil
      notice = "\(provider.title) API 키를 저장했어요."
    }
  }
  private func fetchModels(_ provider: NativeAIProvider) {
    run {
      let result =
        try await store.invoke("agent:models", ["provider": provider.rawValue, "refresh": true])
        as? [String: Any]
      modelCatalog[provider.rawValue] = (result?["models"] as? [[String: Any]] ?? []).compactMap {
        $0["id"] as? String
      }
      if let message = result?["error"] as? String { throw DesktopRuntimeError(message) }
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

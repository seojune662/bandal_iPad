import SwiftUI

/// The one school picker. The sidebar and Settings show it in a popover (`NativeSchoolPickerButton`);
/// onboarding shows it full screen. Choosing or confirming a school saves it and calls `done`.
struct NativeSchoolPicker: View {
    var store: NativeWorkspaceStore
    /// Starts the AI search for this name right away (the sidebar's ‘AI로 링크 찾기’).
    var aiQuery: String?
    /// Onboarding: the larger sizes of its frame, a row is picked first and "다음" saves it.
    var onboarding = false
    /// The most the list may take (onboarding: what the keyboard leaves). Four rows otherwise.
    var maxListHeight: CGFloat?
    /// The popover's ×. Closing while the AI search runs leaves it running.
    var close: (() -> Void)?
    let done: (School) -> Void
    @State private var model: NativeSchoolPickerModel
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var enteringCountry = false
    /// The country typed under 기타, applied once its entry has closed.
    @State private var pickedCountry: String?
    @State private var signInError: String?
    @State private var editing: String?
    @State private var editTitle = ""
    @State private var editURL = ""
    @State private var editInvalid = false
    @State private var manualName = ""
    @State private var manualError: String?
    /// The school in settings, marked in the list.
    @State private var current: String?
    @State private var spinning = false
    @FocusState private var searching: Bool

    init(store: NativeWorkspaceStore, aiQuery: String? = nil, country: String? = nil, onboarding: Bool = false, maxListHeight: CGFloat? = nil,
         close: (() -> Void)? = nil, done: @escaping (School) -> Void) {
        self.store = store; self.aiQuery = aiQuery; self.onboarding = onboarding; self.maxListHeight = maxListHeight; self.close = close; self.done = done
        // A saved country that is missing or not a real code falls back to the device's region.
        let country = country.flatMap(NativeSchoolPickerModel.region) ?? NativeSchoolPickerModel.region(NativeSchoolPickerModel.deviceCountry) ?? "KR"
        _model = State(initialValue: (onboarding ? nil : NativeSchoolPickerModel.waiting) ?? NativeSchoolPickerModel(directory: store.schools, country: country, save: { [store] school in
            // Read at save time: the patch keeps the user's own sites and drops the previous school's.
            let settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
            let patch = NativeUniversityCatalog.patch(choosing: school, current: settings["university"] as? [String: Any] ?? [:])
            _ = try await store.invoke("settings:set", ["university": patch])
        }, done: done))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !onboarding { header }
            switch model.phase {
            case .searching, .signIn: search
            case .finding: finding
            case .confirming: confirmation
            case .notFound: notFound
            case .manual: manual
            }
        }
        .foregroundStyle(NativeDesktopTheme.text)
        .task {
            // A search left running by a popover that closed: this picker shows how it went.
            if NativeSchoolPickerModel.waiting === model { NativeSchoolPickerModel.waiting = nil; model.announce = nil; model.done = done; return }
            current = ((try? await store.invoke("settings:get")) as? [String: Any]).flatMap { ($0["university"] as? [String: Any])?["universityId"] as? String }
            if let aiQuery { model.query = aiQuery }
            await model.search()
            if aiQuery != nil { await model.findWithAI() }
        }
        // A row left in edit mode belongs to the result it was opened on.
        .onChange(of: model.phase) { _, phase in editing = nil; editInvalid = false; if phase == .manual { manualName = name; manualError = nil } }
        .onDisappear(perform: leave)
        .onReceive(store.events) { event in
            // Signed in from the prompt: the AI search carries on by itself.
            if event.channel == "auth:changed", (event.payload as? [String: Any])?["phase"] as? String == "signed-in" { Task { await model.signedIn() } }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-school-picker")
    }

    private func text(_ korean: String) -> String { NativeAppLocale.string(korean, locale) }
    private var name: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var english: Bool { locale.language.languageCode?.identifier == "en" }
    private var rowHeight: CGFloat { onboarding ? 68 : 62 }
    private var inset: CGFloat { onboarding ? 16 : 14 }
    private func listHeight(_ rows: Int) -> CGFloat { min(CGFloat(rows) * (rowHeight + 1) - 1, maxListHeight ?? rowHeight * 4 + 3) }

    /// A popover that closes while the AI search runs leaves it running; the workspace's toast says how it ended.
    private func leave() {
        guard !onboarding, model.phase == .finding else { model.backToSearch(); return }
        let name = name, locale = locale
        NativeSchoolPickerModel.waiting = model
        model.announce = { [store] phase, notice in
            switch (phase, notice) {
            case (.confirming, _): store.errorMessage = String(format: NativeAppLocale.string("‘%@’ 사이트를 찾았어요. 학교 바꾸기에서 확인해 주세요", locale), name)
            case (.notFound, _): store.errorMessage = NativeAppLocale.string("AI도 학교 사이트를 찾지 못했어요", locale)
            case (_, .rateLimited(let limit)): store.errorMessage = String(format: NativeAppLocale.string("오늘 AI 찾기를 %lld번 모두 썼어요", locale), limit)
            case (_, .aiUnavailable): store.errorMessage = NativeAppLocale.string("지금은 AI로 찾을 수 없어요. 잠시 뒤 다시 하거나 직접 입력해 주세요.", locale)
            default: break
            }
        }
    }

    private var header: some View {
        HStack {
            (model.phase == .confirming ? Text("학교 확인") : Text("학교 바꾸기")).font(.system(size: 17, weight: .bold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { close?() } label: { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.muted).padding(-15)
                .accessibilityLabel("닫기").accessibilityIdentifier("native-school-close")
        }.frame(height: 24)
    }

    // MARK: Search

    private var search: some View {
        VStack(alignment: .leading, spacing: 14) {
            BandalField(prompt: "학교 이름 검색", text: $model.query, search: true, large: onboarding, identifier: "native-school-search").focused($searching)
            if case .rateLimited(let limit) = model.notice { limited(limit) } else {
                chips
                if model.searched && model.results.isEmpty && !name.isEmpty { noMatch } else { results }
                if model.offline {
                    Text("서버에 연결하지 못해 기기에 있는 목록에서 찾았어요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .center).accessibilityIdentifier("native-school-offline")
                }
                noticeLine
            }
        }
        .disabled(model.saving)
    }

    @ViewBuilder private var results: some View {
        if model.results.isEmpty {
            Text("학교 이름이나 약칭으로 찾아보세요.").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
        } else {
            BandalChoiceCard(radius: onboarding ? 16 : 14) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, school in
                            if index > 0 { divider }
                            BandalChoiceRow(title: english ? school.nameEn ?? school.name : school.name, detail: detail(school), chosen: isChosen(school),
                                            compact: !onboarding, showsDivider: false) {
                                // Onboarding: the pick ends the typing, so "다음" is not left under the keyboard.
                                if onboarding { model.selected = school; searching = false } else { Task { await model.choose(school) } }
                            }
                            .accessibilityIdentifier("native-school-result-" + school.id)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize).frame(maxHeight: listHeight(model.results.count)).padding(.vertical, 1)
            }
        }
        if onboarding, !model.results.isEmpty {
            VStack(spacing: 16) {
                NativeOnboardingButton(title: text("다음"), label: "다음 단계", identifier: "native-onboarding-next") {
                    if let school = model.selected { Task { await model.choose(school) } }
                }
                .disabled(model.selected == nil)
                Button { model.enterManually() } label: {
                    Text("목록에 없어요 · 직접 입력").font(.system(size: 15, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                        .frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("native-onboarding-manual")
            }
            .frame(maxWidth: .infinity).padding(.top, 14)
        }
    }

    private var divider: some View { NativeDesktopTheme.border.frame(height: 1).padding(.leading, inset) }
    private func isChosen(_ school: School) -> Bool {
        onboarding ? model.selected?.id == school.id : current == school.id || current == "custom:" + school.id
    }
    private func detail(_ school: School) -> String? {
        let parts = [school.domain, school.unreviewed ? text("AI가 찾은 정보 · 검토 전") : nil].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// No match: AI (signed in) or the name alone.
    private var noMatch: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("‘\(name)’를 찾지 못했어요").font(.system(size: 16, weight: .semibold)).frame(minHeight: 22).accessibilityIdentifier("native-school-no-match")
                Text("AI가 학교 사이트와 포털을 찾아 드릴 수 있어요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 18)
            }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 14)
            VStack(spacing: 8) {
                Button { Task { await model.findWithAI() } } label: {
                    HStack(spacing: 7) { Image(systemName: "sparkles").font(.system(size: 14)); Text("AI로 찾기") }
                }
                .buttonStyle(BandalButtonStyle(fills: true)).accessibilityIdentifier("native-school-ai")
                .bandalPopover(isPresented: Binding(get: { model.phase == .signIn }, set: { if !$0 { model.dismissSignIn() } }), arrowEdge: nil, width: 264) { signIn }
                Button("직접 입력") { model.enterManually() }.buttonStyle(BandalButtonStyle(kind: .outline, fills: true)).accessibilityIdentifier("native-school-manual")
            }
        }
    }

    /// The day's AI searches are used up: the dots are the searches, all spent.
    private func limited(_ limit: Int) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                HStack(spacing: 6) { ForEach(0..<max(limit, 1), id: \.self) { _ in Circle().fill(NativeDesktopTheme.muted).frame(width: 8, height: 8) } }.accessibilityHidden(true)
                Text("오늘 AI 찾기를 \(limit)번 모두 썼어요").font(.system(size: 16, weight: .semibold)).frame(minHeight: 22).accessibilityIdentifier("native-school-notice")
                Text("하루에 \(limit)번까지 쓸 수 있어요 · 내일 다시 채워져요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 18)
            }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 12)
            Button { model.enterManually() } label: { Text("직접 입력").fontWeight(.bold) }
                .buttonStyle(BandalButtonStyle(fills: true)).accessibilityIdentifier("native-school-manual")
        }
    }

    /// Signed out: sign in right here, then the search runs.
    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI로 찾으려면 로그인이 필요해요").font(.system(size: 15, weight: .semibold))
            NativeSignInButtons(store: store, error: $signInError, identifierPrefix: "native-school-sign-in")
            if let signInError { Text(signInError).font(.system(size: 12)).foregroundStyle(.red) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-school-sign-in-prompt")
    }

    @ViewBuilder private var noticeLine: some View {
        if let notice = model.notice {
            Group {
                switch notice {
                case .rateLimited(let limit): Text("오늘 AI 찾기를 \(limit)번 모두 썼어요")
                case .aiUnavailable: Text("지금은 AI로 찾을 수 없어요. 잠시 뒤 다시 하거나 직접 입력해 주세요.")
                case .saveFailed(let message): Text(verbatim: message)
                }
            }
            .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("native-school-notice")
        }
    }

    // MARK: Country

    private static let listed = ["KR": "대한민국", "US": "미국", "JP": "일본"]

    /// 대한민국 · 미국 · 일본 · 기타, wrapping to a second line when they do not fit.
    private var chips: some View {
        let other = Self.listed[model.country] == nil
        return BandalFlow(spacing: onboarding ? 8 : 6) {
            ForEach(["KR", "US", "JP"], id: \.self) { code in
                chip(text(Self.listed[code] ?? code), on: model.country == code) { model.country = code }.accessibilityIdentifier("native-school-country-" + code)
            }
            chip(other ? locale.localizedString(forRegionCode: model.country) ?? model.country : text("기타"), on: other) { enteringCountry = true }
                .accessibilityLabel("기타 나라").accessibilityIdentifier("native-school-country-other")
                .bandalPopover(isPresented: $enteringCountry, arrowEdge: nil, width: 240) {
                    BandalTextEntry(title: text("나라 코드 두 글자"), prompt: "DE", initial: other ? model.country : "", actionTitle: text("나라 바꾸기"),
                                    keyboard: .asciiCapable, identifier: "native-school-country-code") { code in
                        guard let region = NativeSchoolPickerModel.region(code) else { throw DesktopRuntimeError(text("없는 나라 코드예요. 예: DE, FR, CN")) }
                        pickedCountry = region; enteringCountry = false
                    }
                    // The country takes effect once the entry has gone, not while it and its keyboard are
                    // still leaving. Changing the list underneath at that moment was once followed by a
                    // UI test waiting on an app that never went idle; the cause was not pinned down.
                    .onDisappear { if let pickedCountry { model.country = pickedCountry; self.pickedCountry = nil } }
                }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: onboarding ? 14 : 13, weight: .medium)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? NativeDesktopTheme.bgApp : NativeDesktopTheme.text)
                // The chosen chip has no hairline and is that much shorter in the frame.
                .padding(.horizontal, onboarding ? 14 : 12).frame(height: (onboarding ? 38 : 32) - (on ? 2 : 0))
                .background(on ? NativeDesktopTheme.secondary : NativeDesktopTheme.bgApp, in: Capsule())
                .overlay { if !on { Capsule().strokeBorder(NativeDesktopTheme.border) } }.contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: AI search

    private var finding: some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(NativeDesktopTheme.border, lineWidth: 3)
                    Circle().trim(from: 0, to: 0.25).stroke(NativeDesktopTheme.text, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(spinning ? 360 : 0)).animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
                }
                .padding(1.5).frame(width: 36, height: 36).onAppear { spinning = true }.accessibilityHidden(true)
                Text("AI가 ‘\(name)’ 사이트를 찾는 중이에요").font(.system(size: 16, weight: .semibold)).frame(minHeight: 22).accessibilityIdentifier("native-school-finding")
                if model.slow {
                    (onboarding ? Text("조금 더 걸려요") : Text("조금 더 걸려요 · 창을 닫아도 계속 찾고, 끝나면 알려 드려요")).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 18)
                        .accessibilityIdentifier("native-school-slow")
                } else {
                    Text("학교 홈 · 포털 · 도서관 같은 링크를 모으고 있어요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 18)
                }
            }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 18)
            if model.slow, let close {
                Button("닫고 기다리기", action: close).buttonStyle(BandalButtonStyle(kind: .outline, fills: true)).accessibilityIdentifier("native-school-wait")
            }
            // Not in the design: the way back to the search field while the AI is still looking.
            link("그만 찾기", identifier: "native-school-stop") { model.backToSearch() }
        }
    }

    private var notFound: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(NativeDesktopTheme.muted).frame(height: 31).accessibilityHidden(true)
                Text("AI도 학교 사이트를 찾지 못했어요").font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center).frame(minHeight: 22)
                    .accessibilityIdentifier("native-school-not-found")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            VStack(spacing: 8) {
                Button { model.enterManually() } label: { Text("직접 입력").fontWeight(.bold) }
                    .buttonStyle(BandalButtonStyle(fills: true)).accessibilityIdentifier("native-school-manual")
                if model.remaining > 0 {
                    Button("다시 찾기 · 오늘 \(model.remaining)번 남음") { Task { await model.findAgain() } }
                        .buttonStyle(BandalButtonStyle(kind: .outline, fills: true)).accessibilityIdentifier("native-school-retry")
                }
            }
            if onboarding { link("다시 검색", identifier: "native-school-back") { model.backToSearch() } }
        }
    }

    /// A text button under the drawn ones, for what the design leaves out.
    private func link(_ title: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.vertical, -10).accessibilityIdentifier(identifier)
    }

    // MARK: 직접 입력

    private var manual: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("학교 직접 입력").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
            BandalField(prompt: "학교 이름", text: $manualName, large: onboarding, identifier: "native-school-name", onSubmit: saveManually)
            if let manualError { Text(verbatim: manualError).font(.system(size: 12)).foregroundStyle(.red) }
            Text("링크는 사이드바의 ‘AI로 링크 찾기’나 설정에서 나중에 더할 수 있어요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            pair(main: Button(action: saveManually) { Text("이 이름으로 설정").fontWeight(.bold) }.buttonStyle(BandalButtonStyle(fills: true))
                    .disabled(model.saving || manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("native-school-name-submit"),
                 other: Button("다시 검색") { model.backToSearch() }.buttonStyle(BandalButtonStyle(kind: .outline, fills: true)).accessibilityIdentifier("native-school-back"))
        }
        .onAppear { manualName = name }
    }

    private func saveManually() {
        let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { do { try await model.saveManually(name) } catch { manualError = error.localizedDescription } }
    }

    /// Two buttons side by side, the main one on the right; stacked with the main one on top when
    /// their labels do not fit (English), never cut short.
    private func pair(main: some View, other: some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { other; main }
            VStack(spacing: 8) { main; other }
        }
    }

    // MARK: Confirmation

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.found?.verified == false {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 12)).accessibilityHidden(true)
                    Text("AI가 찾은 정보 · 검토 전").font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("native-school-unverified")
                }
                .foregroundStyle(NativeDesktopTheme.secondary).padding(.horizontal, 10).frame(height: 27).background(NativeDesktopTheme.surface, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: model.found?.name ?? "").font(.system(size: 20, weight: .bold)).frame(minHeight: 28).accessibilityIdentifier("native-school-found-name")
                HStack(spacing: 0) {
                    if let domain = model.found?.domain, !domain.isEmpty { Text(verbatim: domain + " · ") }
                    Text("링크 \(model.links.count)개")
                }
                .font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1).frame(minHeight: 18)
            }
            if !model.links.isEmpty {
                BandalChoiceCard(radius: 14) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(model.links.enumerated()), id: \.element.id) { index, link in
                                    if index > 0 { NativeDesktopTheme.border.frame(height: 1).padding(.leading, 14) }
                                    linkRow(link).id(link.id)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize).frame(maxHeight: maxListHeight ?? 62 * 4.5).fixedSize(horizontal: false, vertical: true).padding(.vertical, 1)
                        // The row being edited, and the line that says what is wrong with it, stay in view above the keyboard.
                        .onChange(of: editing) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                        .onChange(of: editInvalid) { _, invalid in if invalid, let editing { withAnimation { proxy.scrollTo(editing, anchor: .bottom) } } }
                    }
                }
            }
            Button { if commitEdit() { begin(model.addLink()) } } label: {
                HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 13)); Text("링크 추가").font(.system(size: 14, weight: .medium)) }
                    .foregroundStyle(NativeDesktopTheme.secondary).padding(.horizontal, 4).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.vertical, -10).accessibilityLabel("학교 링크 추가").accessibilityIdentifier("native-school-link-add")
            Text("틀린 링크는 연필로 고치거나 휴지통으로 지운 뒤 저장해 주세요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 17)
            noticeLine
            pair(main: Button { if commitEdit() { Task { await model.confirm() } } } label: { Text("저장").fontWeight(.bold) }.buttonStyle(BandalButtonStyle(fills: true))
                    .disabled(model.saving).accessibilityLabel("이 학교로 설정").accessibilityIdentifier("native-school-confirm"),
                 other: Button("다시 찾기") { model.backToSearch() }.buttonStyle(BandalButtonStyle(kind: .outline, fills: true)).accessibilityIdentifier("native-school-back"))
        }
    }

    /// "https://portal.school.ac.kr/" is shown as portal.school.ac.kr.
    private func shortAddress(_ url: String) -> String {
        var text = url
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    @ViewBuilder private func linkRow(_ link: School.Link) -> some View {
        let symbol = Image("FigmaLinkRow").foregroundStyle(NativeDesktopTheme.secondary).accessibilityHidden(true)
        if editing == link.id {
            HStack(alignment: .top, spacing: 10) {
                symbol.padding(.top, 18)
                VStack(alignment: .leading, spacing: 6) {
                    editField(text("링크 이름"), text: $editTitle, identifier: "native-school-link-title")
                    editField("https://", text: $editURL, keyboard: .URL, identifier: "native-school-link-url")
                    if editInvalid { Text("이름과 웹 주소를 확인해 주세요.").font(.system(size: 12)).foregroundStyle(.red) }
                }
                iconButton("checkmark", label: "링크 편집 마치기", identifier: "native-school-link-done") { _ = commitEdit() }.padding(.top, 4)
            }
            .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 8)
        } else {
            HStack(spacing: 10) {
                symbol
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: link.title).font(.system(size: 15, weight: .medium)).lineLimit(1).frame(minHeight: 21)
                    Text(verbatim: shortAddress(link.url)).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1).truncationMode(.middle).frame(minHeight: 17)
                }
                Spacer(minLength: 8)
                HStack(spacing: -18) {
                    iconButton("pencil", label: "\(link.title) 링크 편집", identifier: "native-school-link-edit-" + link.id) { if commitEdit() { begin(link.id) } }
                    iconButton("trash", label: "\(link.title) 링크 삭제", identifier: "native-school-link-delete-" + link.id) { model.removeLink(link.id) }
                }
            }
            .padding(.leading, 14).frame(height: 62)
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-school-link-" + link.id)
        }
    }

    private func editField(_ prompt: String, text: Binding<String>, keyboard: UIKeyboardType = .default, identifier: String) -> some View {
        TextField(prompt, text: text).font(.system(size: 15)).textFieldStyle(.plain).keyboardType(keyboard)
            .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { _ = commitEdit() }
            .onChange(of: text.wrappedValue) { _, _ in editInvalid = false }
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier(identifier)
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Group { if symbol == "pencil" { Image("FigmaPencil") } else { Image(systemName: symbol).font(.system(size: 15)) } }.frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private func begin(_ id: String) {
        guard let link = model.links.first(where: { $0.id == id }) else { return }
        editTitle = link.title; editURL = link.url; editInvalid = false; editing = id
    }

    /// Ends the row being edited. An untouched new row is dropped; an invalid one stays open.
    private func commitEdit() -> Bool {
        guard let id = editing, model.links.contains(where: { $0.id == id }) else { editing = nil; return true }
        if editTitle.trimmingCharacters(in: .whitespaces).isEmpty && editURL.trimmingCharacters(in: .whitespaces).isEmpty, model.links.first(where: { $0.id == id })?.url.isEmpty == true {
            model.removeLink(id); editing = nil; return true
        }
        guard model.updateLink(id, title: editTitle, url: editURL) else { editInvalid = true; return false }
        editing = nil
        return true
    }
}

/// Lays chips out in a row and carries on to the next line when one does not fit; nothing is cut short or scrolled.
struct BandalFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(width: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func place(width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        return subviews.map { subview in
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            defer { x += size.width + spacing; line = max(line, size.height) }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }
}

/// A button that opens the school picker in a popover anchored to it.
struct NativeSchoolPickerButton<Content: View>: View {
    var store: NativeWorkspaceStore
    var aiQuery: String?
    var country: String?
    var arrowEdge: Edge = .top
    @ViewBuilder let label: () -> Content
    @State private var showing = false
    var body: some View {
        Button(action: { showing = true }, label: label)
            .bandalPopover(isPresented: $showing, arrowEdge: arrowEdge, width: 380, radius: 22, padding: 18) {
                NativeSchoolPicker(store: store, aiQuery: aiQuery, country: country, close: { showing = false }) { _ in showing = false }
            }
    }
}

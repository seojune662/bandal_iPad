import SwiftUI

/// The one school picker. The sidebar and Settings show it in a popover (`NativeSchoolPickerButton`);
/// onboarding shows it full screen. Choosing or confirming a school saves it and calls `done`.
struct NativeSchoolPicker: View {
    var store: NativeWorkspaceStore
    /// Starts the AI search for this name right away (the sidebar's ‘AI로 링크 찾기’).
    var aiQuery: String?
    /// The list's height when it has that many rows. A popover keeps it short enough to stay
    /// clear of the software keyboard on the smaller iPads.
    var maxListHeight: CGFloat = 220
    @State private var model: NativeSchoolPickerModel
    @Environment(\.locale) private var locale
    @State private var choosingCountry = false
    @State private var enteringCountry = false
    /// The country picked in the menu, applied once the menu has closed.
    @State private var pickedCountry: String?
    @State private var signInError: String?
    @State private var editing: String?
    @State private var editTitle = ""
    @State private var editURL = ""
    @State private var editInvalid = false

    init(store: NativeWorkspaceStore, aiQuery: String? = nil, country: String? = nil, maxListHeight: CGFloat = 220, done: @escaping (School) -> Void) {
        self.store = store; self.aiQuery = aiQuery; self.maxListHeight = maxListHeight
        // A saved country that is missing or not a real code falls back to the device's region.
        let country = country.flatMap(NativeSchoolPickerModel.region) ?? NativeSchoolPickerModel.region(NativeSchoolPickerModel.deviceCountry) ?? "KR"
        _model = State(initialValue: NativeSchoolPickerModel(directory: store.schools, country: country, save: { [store] school in
            // Read at save time: the patch keeps the user's own sites and drops the previous school's.
            let settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
            let patch = NativeUniversityCatalog.patch(choosing: school, current: settings["university"] as? [String: Any] ?? [:])
            _ = try await store.invoke("settings:set", ["university": patch])
        }, done: done))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .searching, .signIn: search
            case .finding: finding
            case .confirming: confirmation
            case .notFound: notFound
            case .manual: manual
            }
        }
        .font(.system(size: BandalMetrics.bodySize)).foregroundStyle(NativeDesktopTheme.text)
        .task {
            if let aiQuery { model.query = aiQuery }
            await model.search()
            if aiQuery != nil { await model.findWithAI() }
        }
        // A row left in edit mode belongs to the result it was opened on.
        .onChange(of: model.phase) { _, _ in editing = nil; editInvalid = false }
        // Closed mid-search (a tap outside the popover): the request stops with it.
        .onDisappear { model.backToSearch() }
        .onReceive(store.events) { event in
            // Signed in from the prompt: the AI search carries on by itself.
            if event.channel == "auth:changed", (event.payload as? [String: Any])?["phase"] as? String == "signed-in" { Task { await model.signedIn() } }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-school-picker")
    }

    private func text(_ korean: String) -> String { NativeAppLocale.string(korean, locale) }
    private var name: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func countryName(_ code: String) -> String { locale.localizedString(forRegionCode: code) ?? code }

    // MARK: Search

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            BandalSearchList(prompt: text("학교 이름 검색"), query: $model.query, maxHeight: maxListHeight, identifier: "native-school-search", accessory: { countryChip }) {
                ForEach(model.results) { school in
                    BandalMenuRow(school.name, symbol: "building.columns", detail: [school.nameEn, school.domain].compactMap { $0 }.first { !$0.isEmpty }) { Task { await model.choose(school) } }
                        .accessibilityIdentifier("native-school-result-" + school.id)
                }
                if model.results.isEmpty && name.isEmpty {
                    Text("학교 이름이나 약칭으로 찾아보세요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(8)
                }
            }
            if model.offline {
                Text("서버에 연결하지 못해 기기에 있는 목록에서 찾았어요.").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                    .accessibilityIdentifier("native-school-offline")
            }
            if !name.isEmpty { actions }
            noticeLine
        }
        .disabled(model.saving)
    }

    /// No match, or the school is not in the list: AI (signed in) or the name alone. They stay put
    /// while a search is under way, so the picker does not jump at every keystroke.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if model.searched && model.results.isEmpty {
                    Text("‘\(name)’ 학교를 찾지 못했어요").font(.system(size: BandalMetrics.bodySize, weight: .medium)).lineLimit(1).accessibilityIdentifier("native-school-no-match")
                } else {
                    Text("찾는 학교가 없나요?").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                }
            }.frame(minHeight: 18)
            HStack(spacing: 8) {
                // The main action only when there is nothing to choose from.
                Button { Task { await model.findWithAI() } } label: { Label("AI로 찾기", systemImage: "sparkles") }
                    .buttonStyle(NativeToolButtonStyle(primary: model.searched && model.results.isEmpty)).accessibilityIdentifier("native-school-ai")
                    .bandalPopover(isPresented: Binding(get: { model.phase == .signIn }, set: { if !$0 { model.dismissSignIn() } }), arrowEdge: nil, width: 264) { signIn }
                Button("직접 입력") { model.enterManually() }.buttonStyle(NativeToolButtonStyle()).accessibilityIdentifier("native-school-manual")
            }
        }
        .padding(.top, 4)
    }

    /// Signed out: sign in right here, then the search runs.
    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI로 찾으려면 로그인이 필요해요").font(.system(size: BandalMetrics.bodySize, weight: .semibold))
            NativeSignInButtons(store: store, error: $signInError, identifierPrefix: "native-school-sign-in")
            if let signInError { Text(signInError).font(.system(size: 11)).foregroundStyle(.red) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-school-sign-in-prompt")
    }

    @ViewBuilder private var noticeLine: some View {
        if let notice = model.notice {
            Group {
                switch notice {
                case .rateLimited(let limit): Text("AI로 찾기를 \(limit)번 다 썼어요. 직접 입력해 주세요.")
                case .aiUnavailable: Text("지금은 AI로 찾을 수 없어요. 잠시 뒤 다시 하거나 직접 입력해 주세요.")
                case .saveFailed(let message): Text(verbatim: message)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("native-school-notice")
        }
    }

    // MARK: Country

    private var countryChip: some View {
        Button { enteringCountry = false; choosingCountry = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 11))
                Text(verbatim: countryName(model.country)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary)
            .padding(.horizontal, 8).frame(height: 24)
            .background(NativeDesktopTheme.bgApp, in: Capsule()).overlay(Capsule().strokeBorder(NativeDesktopTheme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("나라: \(countryName(model.country))").accessibilityIdentifier("native-school-country")
        .bandalPopover(isPresented: $choosingCountry, arrowEdge: nil, width: 220) {
            // The country takes effect once the menu has gone, not while it and its keyboard are
            // still leaving. Changing the list underneath at that moment was once followed by a
            // UI test waiting on an app that never went idle; the cause was not pinned down.
            VStack(alignment: .leading, spacing: 0) { countryMenu }
                .onDisappear { if let pickedCountry { model.country = pickedCountry; self.pickedCountry = nil } }
        }
    }

    @ViewBuilder private var countryMenu: some View {
        let listed = ["KR", "US", "JP"]
        if enteringCountry {
            // 기타: the entry takes the menu's place, so it fits beside the keyboard on a small iPad.
            BandalTextEntry(title: text("나라 코드 두 글자"), prompt: "DE", initial: listed.contains(model.country) ? "" : model.country, actionTitle: text("나라 바꾸기"),
                            keyboard: .asciiCapable, identifier: "native-school-country-code") { code in
                guard let region = NativeSchoolPickerModel.region(code) else { throw DesktopRuntimeError(text("없는 나라 코드예요. 예: DE, FR, CN")) }
                pickedCountry = region; choosingCountry = false
            }
        } else {
            BandalMenu {
                ForEach(listed, id: \.self) { code in
                    BandalMenuRow(countryName(code), checked: model.country == code) { pickedCountry = code; choosingCountry = false }
                        .accessibilityIdentifier("native-school-country-" + code)
                }
                BandalMenuDivider()
                BandalMenuRow(text("기타"), detail: listed.contains(model.country) ? nil : countryName(model.country), checked: !listed.contains(model.country)) { enteringCountry = true }
                    .accessibilityLabel("기타 나라").accessibilityIdentifier("native-school-country-other")
            }
        }
    }

    // MARK: AI search

    private var finding: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("\(name) 사이트를 찾는 중…").font(.system(size: BandalMetrics.bodySize, weight: .medium)).multilineTextAlignment(.center)
                .accessibilityIdentifier("native-school-finding")
            if model.slow { Text("조금 더 걸려요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).accessibilityIdentifier("native-school-slow") }
            Button("그만 찾기") { model.backToSearch() }.buttonStyle(NativeToolButtonStyle(compact: true)).accessibilityIdentifier("native-school-stop")
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private var notFound: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.circle").font(.system(size: 26, weight: .light)).foregroundStyle(NativeDesktopTheme.muted)
            Text("‘\(name)’ 사이트를 못 찾았어요").font(.system(size: BandalMetrics.bodySize, weight: .medium)).multilineTextAlignment(.center)
                .accessibilityIdentifier("native-school-not-found")
            Text("학교 이름만 먼저 넣어 두고, 링크는 나중에 더할 수 있어요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("다시 검색") { model.backToSearch() }.buttonStyle(NativeToolButtonStyle()).accessibilityIdentifier("native-school-back")
                Button("직접 입력") { model.enterManually() }.buttonStyle(NativeToolButtonStyle(primary: true)).accessibilityIdentifier("native-school-manual")
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    // MARK: 직접 입력

    private var manual: some View {
        VStack(alignment: .leading, spacing: 8) {
            BandalTextEntry(title: text("학교 직접 입력"), prompt: text("학교 이름"), initial: name, actionTitle: text("이 이름으로 설정"), identifier: "native-school-name") { name in
                try await model.saveManually(name)
            }
            Text("링크는 사이드바의 ‘AI로 링크 찾기’나 설정에서 나중에 더할 수 있어요.").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("다시 검색") { model.backToSearch() }.buttonStyle(NativeToolButtonStyle(compact: true)).accessibilityIdentifier("native-school-back")
        }
    }

    // MARK: Confirmation

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.found?.name ?? "").font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("native-school-found-name")
                    if let domain = model.found?.domain, !domain.isEmpty { Text(verbatim: domain).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted) }
                }
                Spacer(minLength: 8)
                if model.found?.verified == false {
                    Text("AI가 찾은 정보 · 검토 전").font(.system(size: 11, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                        .padding(.horizontal, 8).frame(height: 22).background(NativeDesktopTheme.raised, in: Capsule())
                        .accessibilityIdentifier("native-school-unverified")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.links) { link in linkRow(link).id(link.id) }
                        BandalMenuRow(text("링크 추가"), symbol: "plus") { if commitEdit() { begin(model.addLink()) } }
                            .accessibilityLabel("학교 링크 추가").accessibilityIdentifier("native-school-link-add")
                    }
                }
                .frame(maxHeight: maxListHeight).fixedSize(horizontal: false, vertical: true)
                // The row being edited, and the line that says what is wrong with it, stay in view above the keyboard.
                .onChange(of: editing) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                .onChange(of: editInvalid) { _, invalid in if invalid, let editing { withAnimation { proxy.scrollTo(editing, anchor: .bottom) } } }
            }
            noticeLine
            HStack(spacing: 8) {
                Button("다시 검색") { model.backToSearch() }.buttonStyle(NativeToolButtonStyle()).accessibilityIdentifier("native-school-back")
                Spacer()
                Button("이 학교로 설정") { if commitEdit() { Task { await model.confirm() } } }
                    .buttonStyle(NativeToolButtonStyle(primary: true)).disabled(model.saving).accessibilityIdentifier("native-school-confirm")
            }
        }
    }

    @ViewBuilder private func linkRow(_ link: School.Link) -> some View {
        let symbol = Image(systemName: NativeUniversityService.symbol(link.kind)).font(.system(size: 13)).frame(width: 18).foregroundStyle(NativeDesktopTheme.secondary)
        if editing == link.id {
            HStack(alignment: .top, spacing: 8) {
                symbol.padding(.top, 9)
                VStack(alignment: .leading, spacing: 4) {
                    editField(text("링크 이름"), text: $editTitle, identifier: "native-school-link-title")
                    editField("https://", text: $editURL, keyboard: .URL, identifier: "native-school-link-url")
                    if editInvalid { Text("이름과 웹 주소를 확인해 주세요.").font(.system(size: 11)).foregroundStyle(.red) }
                }
                iconButton("checkmark", label: "링크 편집 마치기", identifier: "native-school-link-done") { _ = commitEdit() }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        } else {
            HStack(spacing: 8) {
                symbol
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: link.title).lineLimit(1)
                    Text(verbatim: link.url).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                iconButton("pencil", label: "\(link.title) 링크 편집", identifier: "native-school-link-edit-" + link.id) { if commitEdit() { begin(link.id) } }
                iconButton("trash", label: "\(link.title) 링크 삭제", identifier: "native-school-link-delete-" + link.id) { model.removeLink(link.id) }
            }
            .padding(.leading, 8).frame(minHeight: 44)
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-school-link-" + link.id)
        }
    }

    private func editField(_ prompt: String, text: Binding<String>, keyboard: UIKeyboardType = .default, identifier: String) -> some View {
        TextField(prompt, text: text).textFieldStyle(.plain).keyboardType(keyboard)
            .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { _ = commitEdit() }
            .onChange(of: text.wrappedValue) { _, _ in editInvalid = false }
            .padding(.horizontal, 8).frame(minHeight: 32)
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
            .overlay { RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall).stroke(NativeDesktopTheme.border) }
            .accessibilityIdentifier(identifier)
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 36, height: 36).contentShape(Rectangle()) }
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
            .bandalPopover(isPresented: $showing, arrowEdge: arrowEdge, width: 360) {
                NativeSchoolPicker(store: store, aiQuery: aiQuery, country: country) { _ in showing = false }
            }
    }
}

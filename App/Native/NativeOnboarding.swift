import SwiftUI

/// Whether a launch shows onboarding. It is decided once per device, after the store has loaded:
/// someone who already has a school or a course is an existing user and never sees it.
enum NativeOnboardingGate {
    /// `pending`: a new install, covered until the store answers. `deciding`: storage is already
    /// there (an update), so the workspace shows as usual while the store answers.
    enum Stage { case pending, deciding, showing, closed }
    static let doneKey = "native.onboarding.done"
    static let argument = "--native-onboarding"

    static func initialStage(root: URL, arguments: [String] = ProcessInfo.processInfo.arguments, hostedTest: Bool = NSClassFromString("XCTestCase") != nil,
                             defaults: UserDefaults = .standard) -> Stage {
        guard isPending(arguments: arguments, hostedTest: hostedTest, defaults: defaults) else { return .closed }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("bandal.db").path) ? .deciding : .pending
    }

    /// The decision is still open on this launch. Tests never see onboarding unless they ask for it.
    static func isPending(arguments: [String] = ProcessInfo.processInfo.arguments, hostedTest: Bool = NSClassFromString("XCTestCase") != nil,
                          defaults: UserDefaults = .standard) -> Bool {
        if arguments.contains("--native-ui-testing") || hostedTest, !arguments.contains(argument) { return false }
        return !defaults.bool(forKey: doneKey)
    }

    static func shouldShow(settings: [String: Any], hasCourses: Bool) -> Bool {
        !hasCourses && (settings["university"] as? [String: Any])?["universityId"] as? String == nil
    }

    /// Step 1 opens on the device's language, unless English was already chosen in Settings.
    static func language(saved: Any?, preferred: [String] = Locale.preferredLanguages) -> String {
        saved as? String == NativeAppLocale.english ? NativeAppLocale.english : NativeAppLocale.device(preferred)
    }
}

/// Onboarding over the workspace, which is inert underneath; on a new install its bare surface
/// stands in until the decision is made, so the workspace never flashes before onboarding.
struct NativeOnboardingCover: ViewModifier {
    let stage: NativeOnboardingGate.Stage
    var store: NativeWorkspaceStore
    let finish: () -> Void
    func body(content: Content) -> some View {
        content.disabled(stage == .pending || stage == .showing)
            .overlay {
                switch stage {
                case .pending: NativeOnboardingSurface()
                case .showing: NativeOnboarding(store: store, finish: finish).transition(.opacity)
                case .deciding, .closed: EmptyView()
                }
            }
            .animation(.easeOut(duration: 0.25), value: stage)
    }
}

/// The window's backdrop under paper glass. Onboarding lies over the workspace, so it brings its own
/// backdrop: the workspace must not show through the paper.
struct NativeOnboardingSurface: View {
    /// The opening wears the decor: the backdrop shows through a light veil, so the colour chosen on the
    /// 색 step is the colour of the screen it is chosen on.
    var body: some View { ZStack { NativeWorkspaceBackdrop(); Self.veil.ignoresSafeArea() }.accessibilityHidden(true) }
    private static let veil = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x18 / 255, green: 0x18 / 255, blue: 0x1a / 255, alpha: 0.55) : UIColor(white: 1, alpha: 0.5) })
}

/// Onboarding's main action: a 220 × 48 capsule that grows with its label, with the design's soft rim and a gloss from its trailing end.
struct NativeOnboardingButton: View {
    let title: String
    let label: LocalizedStringKey
    let identifier: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: 16, weight: .heavy)).foregroundStyle(NativeDesktopTheme.onAccent).lineLimit(1).fixedSize()
                .padding(.horizontal, 18).frame(minWidth: 220, minHeight: 48)
                .background(NativeDesktopTheme.accent, in: Capsule())
                .overlay {
                    // The frame's gradient runs from the trailing end to a little past the leading one.
                    let end = UnitPoint(x: -0.126, y: 0.5)
                    ZStack {
                        Capsule().fill(LinearGradient(stops: [.init(color: .white.opacity(0.4), location: 0), .init(color: .white.opacity(0.1), location: 0.14), .init(color: .clear, location: 0.3)], startPoint: .trailing, endPoint: end))
                        Capsule().strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.6), location: 0), .init(color: .white.opacity(0.06), location: 0.22), .init(color: .white.opacity(0.1), location: 1)], startPoint: .trailing, endPoint: end))
                    }
                    .opacity(scheme == .dark ? 1 : 0.5).allowsHitTesting(false)
                }
                // The frame's inner shadow: #282828 along the rim, lighter than the fill in light and darker in dark.
                .overlay { Capsule().strokeBorder(Color(white: 0x28 / 255.0).opacity(scheme == .dark ? 0.12 : 0.9), lineWidth: 8).blur(radius: 4).clipShape(Capsule()).allowsHitTesting(false) }
                .opacity(enabled ? 1 : 0.4).contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

/// First-run setup, full screen over the workspace: 언어 → 학교 → 초대 코드 → 완료. "나중에" leaves
/// at any step, and every choice stays in Settings (일반 › 언어, 계정 › 학교, 계정 › 친구 초대). No
/// sign-in is asked here.
struct NativeOnboarding: View {
    var store: NativeWorkspaceStore
    let finish: () -> Void
    private enum Step: Int, CaseIterable { case language, school, decor, invite, share, done }
    @AppStorage(NativeAppLocale.key) private var language = NativeAppLocale.korean
    @State private var step = Step.language
    @AppStorage(NativeDecor.paletteKey) private var decorPalette = NativeDecorPalette.default.id
    @AppStorage(NativeDecor.intensityKey) private var decorIntensity = NativeDecor.defaultIntensity
    /// The school this run saved, for the last step's summary.
    @State private var school: School?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private static let width: CGFloat = 520
    private var english: Bool { locale.language.languageCode?.identifier == "en" }

    var body: some View {
        ZStack(alignment: .top) {
            // The frame's content sits 16 pt under the window's centre (7 pt over it on the last step).
            Group {
                switch step {
                case .language: languageStep
                case .school: schoolStep
                case .decor: decorStep
                case .invite: inviteStep
                case .share: shareStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: Self.width).frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 82).padding(.bottom, step == .done ? 96 : 50).padding(.horizontal, 24)
            .id(step).transition(.opacity)
            topBar
        }
        .ignoresSafeArea(.container)
        .background { NativeOnboardingSurface() }
        // Onboarding lies over the workspace; it hands the decor down itself, so the 색 step repaints as it changes.
        .environment(\.nativeDecor, NativeDecor(palette: .named(decorPalette), intensity: min(max(decorIntensity, 0), 1)))
        .foregroundStyle(NativeDesktopTheme.text).tint(NativeDesktopTheme.accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
        // An invite link opened the app: its code goes into the invite step's field.
        .onChange(of: store.referral.linkedCode, initial: true) { _, code in if code != nil { step = .invite } }
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("native-onboarding")
    }

    // MARK: Chrome

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(item == step ? NativeDesktopTheme.text : NativeDesktopTheme.muted.opacity(0.45)).frame(width: item == step ? 24 : 8, height: 8)
                }
            }
            .offset(y: 2)
            .accessibilityElement().accessibilityLabel("\(Step.allCases.count)단계 중 \(step.rawValue + 1)단계").accessibilityIdentifier("native-onboarding-dots")
            HStack {
                if let previous = Step(rawValue: step.rawValue - 1) {
                    Button { step = previous } label: {
                        HStack(spacing: 6) { Image(systemName: "chevron.left").font(.system(size: 15)); Text("이전").font(.system(size: 17, weight: .medium)) }
                            .frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("이전 단계").accessibilityIdentifier("native-onboarding-back")
                }
                Spacer()
                // "나중에" is "Later" elsewhere in the app; here the design says Skip.
                Button(action: finish) { Text(verbatim: english ? "Skip" : "나중에").font(.system(size: 17, weight: .medium)).frame(height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("첫 설정 나중에 하기").accessibilityIdentifier("native-onboarding-later")
            }
            .foregroundStyle(NativeDesktopTheme.secondary)
        }
        .frame(height: 44).padding(.top, 38).padding(.leading, 60).padding(.trailing, 64)
    }

    private func heading(_ title: LocalizedStringKey, _ subtitle: Text?) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 34, weight: .bold)).frame(minHeight: 48).accessibilityAddTraits(.isHeader)
            if let subtitle { subtitle.font(.system(size: 17)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 24) }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    private func primaryButton(_ title: String, label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        NativeOnboardingButton(title: NativeAppLocale.string(title, locale), label: label, identifier: identifier, action: action)
    }

    private var divider: some View { NativeDesktopTheme.border.frame(height: 1).padding(.leading, 16) }

    // MARK: Steps

    private var languageStep: some View {
        VStack(spacing: 28) {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(NativeDesktopTheme.bgApp).frame(width: 80, height: 80)
                .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
                .shadow(color: .black.opacity(0.08), radius: 6, x: 4, y: 6)
                .overlay { Image(systemName: "moon").font(.system(size: 36)) }.accessibilityHidden(true)
            heading("반달에 오신 걸 환영해요", Text("필기 · 자료 · AI를 한곳에서 이어 쓰는 공부 노트"))
            VStack(alignment: .leading, spacing: 10) {
                Text("언어").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 18)
                BandalChoiceCard {
                    VStack(spacing: 0) {
                        languageRow(NativeAppLocale.korean, name: "한국어", other: "Korean")
                        divider
                        languageRow(NativeAppLocale.english, name: "English", other: english ? "English" : "영어")
                        divider
                        // No Japanese table yet: the row is drawn and waits.
                        BandalChoiceRow(title: "日本語", detail: english ? "Japanese" : "일본어", showsDivider: false) {}
                            .overlay(alignment: .trailing) { Text("준비 중").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted).padding(.trailing, 16) }
                            .allowsHitTesting(false).accessibilityIdentifier("native-onboarding-language-ja")
                    }
                    .padding(.vertical, 1)
                }
            }
            primaryButton("다음", label: "다음 단계", identifier: "native-onboarding-next") { step = .school }
        }
    }

    /// The language's own name, with its name in the language on screen underneath.
    private func languageRow(_ value: String, name: String, other: String) -> some View {
        BandalChoiceRow(title: name, detail: other, chosen: language == value, showsDivider: false, tinted: false) { choose(value) }
            .accessibilityLabel(Text(verbatim: name + " · " + other)).accessibilityIdentifier("native-onboarding-language-" + value)
    }

    /// The screen switches at once; settings.json (the preference) follows.
    private func choose(_ value: String) {
        guard value != language else { return }
        language = value
        Task {
            do { _ = try await store.invoke("settings:set", ["locale": value]) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private var schoolStep: some View {
        // The list takes the height the keyboard leaves, so the field and the buttons under the list
        // stay on screen on every iPad; a short window gives up the second line, then the heading.
        GeometryReader { geometry in
            let height = geometry.size.height
            VStack(spacing: 28) {
                if height >= 420 { heading("학교를 골라 주세요", height >= 520 ? Text("학교 사이트와 포털 바로가기를 자동으로 채워 드려요") : nil) }
                // Everything on this step but the list: field, chips, button and the line under it.
                NativeSchoolPicker(store: store, onboarding: true, maxListHeight: max(68, min(275, height - (height >= 520 ? 352 : height >= 420 ? 318 : 242)))) { school in
                    self.school = school; step = .decor
                }
            }
            // Anchored where the frame's four-row list puts it, so the heading stays put while the list changes.
            .padding(.top, max(0, (height - 628) / 2)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// 색: the decor, chosen on a small window drawn with it. The whole opening repaints as it changes.
    private var decorStep: some View {
        VStack(spacing: 24) {
            heading("반달의 색을 골라 주세요", Text("설정 › 화면에서 언제든 바꿀 수 있어요"))
            NativeDecorPreview().frame(height: 200)
            BandalChoiceCard {
                VStack(alignment: .leading, spacing: 0) {
                    NativeDecorSwatches(selection: $decorPalette).padding(.horizontal, 16).padding(.vertical, 14)
                    divider
                    HStack {
                        Text("세기").font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary)
                        Spacer(minLength: 8)
                        NativeDecorIntensitySlider(value: $decorIntensity, palette: .named(decorPalette))
                    }.padding(.horizontal, 16).frame(minHeight: 56)
                }
            }
            primaryButton("다음", label: "다음 단계", identifier: "native-onboarding-next") { step = .invite }
        }
    }

    /// 초대 코드, for someone a friend invited: a code that exists is kept on this iPad and claimed
    /// when they sign in. The field has the keyboard from the start.
    private var inviteStep: some View {
        VStack(spacing: 28) {
            heading("초대 코드가 있나요?", nil)
            NativeReferralCodeEntry(referral: store.referral, large: true)
            if store.referral.applied {
                primaryButton("다음", label: "다음 단계", identifier: "native-onboarding-next") { step = .share }
            } else {
                Button { store.referral.withdraw(); step = .share } label: {
                    Text("없어요, 건너뛰기").font(.system(size: 15, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                        .frame(minWidth: 220, minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("native-referral-skip")
            }
        }
    }

    /// 친구 초대: the other side of the invitation. Signed in, this account's code to copy or share and what
    /// it has brought; signed out, the sign-in that gives it a code. Either way 다음 goes on without it.
    private var shareStep: some View {
        VStack(spacing: 24) {
            heading("친구를 초대하고 AI 100회 받기", Text("친구가 로그인하고 첫 폴더를 만들면 둘 다 받아요"))
            BandalChoiceCard {
                NativeReferralInvite(store: store, showsTitle: false).padding(16)
            }
            primaryButton("다음", label: "다음 단계", identifier: "native-onboarding-next") { step = .done }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 28) {
            Circle().fill(NativeDesktopTheme.adaptive(0xededed, 0x1f1f1f)).frame(width: 80, height: 80)
                .overlay { BandalCheck(width: 22.5, weight: 3) }
                .accessibilityHidden(true)
            heading("준비됐어요", doneLine)
            BandalChoiceCard {
                VStack(spacing: 0) {
                    summaryRow("학교", value: school.map(name) ?? NativeAppLocale.string("아직 고르지 않았어요", locale))
                    divider
                    summaryRow("색", value: NativeAppLocale.string(NativeDecorPalette.named(decorPalette).title, locale))
                    divider
                    summaryRow("언어", value: language == NativeAppLocale.english ? "English" : "한국어")
                }
                .padding(.top, 1).padding(.bottom, 2)
            }
            primaryButton("시작하기", label: "반달 시작하기", identifier: "native-onboarding-finish", action: finish)
        }
    }

    /// What this run put in the sidebar; without a school (an invite link went straight to its step), where to find the choices later.
    private var doneLine: Text {
        guard let school else { return Text("언어와 학교는 설정에서 언제든 바꿀 수 있어요.") }
        return school.links.isEmpty ? Text("\(name(school)) · 링크는 사이드바에서 AI로 찾을 수 있어요") : Text("\(name(school)) 바로가기 \(school.links.count)개를 사이드바에 넣었어요")
    }
    private func name(_ school: School) -> String { english ? school.nameEn ?? school.name : school.name }

    private func summaryRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(NativeDesktopTheme.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value).fontWeight(.medium).lineLimit(1)
        }
        .font(.system(size: 15)).padding(.horizontal, 16).frame(height: 47)
    }
}

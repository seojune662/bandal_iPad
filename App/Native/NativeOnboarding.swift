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

/// Onboarding over the workspace, which is inert underneath; on a new install a plain cover
/// stands in until the decision is made, so the workspace never flashes before onboarding.
struct NativeOnboardingCover: ViewModifier {
    let stage: NativeOnboardingGate.Stage
    var store: NativeWorkspaceStore
    let finish: () -> Void
    func body(content: Content) -> some View {
        content.disabled(stage == .pending || stage == .showing)
            .overlay {
                switch stage {
                case .pending: NativeDesktopTheme.bgApp.ignoresSafeArea()
                case .showing: NativeOnboarding(store: store, finish: finish).transition(.opacity)
                case .deciding, .closed: EmptyView()
                }
            }
            .animation(.easeOut(duration: 0.25), value: stage)
    }
}

/// First-run setup, full screen over the workspace: 언어 → 학교 → 초대 코드 → 완료. "나중에" leaves
/// at any step, and every choice stays in Settings (일반 › 언어, 계정 › 학교, 계정 › 친구 초대). No
/// sign-in is asked here.
struct NativeOnboarding: View {
    var store: NativeWorkspaceStore
    let finish: () -> Void
    private enum Step: Int, CaseIterable { case language, school, invite, done }
    @AppStorage(NativeAppLocale.key) private var language = NativeAppLocale.korean
    @State private var step = Step.language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch step {
                case .language: languageStep
                case .school: schoolStep
                case .invite: inviteStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step).transition(.opacity)
        }
        .padding(.horizontal, 24)
        .background(NativeDesktopTheme.bgApp.ignoresSafeArea())
        .font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.text).tint(NativeDesktopTheme.accent)
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
                    Circle().fill(NativeDesktopTheme.text.opacity(item == step ? 1 : 0.18)).frame(width: 8, height: 8)
                }
            }
            .accessibilityElement().accessibilityLabel("\(Step.allCases.count)단계 중 \(step.rawValue + 1)단계").accessibilityIdentifier("native-onboarding-dots")
            HStack {
                if let previous = Step(rawValue: step.rawValue - 1) {
                    Button { step = previous } label: {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .buttonStyle(.plain).bandalGlass(in: Circle()).accessibilityLabel("이전 단계").accessibilityIdentifier("native-onboarding-back")
                }
                Spacer()
                if step != .done {
                    Button(action: finish) {
                        Text("나중에").font(NativeDesktopTheme.font(13, weight: .medium)).padding(.horizontal, 16).frame(height: 44).contentShape(Capsule())
                    }
                    .buttonStyle(.plain).bandalGlass(in: Capsule()).accessibilityLabel("첫 설정 나중에 하기").accessibilityIdentifier("native-onboarding-later")
                }
            }
        }
        .frame(height: 44).padding(.top, 24)
    }

    private func heading(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey?, size: CGFloat = 30) -> some View {
        VStack(spacing: 8) {
            Text(title).font(NativeDesktopTheme.font(size, weight: .bold)).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(NativeDesktopTheme.font(15)).foregroundStyle(NativeDesktopTheme.secondary).multilineTextAlignment(.center) }
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(NativeDesktopTheme.font(15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.onAccent)
                .frame(maxWidth: 280, minHeight: 48)
                .background(NativeDesktopTheme.accent, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    // MARK: Steps

    private var languageStep: some View {
        VStack(spacing: 28) {
            NativeBandalMark(size: 56)
            heading("반달에 오신 걸 환영해요", "어떤 언어로 쓸까요? 설정에서 언제든 바꿀 수 있어요.")
            HStack(spacing: 12) {
                languageCard(NativeAppLocale.korean, glyph: "가", name: "한국어", other: "Korean")
                languageCard(NativeAppLocale.english, glyph: "A", name: "English", other: "영어")
            }
            primaryButton("다음", label: "다음 단계", identifier: "native-onboarding-next") { step = .school }
        }
    }

    /// The language's own name, with the other language's word for it underneath; neither is translated.
    private func languageCard(_ value: String, glyph: String, name: String, other: String) -> some View {
        let on = language == value
        return Button { choose(value) } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    Text(verbatim: glyph).font(.system(size: 34, weight: .semibold))
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
                        .foregroundStyle(on ? NativeDesktopTheme.accent : NativeDesktopTheme.muted.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(NativeDesktopTheme.font(17, weight: .semibold))
                    Text(verbatim: other).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? NativeDesktopTheme.accent : NativeDesktopTheme.border, lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).accessibilityLabel(Text(verbatim: name + " · " + other)).accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("native-onboarding-language-" + value)
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
        // The search field has the keyboard from the start. The list takes the height the keyboard
        // leaves, so the field and the buttons under the list stay on screen on every iPad. Under
        // 320pt (an iPad mini in landscape with the keyboard up) the heading gives up its second line.
        GeometryReader { geometry in
            let tight = geometry.size.height < 320
            VStack(spacing: tight ? 10 : 16) {
                heading("다니는 학교를 알려 주세요", tight ? nil : "학교 사이트 바로가기를 사이드바에 모아 드려요.", size: tight ? 20 : 24)
                // Everything on this step but the list: 190pt when tight, 250pt otherwise.
                NativeSchoolPicker(store: store, maxListHeight: min(420, max(44, geometry.size.height - (tight ? 190 : 250)))) { _ in step = .invite }
                    .padding(BandalMetrics.padding)
                    .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge))
                    .overlay(RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge).strokeBorder(NativeDesktopTheme.border))
            }
            .padding(.top, tight ? 4 : 16).frame(maxWidth: .infinity)
        }
    }

    /// 초대 코드, for someone a friend invited: a code that exists is kept on this iPad and claimed
    /// when they sign in. The field has the keyboard from the start; under 320pt (an iPad mini in
    /// landscape with the keyboard up) the step draws tighter so its button stays on screen.
    private var inviteStep: some View {
        GeometryReader { geometry in
            let tight = geometry.size.height < 320
            VStack(spacing: tight ? 10 : 20) {
                heading("초대 코드가 있나요?", nil, size: tight ? 20 : 30)
                NativeReferralCodeEntry(referral: store.referral, large: true)
                if store.referral.applied {
                    primaryButton("다음", label: "다음 단계", identifier: "native-onboarding-next") { step = .done }
                } else {
                    Button { store.referral.withdraw(); step = .done } label: {
                        Text("없어요, 건너뛰기").font(NativeDesktopTheme.font(15, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                            .frame(maxWidth: 280, minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("native-referral-skip")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 28) {
            NativeBandalMark(size: 56)
            heading("준비됐어요", "언어와 학교는 설정에서 언제든 바꿀 수 있어요.")
            primaryButton("시작하기", label: "반달 시작하기", identifier: "native-onboarding-finish", action: finish)
        }
    }
}

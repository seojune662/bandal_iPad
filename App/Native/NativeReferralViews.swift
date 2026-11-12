import SwiftUI

/// The invitee's code field, the same in onboarding and 설정 › 계정 › 친구 초대: six characters,
/// checked with the server as soon as they are all there. It never asks to sign in. Once the
/// account has claimed a code there is no field, only what became of it. A code that came from an
/// invite link is only shown: a tapped link must not spend the account's one claim by itself.
struct NativeReferralCodeEntry: View {
    var referral: NativeReferral
    /// Onboarding: a large centred field that takes the keyboard.
    var large = false
    @Environment(\.locale) private var locale
    @State private var text = ""
    @State private var entry = NativeReferral.Entry.idle
    @State private var attempt = 0
    /// The code an invite link put in the field, until someone taps 이 코드 적용 or types another.
    @State private var linked: String?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var height: CGFloat { large ? 50 : 44 }

    var body: some View {
        VStack(alignment: large ? .center : .leading, spacing: 8) {
            if referral.awaiting || referral.status?.claim != nil {
                applied(referral.status?.claim?.completed == true ? "코드 적용됨 — AI 100회를 받았어요" : "코드 적용됨 — 로그인하고 첫 폴더를 만들면 AI 100회가 들어와요")
            } else {
                // In onboarding the row is as wide as the button under it.
                HStack(spacing: 8) {
                    field
                    // Made again when the theme changes: the system draws it in the colours it was given.
                    NativeReferralPasteControl { text = Referral.normalize($0) }.frame(height: height).id(colorScheme)
                }.frame(maxWidth: large ? 520 : nil)
                outcome.frame(minHeight: 18)
            }
        }
        .onAppear { text = referral.pending ?? ""; takeLink(); if large { focused = true } }
        .onChange(of: referral.linkedCode) { _, _ in takeLink() }
        // Settled (paid, or nothing was owed): the line that promised the reward goes.
        .onChange(of: referral.applied) { _, applied in if !applied, entry == .applied { entry = .idle } }
        .onChange(of: text) { _, value in
            let code = Referral.normalize(value)
            if code != value { text = code; return }
            // What is on screen is what is kept: an edited code no longer waits.
            if referral.pending != nil, referral.pending != code { referral.withdraw() }
        }
        .task(id: text + " \(attempt)") {
            guard Referral.isCode(text) else { entry = .idle; return }
            guard text != referral.pending else { entry = .applied; return }
            guard text != linked else { entry = .idle; return }
            entry = .checking
            let result = await referral.enter(text)
            if !Task.isCancelled { entry = result }
        }
    }

    /// The code of an invite link takes the field, over one already waiting, and waits there for a tap.
    private func takeLink() {
        guard let code = referral.linkedCode else { return }
        referral.linkedCode = nil; linked = code; text = code
    }

    private var field: some View {
        TextField("", text: $text, prompt: Text("6자리 코드"))
            .font(.system(size: large ? 17 : 15, weight: .semibold, design: .monospaced)).multilineTextAlignment(large ? .center : .leading)
            .textFieldStyle(.plain).keyboardType(.asciiCapable).textInputAutocapitalization(.characters).autocorrectionDisabled()
            .focused($focused)
            .padding(.horizontal, 12).frame(maxWidth: large ? .infinity : 150).frame(height: height)
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: large ? 14 : BandalMetrics.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: large ? 14 : BandalMetrics.radius, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
            .accessibilityLabel("초대 코드").accessibilityIdentifier("native-referral-field")
    }

    @ViewBuilder private var outcome: some View {
        switch entry {
        case .idle:
            if linked == text, linked != nil {
                Button { linked = nil; attempt += 1 } label: { Text("이 코드 적용").frame(minHeight: 44) }
                    .buttonStyle(NativeToolButtonStyle(primary: true)).accessibilityIdentifier("native-referral-apply")
            }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("확인하는 중…") }
                .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
        case .applied: applied("코드 적용됨 — 로그인하고 첫 폴더를 만들면 AI 100회가 들어와요")
        case .invalid: failure(Text("없는 초대 코드예요."))
        case .refused(let error): failure(Text(verbatim: NativeReferral.Notice.refused(error).text(locale)))
        case .unavailable:
            HStack(spacing: 8) {
                failure(Text("코드를 확인하지 못했어요. 연결을 확인해 주세요."))
                Button("다시 확인") { attempt += 1 }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).frame(minHeight: 44).contentShape(Rectangle())
                    .accessibilityIdentifier("native-referral-check-again")
            }
        }
    }

    private func applied(_ line: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            Text(line).multilineTextAlignment(large ? .center : .leading).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("native-referral-applied")
        }.font(.system(size: large ? 14 : 12)).foregroundStyle(NativeDesktopTheme.text)
    }

    private func failure(_ line: Text) -> some View {
        line.font(.system(size: large ? 13 : 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("native-referral-error")
    }
}

/// 붙여넣기: the system's own paste control, as tall as the field beside it. It reads the pasteboard
/// only when tapped, so iOS asks nothing. The label is the system's, in the device's language.
private struct NativeReferralPasteControl: UIViewRepresentable {
    let paste: (String) -> Void

    final class Coordinator: NSObject, UIPasteConfigurationSupporting {
        var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(forAccepting: NSString.self)
        var paste: (String) -> Void = { _ in }
        func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) } }
        func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                guard let text = value as? String else { return }
                DispatchQueue.main.async { self?.paste(text) }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .labelOnly
        configuration.cornerStyle = .fixed; configuration.cornerRadius = BandalMetrics.radius
        configuration.baseBackgroundColor = UIColor(NativeDesktopTheme.raised); configuration.baseForegroundColor = UIColor(NativeDesktopTheme.text)
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.accessibilityIdentifier = "native-referral-paste"
        return control
    }
    func updateUIView(_ control: UIPasteControl, context: Context) { context.coordinator.paste = paste }
}

/// 친구 초대: this account's code to copy or share, how many friends it has brought and what that
/// paid. The profile menu and 설정 › 계정 › 친구 초대 show it in a popover. Signed out it offers
/// sign-in right here and loads once someone is in.
struct NativeReferralInvite: View {
    var store: NativeWorkspaceStore
    /// Off where the screen already says 친구 초대 (onboarding's own heading).
    var showsTitle = true
    @Environment(\.locale) private var locale
    @State private var phase = Phase.loading
    @State private var signInError: String?
    @State private var toast: String?
    private enum Phase { case loading, signIn, failed, loaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle { Text("친구 초대").font(.system(size: BandalMetrics.bodySize, weight: .semibold)).accessibilityAddTraits(.isHeader) }
            if phase == .loaded, let status = store.referral.status { invite(status) }
            else if phase == .signIn { signIn }
            else if phase == .failed {
                HStack {
                    Text("초대 정보를 불러오지 못했어요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityIdentifier("native-referral-failed")
                    Spacer()
                    Button { Task { await load() } } label: { Text("다시 시도").frame(minHeight: 44) }
                        .buttonStyle(NativeToolButtonStyle(compact: true)).accessibilityIdentifier("native-referral-retry")
                }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 88).accessibilityIdentifier("native-referral-loading") }
        }
        .task { await load() }
        // Signed in from the prompt (or out, elsewhere): what is shown follows.
        .onReceive(store.events) { event in if event.channel == "auth:changed" { Task { await load() } } }
        // Beside the title: at the bottom of so small a popover it would cover the rules.
        .overlay(alignment: .topTrailing) { BandalToast(message: $toast) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-referral-invite")
    }

    private func load() async {
        // What is already on screen stays while it is asked for again.
        if store.referral.status == nil { phase = .loading }
        do { phase = try await store.referral.loadStatus() ? .loaded : .signIn }
        catch is CancellationError {} // The account changed meanwhile; its own answer decides what shows.
        catch { phase = .failed }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("로그인하면 내 초대 코드를 받을 수 있어요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).fixedSize(horizontal: false, vertical: true)
            NativeSignInButtons(store: store, error: $signInError, identifierPrefix: "native-referral-sign-in")
            if let signInError { Text(signInError).font(.system(size: 11)).foregroundStyle(.red) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-referral-sign-in-prompt")
    }

    private func invite(_ status: ReferralStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { copy(status.code) } label: {
                HStack {
                    Text(verbatim: status.code).font(.system(size: 26, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer(minLength: 8)
                    Image(systemName: "doc.on.doc").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 56)
                .background(NativeDesktopTheme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: BandalMetrics.radius)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("내 초대 코드 \(status.code) 복사").accessibilityIdentifier("native-referral-code")
            HStack(spacing: 8) {
                Button { copy(Referral.link(status.code)) } label: { Label("링크 복사", systemImage: "link").frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityIdentifier("native-referral-copy-link")
                ShareLink(item: String(format: NativeAppLocale.string("반달에서 같이 공부하자. 초대 코드 %@ 넣으면 둘 다 AI 100회 받아요. https://bandal.io/r/%@", locale), status.code, status.code)) {
                    Label("공유", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityIdentifier("native-referral-share")
            }.buttonStyle(NativeToolButtonStyle())
            Text("초대 \(status.counted) / \(status.limit) · 받은 AI \(Referral.uses(status.creditMicrocents))회")
                .font(.system(size: BandalMetrics.bodySize, weight: .medium)).accessibilityIdentifier("native-referral-count")
            VStack(alignment: .leading, spacing: 2) {
                Text("친구가 로그인하고 첫 폴더를 만들면 둘 다 AI 100회")
                Text("\(status.limit)명까지")
            }.font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        toast = NativeAppLocale.string("복사했어요", locale)
    }
}

/// What the workspace root does for invitations: the toast for a reward or a refused code, and
/// where an invite link's code goes. Onboarding takes it by itself while it shows; otherwise
/// 설정 › 계정 › 친구 초대 opens, once the workspace is there to open it over (`ready`).
struct NativeReferralHost: ViewModifier {
    var referral: NativeReferral
    let ready: Bool
    let openSettings: (String) -> Void
    @Environment(\.locale) private var locale
    func body(content: Content) -> some View {
        content
            .bandalToast(Binding(get: { referral.notice?.text(locale) }, set: { if $0 == nil { referral.notice = nil } }))
            // A universal link arrives through the root's `onOpenURL`; a handed-off page arrives here.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in if let url = activity.webpageURL { referral.open(url) } }
            .onChange(of: ready ? referral.linkedCode : nil, initial: true) { _, code in if code != nil { openSettings("referral") } }
            #if DEBUG
            .task { if let link = Referral.fixtureLink { referral.open(link) } }
            #endif
    }
}

/// The invitee's reminder at the top of the home sidebar, from the moment a code is applied until
/// its reward is settled.
struct NativeReferralBanner: View {
    var store: NativeWorkspaceStore
    @Environment(\.locale) private var locale
    var body: some View {
        if store.referral.applied {
            // With a course already made, a code still waiting on this iPad only needs someone to sign in.
            let needsSignIn = store.referral.pending != nil && store.hasCourse && !store.referral.signedIn
            // Signed in with a course and still waiting: the server could not give the reward yet and is asked again.
            let onItsWay = store.referral.awaiting && store.hasCourse && store.referral.signedIn
            let line = NativeAppLocale.string(needsSignIn ? "로그인하면 AI 100회가 들어와요" : onItsWay ? "곧 AI 100회가 들어와요" : "첫 폴더를 만들면 AI 100회가 들어와요", locale)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "gift").accessibilityHidden(true)
                // One line at the sidebar's usual width. Where it wraps, "AI 100회" stays whole.
                Text(verbatim: line.replacingOccurrences(of: "AI 100회", with: "AI\u{00A0}100\u{2060}회")).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: line)).accessibilityIdentifier("native-referral-banner")
                Spacer(minLength: 0)
            }
            .font(NativeDesktopTheme.font(11, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
            .padding(8)
            .background(NativeDesktopTheme.accentMuted, in: RoundedRectangle(cornerRadius: BandalMetrics.radius))
            .padding(.horizontal, 8).padding(.top, 8)
        }
    }
}

/// 설정 › 계정 › 친구 초대: the invite popover for the one who invites, and the code field for the
/// one who was invited.
struct NativeReferralSettingsCard: View {
    var store: NativeWorkspaceStore
    @Environment(\.locale) private var locale
    @State private var inviting = false
    var body: some View {
        NativeSettingsGroup(title: NativeAppLocale.string("친구 초대", locale)) {
            BandalSettingRow(title: NativeAppLocale.string("친구 초대", locale), note: NativeAppLocale.string("친구가 로그인하고 첫 폴더를 만들면 둘 다 AI 100회", locale)) {
                Button { inviting = true } label: { Text("초대하기").frame(minHeight: 44) }.accessibilityIdentifier("native-referral-settings-open")
                    .bandalPopover(isPresented: $inviting, width: 280) { NativeReferralInvite(store: store) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("초대 코드 입력")
                NativeReferralCodeEntry(referral: store.referral)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("native-referral-settings-entry")
        }
        // Whether this account has already used a code is the server's to say.
        .task { _ = try? await store.referral.loadStatus() }
        .onReceive(store.events) { event in if event.channel == "auth:changed" { Task { _ = try? await store.referral.loadStatus() } } }
    }
}

import SwiftUI

/// The profile button at the bottom of the rail. Signed out it offers sign-in in place; signed in
/// it opens the account menu (Figma 130:5623): email, name · plan, then 설정 / 사용량 / 도움말 › / 플랜 보기 /
/// 로그아웃. 도움말 opens its own card beside the row. 친구 초대 is not in the design: it is a long press on
/// 플랜 보기 (and in 설정 › 계정), and takes the menu's place in the same popover.
struct NativeAccountRailButton: View {
    var store: NativeWorkspaceStore
    let openSettings: (String) -> Void
    let openHelp: () -> Void
    @ObservedObject private var usage = AIUsage.shared
    @ObservedObject private var membership = Membership.shared
    @State private var account: [String: Any] = [:]
    @State private var showingMenu = false
    @State private var showingHelp = false
    @State private var inviting = false
    @Environment(\.locale) private var locale
    @State private var busy = false
    @State private var error: String?

    static let docsURL = URL(string: "https://bandal.io/ko/docs")!
    /// Posted by 처음 사용 안내 다시 보기; the workspace shows onboarding again.
    static let restartOnboarding = Notification.Name("native.onboarding.restart")
    static let contactURL = URL(string: "mailto:hi@bandal.io")!

    private var signedIn: Bool { account["phase"] as? String == "signed-in" }
    private var email: String { account["email"] as? String ?? "" }
    private var profile: [String: Any] { account["profile"] as? [String: Any] ?? [:] }
    private var displayName: String {
        let nickname = (profile["nickname"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !nickname.isEmpty { return nickname }
        if let name = email.split(separator: "@").first, !name.isEmpty { return String(name) }
        return "내 계정"
    }
    /// The server's plan wins (it knows trials); StoreKit fills in before the first answer.
    private var planName: String {
        switch usage.plan {
        case "pro": return usage.trial ? "Pro 체험" : "Pro"
        case "plus": return "Plus"
        default: return membership.tier == .pro ? "Pro" : membership.tier == .plus ? "Plus" : "무료"
        }
    }
    private var avatarURL: URL? { (account["avatarUrl"] as? String).flatMap(URL.init) }

    var body: some View {
        Button { error = nil; showingHelp = false; inviting = false; showingMenu.toggle() } label: {
            // A 36 pt avatar in the rail's 44 pt cell, like every other rail button.
            railAvatar
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(signedIn ? "계정: " + displayName : "로그인").accessibilityIdentifier("native-section-account")
            .help(signedIn ? displayName : "로그인")
            // The card's left edge 34 right of the avatar's middle, its bottom 18 below it. The popover is wider and
            // taller than the card by the room the 도움말 card takes beside it; a tap there closes like one outside.
            .bandalPopover(isPresented: $showingMenu, at: .center, offset: CGSize(width: 34 + (Self.width + Self.helpRoom.width) / 2, height: 24 + Self.helpRoom.height),
                           arrowEdge: .bottom, width: nil, padding: 0, bare: true) {
                (inviting ? AnyView(NativeReferralInvite(store: store)) : signedIn ? AnyView(menu) : AnyView(signInMenu))
                    .padding(signedIn && !inviting ? 8 : BandalMetrics.padding).frame(width: Self.width, alignment: .leading).bandalPopoverSurface()
                    .padding(.trailing, Self.helpRoom.width).padding(.bottom, Self.helpRoom.height)
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { close() } }
                    .overlayPreferenceValue(HelpRowKey.self) { anchor in
                        GeometryReader { proxy in
                            if showingHelp, let anchor {
                                helpCard.offset(x: Self.width + 10, y: proxy[anchor].minY - 7)
                            }
                        }
                    }
            }
            .task(id: store.isReady) { await loadAccount() }
            .onReceive(store.events) { event in
                if event.channel == "auth:changed", let state = event.payload as? [String: Any] {
                    let wasSigningIn = !signedIn
                    account = state
                    // Signed in from 친구 초대: it stays open and shows the code.
                    if wasSigningIn && signedIn && !inviting { showingMenu = false }
                }
            }
    }

    private struct HelpRowKey: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
    }
    private static let width: CGFloat = 276
    /// The 도움말 card: 236 wide, 10 from the menu, and 26 lower than the menu's bottom edge.
    private static let helpRoom = CGSize(width: 246, height: 26)

    private var signInMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("반달 계정").font(.system(size: BandalMetrics.bodySize, weight: .semibold))
            Text("로그인하면 AI와 동기화를 쓸 수 있어요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
            NativeSignInButtons(store: store, error: $error, identifierPrefix: "native-account")
            errorLine
            BandalMenuDivider()
            VStack(spacing: 2) {
                BandalMenuRow(NativeAppLocale.string("친구 초대", locale), symbol: "gift") { inviting = true }.accessibilityIdentifier("native-referral-menu")
                helpRow
            }.padding(-4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-account-menu")
    }

    private var menu: some View {
        let invite = NativeAppLocale.string("친구 초대", locale)
        return VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                if !email.isEmpty { Text(email).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1).truncationMode(.middle).frame(height: 20) }
                Text(displayName + " · " + planName).font(.system(size: 17, weight: .semibold)).foregroundStyle(NativeGlass.icon).lineLimit(1).frame(height: 24)
                    .accessibilityIdentifier("native-account-plan")
            }.padding(.horizontal, 12).padding(.vertical, 10)
            BandalMenuDivider()
            BandalMenuRow("설정", asset: "MenuIconGear") { close(); openSettings("general") }.accessibilityIdentifier("native-account-app-settings")
            if NativeReleaseFlags.membership {
                BandalMenuRow("사용량", asset: "MenuIconBars", detail: usage.percent.map { "이번 달 AI \($0)%" }) { close(); openSettings("subscription") }
                    .accessibilityIdentifier("native-account-usage")
            }
            helpRow
            BandalMenuRow("플랜 보기", asset: "MenuIconSpark") { close(); MembershipPaywall.present() }
                .contextMenu { Button(invite, systemImage: "gift") { inviting = true }.accessibilityIdentifier("native-referral-menu") }
                .accessibilityIdentifier("native-account-plans")
            BandalMenuDivider()
            BandalMenuRow(busy ? "로그아웃 중…" : "로그아웃", asset: "MenuIconLogout") { signOut() }
                .disabled(busy).accessibilityIdentifier("native-account-sign-out")
            errorLine
        }
        .task { _ = try? await store.invokePrivate("native:aiConfig") }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-account-menu")
    }

    /// 도움말 ›: its four lines open in a card of their own beside the row (10 right of the menu, the first line level with the row).
    private var helpRow: some View {
        BandalMenuRow(title: "도움말", asset: "MenuIconHelp", action: { showingHelp.toggle() }) {
            Image("MenuIconChevron").foregroundStyle(NativeDesktopTheme.secondary).frame(width: 16, height: 16)
        }
        .background(showingHelp ? NativeGlass.selection : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("native-account-help")
        .anchorPreference(key: HelpRowKey.self, value: .bounds) { $0 }
    }
    private var helpCard: some View {
        VStack(spacing: 2) {
            helpLine("처음 사용 안내 다시 보기", "native-help-onboarding") { NotificationCenter.default.post(name: Self.restartOnboarding, object: nil) }
            helpLine("펜슬·손가락 사용법", "native-help-guide", action: openHelp)
            helpLine("단축키", "native-help-shortcuts") { openSettings("shortcuts") }
            helpLine("문의하기 · 버그 신고", "native-help-contact") { UIApplication.shared.open(Self.contactURL) }
        }.padding(8).frame(width: 236).foregroundStyle(NativeDesktopTheme.text).bandalPopoverSurface(radius: 18)
    }
    private func helpLine(_ title: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button { close(); action() } label: {
            BandalText(title).font(.system(size: 15)).foregroundStyle(NativeGlass.icon).lineLimit(1)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 41, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(BandalRowStyle(radius: 10)).accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var errorLine: some View {
        if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 8).fixedSize(horizontal: false, vertical: true) }
    }

    private func close() { showingMenu = false; showingHelp = false }

    private func loadAccount() async {
        guard store.isReady else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-account-fixture") {
            account = ["phase": "signed-in", "email": "seojun@bandal.io", "profile": ["nickname": "서준", "avatarEmoji": "🌙"]]; return
        }
        #endif
        account = (try? await store.invoke("auth:getState")) as? [String: Any] ?? [:]
    }

    /// The rail shows the account as a plain 26 pt disc; a profile photo fills it.
    private var railAvatar: some View {
        Circle().fill(Color(red: 0x3e / 255, green: 0x8e / 255, blue: 0x9a / 255)).frame(width: 26, height: 26)
            .overlay { if signedIn, let avatarURL { AsyncImage(url: avatarURL) { $0.image?.resizable().scaledToFill() }.frame(width: 26, height: 26).clipShape(Circle()) } }
    }
    private func signOut() {
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { _ = try await store.invoke("auth:signOut"); close() }
            catch { self.error = "로그아웃하지 못했어요. 다시 시도해 주세요." }
        }
    }
}

/// Apple / Google sign-in, used by the profile popover, the AI sign-in prompt and Settings.
/// The provider's own sheet (ASWebAuthenticationSession, Sign in with Apple) takes it from there.
struct NativeSignInButtons: View {
    var store: NativeWorkspaceStore
    @Binding var error: String?
    var identifierPrefix = "native-sign-in"
    @State private var busy: String?
    var body: some View {
        VStack(spacing: 6) {
            button("Apple로 로그인", symbol: "apple.logo", provider: "apple")
            button("Google로 로그인", symbol: "g.circle", provider: "google")
        }
    }
    private func button(_ title: String, symbol: String, provider: String) -> some View {
        Button { signIn(provider) } label: {
            HStack(spacing: 8) {
                if busy == provider { ProgressView().controlSize(.small) } else { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title)
            }.font(.system(size: BandalMetrics.bodySize, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(provider == "apple" ? NativeDesktopTheme.accent : NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
                .foregroundStyle(provider == "apple" ? NativeDesktopTheme.onAccent : NativeDesktopTheme.text)
        }.buttonStyle(.plain).disabled(busy != nil).accessibilityLabel(title).accessibilityIdentifier("\(identifierPrefix)-\(provider)")
    }
    private func signIn(_ provider: String) {
        busy = provider; error = nil
        Task { @MainActor in
            defer { busy = nil }
            do {
                let result = try await store.invoke("auth:signIn", ["provider": provider]) as? [String: Any]
                guard result?["ok"] as? Bool != true else { return }
                switch result?["reason"] as? String {
                case "already-signed-in": break
                case "provider": error = "다른 로그인이 진행 중이에요. 잠시 뒤 다시 해 주세요."
                default: error = "지금은 로그인할 수 없어요. 연결을 확인해 주세요."
                }
            } catch { self.error = "로그인하지 못했어요. 다시 시도해 주세요." }
        }
    }
}

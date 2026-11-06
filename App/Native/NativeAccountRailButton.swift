import SwiftUI

/// The profile button at the bottom of the rail. Signed out it offers sign-in in place; signed in
/// it opens the account menu: email, name · plan, then 설정 / 사용량 / 도움말 / 플랜 보기 / 로그아웃.
struct NativeAccountRailButton: View {
    var store: NativeWorkspaceStore
    let openSettings: (String) -> Void
    let openHelp: () -> Void
    @ObservedObject private var usage = AIUsage.shared
    @ObservedObject private var membership = Membership.shared
    @State private var account: [String: Any] = [:]
    @State private var showingMenu = false
    @State private var showingHelp = false
    @State private var busy = false
    @State private var error: String?

    static let docsURL = URL(string: "https://bandal.io/ko/docs")!
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
        Button { error = nil; showingHelp = false; showingMenu.toggle() } label: {
            avatar(size: 26)
                .frame(width: 36, height: 36)
                .background(showingMenu ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(signedIn ? "계정: " + displayName : "로그인").accessibilityIdentifier("native-section-account")
            .help(signedIn ? displayName : "로그인")
            .bandalPopover(isPresented: $showingMenu, arrowEdge: .leading, width: 264) { signedIn ? AnyView(menu) : AnyView(signInMenu) }
            .task(id: store.isReady) { await loadAccount() }
            .onReceive(store.events) { event in
                if event.channel == "auth:changed", let state = event.payload as? [String: Any] {
                    let wasSigningIn = !signedIn
                    account = state
                    if wasSigningIn && signedIn { showingMenu = false }
                }
            }
    }

    private var signInMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("반달 계정").font(.system(size: BandalMetrics.bodySize, weight: .semibold))
            Text("로그인하면 AI와 동기화를 쓸 수 있어요.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
            NativeSignInButtons(store: store, error: $error, identifierPrefix: "native-account")
            errorLine
            BandalMenuDivider()
            BandalMenu { helpRows }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-account-menu")
    }

    private var menu: some View {
        BandalMenu {
            VStack(alignment: .leading, spacing: 2) {
                if !email.isEmpty { Text(email).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1).truncationMode(.middle) }
                Text(displayName + " · " + planName).font(.system(size: BandalMetrics.bodySize, weight: .semibold)).lineLimit(1)
                    .accessibilityIdentifier("native-account-plan")
            }.padding(.horizontal, 8).padding(.vertical, 6)
            BandalMenuDivider()
            BandalMenuRow("설정", symbol: "gearshape") { close(); openSettings("general") }.accessibilityIdentifier("native-account-app-settings")
            if NativeReleaseFlags.membership {
                BandalMenuRow("사용량", symbol: "chart.bar", detail: usage.percent.map { "이번 달 AI \($0)%" }) { close(); openSettings("subscription") }
                    .accessibilityIdentifier("native-account-usage")
            }
            helpRows
            BandalMenuRow("플랜 보기", symbol: "sparkles") { close(); MembershipPaywall.present(message: nil, variant: membership.tier == .plus ? .upgrade : .all) }
                .accessibilityIdentifier("native-account-plans")
            BandalMenuDivider()
            BandalMenuRow(busy ? "로그아웃 중…" : "로그아웃", symbol: "rectangle.portrait.and.arrow.right") { signOut() }
                .disabled(busy).accessibilityIdentifier("native-account-sign-out")
            errorLine
        }
        .task { _ = try? await store.invokePrivate("native:aiConfig") }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-account-menu")
    }

    /// 도움말 opens in place: 화면 도우미 / 문서 / 문의하기.
    @ViewBuilder private var helpRows: some View {
        BandalMenuRow(title: "도움말", symbol: "questionmark.circle", action: { showingHelp.toggle() }) {
            Image(systemName: showingHelp ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(NativeDesktopTheme.muted)
        }.accessibilityIdentifier("native-account-help")
        if showingHelp {
            Group {
                BandalMenuRow("화면 도우미", symbol: "rectangle.and.hand.point.up.left") { close(); openHelp() }.accessibilityIdentifier("native-help-guide")
                BandalMenuRow("문서", symbol: "book") { close(); UIApplication.shared.open(Self.docsURL) }.accessibilityIdentifier("native-help-docs")
                BandalMenuRow("문의하기", symbol: "bubble.left") { close(); UIApplication.shared.open(Self.contactURL) }.accessibilityIdentifier("native-help-contact")
            }.padding(.leading, 16)
        }
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

    @ViewBuilder private func avatar(size: CGFloat) -> some View {
        if signedIn, let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { emoji(size) }
            }.frame(width: size, height: size).clipShape(Circle()).overlay(Circle().stroke(NativeDesktopTheme.border, lineWidth: 1))
        } else if signedIn {
            emoji(size)
        } else {
            Image(systemName: "person.crop.circle").font(.system(size: 16, weight: .regular)).foregroundStyle(NativeDesktopTheme.muted)
        }
    }
    /// The profile's emoji avatar (default 🌙) marks a signed-in session without a photo.
    private func emoji(_ size: CGFloat) -> some View {
        Text(profile["avatarEmoji"] as? String ?? "🌙").font(.system(size: size * 0.55))
            .frame(width: size, height: size).background(NativeDesktopTheme.raised, in: Circle())
            .overlay(Circle().stroke(NativeDesktopTheme.border, lineWidth: 1))
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

import SwiftUI

/// Desktop parity for `SidebarAccountEntry`: the rail shows the account avatar
/// and opens a popover with name · email, 계정 설정, 앱 설정 and 로그아웃.
/// Signed out, it is the plain 계정 icon that opens the account page.
struct NativeAccountRailButton: View {
    @ObservedObject var store: NativeWorkspaceStore
    var selected = false
    let openAccount: () -> Void
    let openSettings: () -> Void
    @State private var account: [String: Any] = [:]
    @State private var showingMenu = false
    @State private var signingOut = false
    @State private var error: String?

    private var signedIn: Bool { account["phase"] as? String == "signed-in" }
    private var email: String { account["email"] as? String ?? "" }
    private var profile: [String: Any] { account["profile"] as? [String: Any] ?? [:] }
    private var displayName: String {
        let nickname = (profile["nickname"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !nickname.isEmpty { return nickname }
        if let name = email.split(separator: "@").first, !name.isEmpty { return String(name) }
        return "내 계정"
    }
    private var avatarURL: URL? { (account["avatarUrl"] as? String).flatMap(URL.init) }

    var body: some View {
        Button {
            if signedIn { showingMenu.toggle() } else { openAccount() }
        } label: {
            avatar(size: 26)
                .frame(width: 36, height: 36)
                .background(selected || showingMenu ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(signedIn ? "계정: " + displayName : "계정").accessibilityIdentifier("native-section-account")
            .help(signedIn ? displayName : "계정")
            .popover(isPresented: $showingMenu, arrowEdge: .leading) { menu.presentationCompactAdaptation(.popover) }
            .task(id: store.isReady) { if store.isReady { account = (try? await store.invoke("auth:getState")) as? [String: Any] ?? [:] } }
            .onReceive(store.events) { event in
                if event.channel == "auth:changed", let state = event.payload as? [String: Any] { account = state }
            }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                avatar(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if !email.isEmpty {
                        Text(email).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            item("계정 설정", symbol: "person") { showingMenu = false; openAccount() }.accessibilityIdentifier("native-account-settings")
            item("앱 설정", symbol: "gearshape") { showingMenu = false; openSettings() }.accessibilityIdentifier("native-account-app-settings")
            Divider()
            item(signingOut ? "로그아웃 중…" : "로그아웃", symbol: "rectangle.portrait.and.arrow.right") { signOut() }
                .disabled(signingOut).accessibilityIdentifier("native-account-sign-out")
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 10)
            }
        }.frame(width: 272).foregroundStyle(NativeDesktopTheme.text)
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-account-menu")
    }
    private func item(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func avatar(size: CGFloat) -> some View {
        if signedIn, let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { emoji(size) }
            }.frame(width: size, height: size).clipShape(Circle()).overlay(Circle().stroke(NativeDesktopTheme.border, lineWidth: 1))
        } else if signedIn {
            emoji(size)
        } else {
            Image(systemName: "person.crop.circle").font(.system(size: 16, weight: .regular))
                .foregroundStyle(selected ? NativeDesktopTheme.text : NativeDesktopTheme.muted)
        }
    }
    /// The profile's emoji avatar (default 🌙) marks a signed-in session without a photo.
    private func emoji(_ size: CGFloat) -> some View {
        Text(profile["avatarEmoji"] as? String ?? "🌙").font(.system(size: size * 0.55))
            .frame(width: size, height: size).background(NativeDesktopTheme.raised, in: Circle())
            .overlay(Circle().stroke(NativeDesktopTheme.border, lineWidth: 1))
    }
    private func signOut() {
        signingOut = true; error = nil
        Task { @MainActor in
            defer { signingOut = false }
            do { _ = try await store.invoke("auth:signOut"); showingMenu = false }
            catch { self.error = "로그아웃하지 못했어요. 다시 시도해 주세요." }
        }
    }
}

import SwiftUI

/// Chrome-style "save password?" and "which account?" prompts. Only metadata
/// (origin, username) is held here; passwords stay in the native page/Keychain.
struct NativeBrowserLoginPrompt: Equatable {
    let origin: String
    let username: String
    let update: Bool
}

struct NativeBrowserLoginAccount: Identifiable, Equatable {
    let id: String
    let username: String
}

struct NativeBrowserLoginChoices: Equatable {
    let guestID: Int
    let origin: String
    let accounts: [NativeBrowserLoginAccount]
}

@MainActor
extension NativeBrowserSession {
    func receiveLoginEvent(_ event: NativeWorkspaceEvent) {
        guard let value = event.payload as? [String: Any], let id = value["tabId"] as? String, owns(id) else { return }
        if event.channel == "browser:login-offer" {
            Task {
                do {
                    let result = try await store.invoke("credentials:reviewOffer", ["tabId": id]) as? [String: Any]
                    guard let result, let origin = result["origin"] as? String, let username = result["username"] as? String else { loginPrompts[id] = nil; return }
                    loginPrompts[id] = .init(origin: origin, username: username, update: result["update"] as? Bool == true)
                } catch { self.error = error.localizedDescription }
            }
            return
        }
        guard event.channel == "browser:page-event", let name = value["name"] as? String else { return }
        if name == "did-start-navigation" { loginChoices[id] = nil }
        guard name == "did-finish-load", tabs.first(where: { $0.id == id })?.isPrivate == false else { return }
        Task {
            guard let result = try? await store.invoke("credentials:autofill", ["tabId": id]) as? [String: Any],
                  let guest = result["guestWebContentsId"] as? Int, let origin = result["origin"] as? String else { return }
            let accounts = (result["accounts"] as? [[String: Any]] ?? []).compactMap { row -> NativeBrowserLoginAccount? in
                guard let id = row["id"] as? String, let username = row["username"] as? String else { return nil }
                return .init(id: id, username: username)
            }
            loginChoices[id] = accounts.isEmpty ? nil : .init(guestID: guest, origin: origin, accounts: accounts)
        }
    }
    func resolveLoginPrompt(_ id: String, decision: String) async throws {
        loginPrompts[id] = nil
        _ = try await store.invoke("credentials:resolveOffer", ["tabId": id, "decision": decision])
    }
    func fillLogin(_ id: String, account: NativeBrowserLoginAccount) async throws {
        guard let choices = loginChoices[id] else { return }
        loginChoices[id] = nil
        let result = try await store.invoke("credentials:fill", ["guestWebContentsId": choices.guestID, "origin": choices.origin, "credentialId": account.id, "autoSubmit": false]) as? [String: Bool]
        if result?["filled"] != true { error = "현재 페이지에서 로그인 입력란을 찾지 못했습니다." }
    }
}

struct NativeBrowserLoginBar: View {
    @ObservedObject var session: NativeBrowserSession
    let perform: (@escaping @MainActor () async throws -> Void) -> Void
    var body: some View {
        if let id = session.activeID {
            if let prompt = session.loginPrompts[id] { save(prompt, id: id) }
            else if let choices = session.loginChoices[id] { pick(choices, id: id) }
        }
    }
    private func save(_ prompt: NativeBrowserLoginPrompt, id: String) -> some View {
        bar {
            Image(systemName: "key.fill").foregroundStyle(NativeDesktopTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.update ? "저장된 비밀번호를 업데이트할까요?" : "비밀번호를 저장할까요?").font(NativeDesktopTheme.font(13).weight(.semibold))
                Text(prompt.username + " · " + (URL(string: prompt.origin)?.host ?? prompt.origin)).font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("이 사이트에서 안 함") { perform { try await session.resolveLoginPrompt(id, decision: "never") } }
                .buttonStyle(NativeToolButtonStyle()).accessibilityIdentifier("native-browser-login-never")
            Button("나중에") { perform { try await session.resolveLoginPrompt(id, decision: "dismiss") } }
                .buttonStyle(NativeToolButtonStyle()).accessibilityIdentifier("native-browser-login-dismiss")
            Button(prompt.update ? "업데이트" : "저장") { perform { try await session.resolveLoginPrompt(id, decision: "save") } }
                .buttonStyle(NativeToolButtonStyle(primary: true)).accessibilityIdentifier("native-browser-login-save")
        }
    }
    private func pick(_ choices: NativeBrowserLoginChoices, id: String) -> some View {
        bar {
            Image(systemName: "key").foregroundStyle(NativeDesktopTheme.secondary)
            Text("저장된 로그인").font(NativeDesktopTheme.font(13).weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(choices.accounts) { account in
                        Button(account.username) { perform { try await session.fillLogin(id, account: account) } }.buttonStyle(NativeToolButtonStyle())
                    }
                }
            }
            Button("닫기", systemImage: "xmark") { session.loginChoices[id] = nil }.labelStyle(.iconOnly).buttonStyle(NativeBrowserIconStyle())
        }
    }
    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 12).frame(minHeight: 48)
            .background(NativeDesktopTheme.surface)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

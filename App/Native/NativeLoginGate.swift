import SwiftUI

/// Local files unlock only for the account bound to this profile. The gate is
/// driven by `auth:changed`; it never reads tokens or decides access itself.
struct NativeLoginGate: View {
    @ObservedObject var store: NativeWorkspaceStore
    @State private var account: [String: Any] = [:]
    @State private var busy = false
    @State private var message: String?

    static func requiresLogin(_ state: [String: Any]) -> Bool {
        guard state["phase"] as? String != "unconfigured" else { return false }
        return (state["localAccess"] as? [String: Any])?["requiresLogin"] as? Bool == true
    }
    private var access: [String: Any] { account["localAccess"] as? [String: Any] ?? [:] }
    private var pendingUserID: String? { access["pendingUserID"] as? String }
    private var signingIn: Bool { account["phase"] as? String == "signing-in" || busy }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.stars.fill").font(.system(size: 56)).foregroundStyle(NativeDesktopTheme.muted)
            Text("반달 계정으로 시작").font(NativeDesktopTheme.font(22, weight: .semibold))
            if access["requiresBindingConfirmation"] as? Bool == true {
                Text("이 기기에 이미 자료가 있습니다. 지금 로그인한 계정에 연결할까요? 연결 후에는 이 계정으로만 이 자료를 열 수 있습니다.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                Button("이 계정에 자료 연결") { run { _ = try await store.invoke("auth:confirmProfile", ["userID": pendingUserID ?? ""]) } }
                    .buttonStyle(.borderedProminent).disabled(busy)
                Button("다른 계정으로 로그인") { run { _ = try await store.invoke("auth:signOut") } }.disabled(busy)
            } else {
                Text(account["errorCode"] as? String == "reauthentication-required" ? "안전을 위해 다시 로그인해 주세요." : NativeReleaseFlags.isLocalOnly ? "이 자료는 계정에 연결되어 있어요. 로그인하면 이 기기의 자료를 열 수 있어요." : "로그인하면 이 기기의 자료를 열고 다른 기기와 동기화할 수 있어요.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                VStack(spacing: 10) {
                    Button("Apple로 로그인") { signIn("apple") }
                    Button("Google로 로그인") { signIn("google") }
                    Button("카카오로 로그인") { signIn("kakao") }
                }.buttonStyle(.borderedProminent).disabled(signingIn)
                if signingIn { ProgressView() }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 420) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativeDesktopTheme.surface)
        .task { await reload() }
        .onReceive(store.events) { event in
            if event.channel == "auth:changed", let state = event.payload as? [String: Any] { account = state }
        }
    }
    private func reload() async { account = (try? await store.invoke("auth:getState")) as? [String: Any] ?? [:] }
    private func signIn(_ provider: String) {
        run {
            let result = try await store.invoke("auth:signIn", ["provider": provider]) as? [String: Any]
            guard result?["ok"] as? Bool == true else {
                throw DesktopRuntimeError(result?["reason"] as? String == "not-configured" ? "동기화 서버 설정이 없어 로그인할 수 없습니다." : "로그인을 시작하지 못했습니다. 연결을 확인하고 다시 시도하세요.")
            }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action(); await reload() } catch { message = error.localizedDescription }
        }
    }
}

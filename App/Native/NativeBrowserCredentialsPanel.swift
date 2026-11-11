import SwiftUI

struct NativeBrowserCredentialContext: Identifiable {
    let id = UUID()
    let target: DesktopCredentialTarget
}

/// Only metadata enters this view. Capture and fill remain in the engine's
/// isolated world, bound to the exact page generation and Keychain profile.
struct NativeBrowserCredentialsPanel: View {
    @ObservedObject var session: NativeBrowserSession
    let context: NativeBrowserCredentialContext
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [[String: Any]] = []
    @State private var staged: [String: Any]?
    @State private var confirmation = false
    @State private var busy = false
    @State private var available = false
    @State private var message: String?
    @State private var failure: String?
    private var target: DesktopCredentialTarget { context.target }
    private var request: [String: Any] { ["guestWebContentsId": target.guestID, "origin": target.origin] }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BandalSectionHeader("로그인 관리")
            Text(target.origin).font(.system(size: BandalMetrics.bodySize, weight: .semibold)).textSelection(.enabled).lineLimit(1)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(.red) }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted) }
            if entries.isEmpty { Text("이 사이트에 저장된 로그인이 없어요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted) }
            ForEach(entries.indices, id: \.self) { index in
                if let id = entries[index]["id"] as? String {
                    BandalMenuRow(title: entries[index]["username"] as? String ?? "계정", symbol: "key", action: { run { try await fill(id) } }) {
                        Button("로그인 삭제", systemImage: "trash", role: .destructive) { run { try await forget(id) } }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.red)
                    }
                }
            }
            BandalMenuDivider()
            if let staged {
                // Saving asks once, here: the username and the two choices.
                Text("이 로그인을 저장할까요? " + (staged["username"] as? String ?? "")).font(.system(size: 12))
                HStack {
                    Button("저장 안 함") { run { await discard() } }.buttonStyle(.plain).font(.system(size: 12))
                    Spacer()
                    Button("저장") { run { try await commit() } }.font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("native-browser-save-login-confirm")
                }
            } else {
                BandalMenuRow("이 페이지의 로그인 저장", symbol: "key.fill", detail: "직접 입력한 로그인만 키체인에 저장해요") { run { try await stage() } }
                    .disabled(!available).accessibilityIdentifier("native-browser-save-login")
            }
        }
        .disabled(busy)
        .task { run { try await load() } }
        .onDisappear { if staged != nil { run { await discard() } } }
    }
    private func validate() throws {
        guard session.activeID == target.tabID, !session.retired,
              try session.host.credentialTarget(guestID: target.guestID, origin: target.origin) == target else {
            throw DesktopRuntimeError("로그인 페이지가 변경되었습니다. 창을 닫고 현재 페이지에서 다시 시도하세요.")
        }
    }
    private func load() async throws {
        try validate()
        let status = try await session.store.invoke("credentials:availability", ["profileId": target.profileID]) as? [String: Any]
        try validate(); available = status?["state"] as? String == "ready"
        guard available else { throw DesktopRuntimeError(status?["reason"] as? String ?? "기기의 로그인 저장소를 사용할 수 없습니다.") }
        let result = try await session.store.invoke("credentials:list", ["profileId": target.profileID]) as? [[String: Any]] ?? []
        try validate(); entries = result.filter { $0["origin"] as? String == target.origin }
    }
    private func stage() async throws {
        try validate(); var parameters = request; parameters["mode"] = "stage"
        let result = try await session.store.invoke("credentials:capture", parameters) as? [String: Any]
        try validate()
        guard let result else { message = "최근 직접 입력한 새 로그인을 찾지 못했습니다. 사이트의 아이디와 비밀번호를 입력한 후 다시 선택하세요."; return }
        staged = result; confirmation = true; message = nil
    }
    private func commit() async throws {
        try validate(); var parameters = request; parameters["mode"] = "commit"
        let result = try await session.store.invoke("credentials:capture", parameters)
        staged = nil
        guard !(result is NSNull) else { throw DesktopRuntimeError("로그인 확인 시간이 만료되었거나 페이지가 바뀌었습니다. 다시 저장해 주세요.") }
        message = "로그인을 저장했습니다."; try await load()
    }
    private func discard() async {
        var parameters = request; parameters["mode"] = "discard"
        _ = try? await session.store.invoke("credentials:capture", parameters); staged = nil
    }
    private func fill(_ id: String) async throws {
        try validate(); var parameters = request; parameters["credentialId"] = id; parameters["autoSubmit"] = false
        let result = try await session.store.invoke("credentials:fill", parameters) as? [String: Bool]
        try validate()
        guard result?["filled"] == true else { throw DesktopRuntimeError("현재 페이지에서 로그인 입력란을 찾지 못했습니다.") }
        dismiss()
    }
    private func forget(_ id: String) async throws {
        try validate()
        _ = try await session.store.invoke("credentials:forget", ["profileId": target.profileID, "origin": target.origin, "credentialId": id])
        try await load()
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; failure = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { await discard(); failure = error.localizedDescription }
        }
    }
}

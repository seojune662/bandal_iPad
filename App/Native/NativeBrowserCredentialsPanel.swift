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
        NavigationStack {
            List {
                Section {
                    Text(target.origin).font(.headline).textSelection(.enabled)
                    Text("현재 사이트와 프로필에 저장된 로그인만 표시합니다.").font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
                Section("저장된 로그인 채우기") {
                    if entries.isEmpty { Text("이 사이트에 저장된 로그인이 없습니다.").foregroundStyle(.secondary) }
                    ForEach(entries.indices, id: \.self) { index in
                        if let id = entries[index]["id"] as? String {
                            HStack {
                                Button { run { try await fill(id) } } label: { Label(entries[index]["username"] as? String ?? "계정", systemImage: "key") }
                                Spacer()
                                Button("로그인 삭제", systemImage: "trash", role: .destructive) { run { try await forget(id) } }.labelStyle(.iconOnly)
                            }.frame(minHeight: 44)
                        }
                    }
                }
                Section {
                    Button("이 페이지의 로그인 저장", systemImage: "key.fill") { run { try await stage() } }
                        .disabled(!available).accessibilityIdentifier("native-browser-save-login")
                } footer: { Text("웹사이트에서 직접 입력한 로그인만 확인 후 기기의 키체인에 저장합니다. 채우기를 눌러도 로그인 버튼을 자동으로 누르지 않습니다.") }
            }.disabled(busy).navigationTitle("로그인 관리").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { run { await discard(); dismiss() } }.disabled(busy) } }
                .task { run { try await load() } }
                .interactiveDismissDisabled(busy || staged != nil)
                .alert("이 로그인을 저장할까요?", isPresented: $confirmation) {
                    Button("취소", role: .cancel) { run { await discard() } }
                    Button("저장") { run { try await commit() } }
                } message: { Text(target.origin + "\n" + (staged?["username"] as? String ?? "")) }
        }
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

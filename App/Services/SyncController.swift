import SwiftUI
import BandalCore
import UniformTypeIdentifiers
import CryptoKit
import Security
import PDFKit

struct CloudSession: Codable {
    var access_token: String
    var refresh_token: String
    var expires_at: Double?
    var user: CloudUser
}
struct CloudUser: Codable { var id: String; var email: String? }

/// Isolates authentication effects so delayed responses can be tested without
/// touching an actual account, Keychain item, or authentication browser.
struct SyncAuthenticationEnvironment {
    var configuration: () -> (url: String, key: String) = {
        (UserDefaults.standard.string(forKey: "sync.url") ?? "", UserDefaults.standard.string(forKey: "sync.publishableKey") ?? "")
    }
    var readCredential: () -> String? = { KeychainStore.read("sync.session") }
    var writeCredential: (String) throws -> Void = { try KeychainStore.write($0, account: "sync.session") }
    var request: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    var openOAuth: ((URL) async throws -> URL)?
}

@MainActor
final class SyncController: ObservableObject {
    @Published var status = "연결되지 않음"
    @Published var email: String?
    @Published var busy = false
    @Published var conflicts: [SyncConflict] = []
    private weak var model: AppModel?
    private var session: CloudSession?
    private var engine: SyncEngine?
    private var uploaded = Set<String>()
    private var generation = 0
    private var activeOperation: UUID?
    private var refresh: (id: UUID, generation: Int, task: Task<CloudSession, Error>)?
    private let authentication: SyncAuthenticationEnvironment
    private struct AuthContext { let generation: Int; let url: String; let key: String }
    var projectURL: String { authentication.configuration().url }
    var publishableKey: String { authentication.configuration().key }
    init(model: AppModel, authentication: SyncAuthenticationEnvironment = SyncAuthenticationEnvironment()) {
        self.model = model; self.authentication = authentication
        if let raw = authentication.readCredential(), let value = try? JSONDecoder().decode(CloudSession.self, from: Data(raw.utf8)) { session = value; email = value.user.email; status = "연결됨" }
    }
    private func beginOperation() throws -> UUID {
        guard !busy else { throw AIError.message("진행 중인 로그인 또는 동기화가 끝난 뒤 다시 시도해 주세요.") }
        let operation = UUID(); activeOperation = operation; busy = true; return operation
    }
    private func finishOperation(_ operation: UUID) {
        guard activeOperation == operation else { return }
        activeOperation = nil; busy = false
    }
    private func authContext() -> AuthContext {
        let configuration = authentication.configuration()
        return AuthContext(generation: generation, url: configuration.url, key: configuration.key)
    }
    private func validate(_ context: AuthContext) throws {
        try Task.checkCancellation()
        guard context.generation == generation, context.url == projectURL, context.key == publishableKey else { throw CancellationError() }
    }
    func signIn(email: String, password: String) async throws {
        let operation = try beginOperation(), context = authContext(); defer { finishOperation(operation) }
        let data = try await auth(path: "token?grant_type=password", body: ["email": email, "password": password], context: context)
        try await accept(try JSONDecoder().decode(CloudSession.self, from: data), context: context)
    }
    func signIn(provider: String) async throws {
        guard ["google", "kakao"].contains(provider) else { throw AIError.message("지원하지 않는 로그인 서비스입니다.") }
        let operation = try beginOperation(), context = authContext(); defer { finishOperation(operation) }
        guard var url = URLComponents(string: context.url), url.scheme == "https", url.host != nil, !context.key.isEmpty else { throw AIError.message("동기화 서버 설정이 필요합니다.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AIError.message("안전한 로그인 요청을 만들 수 없습니다.") }
        let verifier = bytes.map { String(format: "%02x", $0) }.joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        url.path = "/auth/v1/authorize"
        url.queryItems = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "redirect_to", value: "bandal://auth/callback"), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "s256")]
        guard let endpoint = url.url else { throw AIError.message("로그인 주소를 확인해 주세요.") }
        let callback: URL
        if let open = authentication.openOAuth { callback = try await open(endpoint) }
        else { let browser = OAuthSession(); callback = try await browser.open(endpoint) }
        try validate(context)
        guard callback.scheme == "bandal", callback.host == "auth", callback.path == "/callback", let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), let code = parts.queryItems?.first(where: { $0.name == "code" })?.value else { throw AIError.message("로그인이 완료되지 않았습니다.") }
        let data = try await auth(path: "token?grant_type=pkce", body: ["auth_code": code, "code_verifier": verifier], context: context)
        try await accept(try JSONDecoder().decode(CloudSession.self, from: data), context: context)
    }
    func sendCode(email: String) async throws {
        let operation = try beginOperation(), context = authContext(); defer { finishOperation(operation) }
        _ = try await auth(path: "otp", body: ["email": email, "create_user": true], context: context)
        try validate(context); status = "이메일에서 인증 코드를 확인해 주세요"
    }
    func verifyCode(email: String, code: String) async throws {
        let operation = try beginOperation(), context = authContext(); defer { finishOperation(operation) }
        let data = try await auth(path: "verify", body: ["email": email, "token": code, "type": "email"], context: context)
        try await accept(try JSONDecoder().decode(CloudSession.self, from: data), context: context)
    }
    private func accept(_ value: CloudSession, context: AuthContext) async throws {
        try validate(context)
        guard UUID(uuidString: value.user.id) != nil, !value.access_token.isEmpty, !value.refresh_token.isEmpty else { throw AIError.message("로그인 응답을 확인할 수 없습니다.") }
        guard let model, let store = model.store else { throw AIError.message("저장소가 준비되지 않아 로그인할 수 없습니다.") }
        let boundAccount = try await store.syncAccount()
        try validate(context)
        guard boundAccount == nil || boundAccount?.lowercased() == value.user.id.lowercased() else { throw AIError.message("이 기기의 자료는 다른 계정에 연결되어 있습니다. 기존 계정으로 로그인해 주세요.") }
        try saveSession(value); email = value.user.email; status = "연결됨"; generation += 1
    }
    private func saveSession(_ value: CloudSession) throws {
        let data = try JSONEncoder().encode(value)
        try authentication.writeCredential(String(decoding: data, as: UTF8.self)); session = value
    }
    func signOut() async {
        generation += 1
        let oldEngine = engine
        engine = nil; session = nil; email = nil; uploaded.removeAll(); conflicts = []
        refresh?.task.cancel(); refresh = nil; activeOperation = nil; busy = false
        try? authentication.writeCredential(""); status = "연결되지 않음"; model?.syncStatus = "기기에 저장됨"
        // Clear state before suspension: a new login may start while the old
        // engine is cancelling, and must not be erased by this completion.
        await oldEngine?.cancel()
    }
    private func token(expectedGeneration: Int? = nil) async throws -> String {
        guard expectedGeneration == nil || expectedGeneration == generation else { throw CancellationError() }
        guard let session else { throw AIError.message("동기화 로그인이 필요합니다.") }
        let context = authContext()
        guard (session.expires_at ?? 0) < Date().timeIntervalSince1970 + 90 else { return session.access_token }
        let pending: (id: UUID, generation: Int, task: Task<CloudSession, Error>)
        if let refresh, refresh.generation == context.generation { pending = refresh }
        else {
            let task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                let data = try await self.auth(path: "token?grant_type=refresh_token", body: ["refresh_token": session.refresh_token], context: context)
                let value = try JSONDecoder().decode(CloudSession.self, from: data)
                guard value.user.id.lowercased() == session.user.id.lowercased(), !value.access_token.isEmpty, !value.refresh_token.isEmpty else { throw AIError.message("로그인 계정이 변경되었거나 응답을 확인할 수 없습니다. 다시 로그인해 주세요.") }
                return value
            }
            pending = (UUID(), context.generation, task); refresh = pending
        }
        defer { if refresh?.id == pending.id { refresh = nil } }
        let value = try await pending.task.value
        try validate(context); try saveSession(value)
        return value.access_token
    }
    private func auth(path: String, body: [String: Any], context: AuthContext) async throws -> Data {
        try validate(context)
        guard var url = URLComponents(string: context.url), url.scheme == "https", url.host != nil, !context.key.isEmpty else { throw AIError.message("동기화 서버 URL과 공개 키를 먼저 설정해 주세요.") }
        let segments = path.split(separator: "?", maxSplits: 1)
        url.path = "/auth/v1/" + segments[0]; url.query = segments.count > 1 ? String(segments[1]) : nil
        guard let endpoint = url.url else { throw AIError.message("서버 주소를 확인해 주세요.") }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue(context.key, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await authentication.request(request)
        try validate(context)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AIError.message("인증에 실패했습니다. 서버 설정과 입력한 정보를 확인해 주세요.") }
        return data
    }
    func synchronize() async {
        guard !busy, let model, !model.loading, !model.isImporting, let store = model.store, let account = session?.user.id, let url = URL(string: projectURL), let operation = try? beginOperation() else { return }
        let expected = generation; defer { finishOperation(operation) }
        do {
            uploaded.formUnion(UserDefaults.standard.stringArray(forKey: "sync.uploaded.\(account)") ?? [])
            model.syncStatus = "동기화 중…"; status = "동기화 중…"
            try await store.bindSyncAccount(userID: account)
            guard generation == expected else { throw CancellationError() }
            let transport = try SupabaseSyncTransport(projectURL: url, publishableKey: publishableKey, userID: account) { [weak self] in
                guard let self else { throw CancellationError() }; return try await self.token(expectedGeneration: expected)
            }
            // Upload immutable files before publishing references to them.
            for item in model.materials {
                guard ![MaterialKind.note, .whiteboard].contains(item.kind) else { continue }
                let file = model.fileURL(item)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                if uploaded.contains(item.revision), item.byteCount != nil { continue }
                let asset = try AssetHasher.revision(of: file, contentType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                guard asset.sha256 == item.revision else { throw AIError.message("\(item.title)의 원본이 변경되었습니다. 새 자료로 가져와 주세요.") }
                if !uploaded.contains(asset.sha256) { try await transport.uploadAsset(asset, from: file); guard generation == expected else { throw CancellationError() }; uploaded.insert(asset.sha256) }
                guard generation == expected else { throw CancellationError() }
                if let index = model.materials.firstIndex(where: { $0.id == item.id }), model.materials[index].byteCount != asset.byteCount { model.materials[index].byteCount = asset.byteCount; model.persist(model.materials[index], kind: "material", id: "material:\(item.id)") }
            }
            // A recording is immutable only after capture has finished. Never hash/upload
            // the WAV while the audio writer is still appending frames.
            for item in model.recordings where ["completed", "recovered", "interrupted"].contains(item.state) {
                let file = model.root.appendingPathComponent(item.fileName)
                guard item.hasSafePath, FileManager.default.fileExists(atPath: file.path) else { continue }
                if let hash = item.assetRevision, uploaded.contains(hash) { continue }
                let asset = try AssetHasher.revision(of: file, contentType: "audio/wav")
                try await transport.uploadAsset(asset, from: file)
                guard generation == expected else { throw CancellationError() }
                uploaded.insert(asset.sha256)
                if var latest = model.recordings.first(where: { $0.id == item.id }) {
                    latest.assetRevision = asset.sha256; latest.byteCount = asset.byteCount
                    model.saveRecording(latest)
                }
            }
            try await model.flushChecked()
            guard generation == expected else { throw CancellationError() }
            let engine = SyncEngine(store: store, transport: transport); self.engine = engine
            let report = try await engine.synchronize()
            guard generation == expected else { throw CancellationError() }
            if report.pulled > 0 || report.conflicts > 0 { await model.reload() }
            for item in model.materials {
                guard generation == expected else { throw CancellationError() }
                if item.kind == .note { if let text = model.notes[item.id] { try model.write(Data(text.utf8), for: item) }; continue }
                if item.kind == .whiteboard { continue }
                let file = model.fileURL(item)
                if !FileManager.default.fileExists(atPath: file.path), let count = item.byteCount {
                    let asset = AssetRevision(sha256: item.revision, byteCount: count, originalName: item.fileName, contentType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                    try await transport.downloadAsset(asset, to: file)
                    guard generation == expected else { throw CancellationError() }
                    uploaded.insert(asset.sha256)
                }
            }
            for item in model.recordings {
                guard generation == expected else { throw CancellationError() }
                let file = model.root.appendingPathComponent(item.fileName)
                if item.hasSafePath, !FileManager.default.fileExists(atPath: file.path), let hash = item.assetRevision, let count = item.byteCount {
                    try await transport.downloadAsset(AssetRevision(sha256: hash, byteCount: count, originalName: (item.fileName as NSString).lastPathComponent, contentType: "audio/wav"), to: file)
                    guard generation == expected else { throw CancellationError() }
                    uploaded.insert(hash)
                }
            }
            let latestConflicts = try await store.conflicts()
            guard generation == expected else { throw CancellationError() }
            conflicts = latestConflicts
            UserDefaults.standard.set(Array(uploaded), forKey: "sync.uploaded.\(account)")
            status = conflicts.isEmpty ? "동기화 완료" : "\(conflicts.count)개 충돌 사본 보관됨"
            model.syncStatus = status
            model.objectWillChange.send()
            NotificationCenter.default.post(name: Notification.Name("app.bandal.records.changed"), object: nil)
        } catch is CancellationError { if generation == expected { status = "동기화 중지"; model.syncStatus = "기기에 저장됨" } }
        catch { if generation == expected { status = "동기화 대기: \(error.localizedDescription)"; model.syncStatus = "기기에 저장됨 · 동기화 대기" } }
    }
    func exportConflict(_ conflict: SyncConflict) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-\(conflict.id).json")
        try JSONEncoder().encode(conflict).write(to: url, options: .atomic); return url
    }
    func convertLegacyPPT(from source: URL, to destination: URL) async throws {
        guard let raw = UserDefaults.standard.string(forKey: "conversion.url"), let url = URL(string: raw), url.scheme == "https", url.host != nil else { throw AIError.message("설정에 PPT 변환 서버를 연결해 주세요.") }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 80 * 1024 * 1024 else { throw AIError.message("변환할 PPT는 80MB 이하여야 합니다.") }
        var request = URLRequest(url: url.appendingPathComponent("convert")); request.httpMethod = "POST"; request.timeoutInterval = 150
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.ms-powerpoint", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: source)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 150 * 1024 * 1024, let document = PDFDocument(data: data), document.pageCount > 0 else { throw AIError.message("PPT를 변환하지 못했습니다. 서버 연결과 파일 형식을 확인해 주세요.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
}

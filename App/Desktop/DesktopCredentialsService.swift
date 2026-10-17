import Foundation
import Security
import UIKit
import UniformTypeIdentifiers

struct DesktopCredentialTarget: Equatable {
    let guestID: Int
    let tabID: String
    let profileID: String
    let origin: String
    let generation: Int
}

/// Secrets remain in a device-only Keychain item and the native browser. The
/// original renderer receives metadata only; private tabs never enter here.
@MainActor
final class DesktopCredentialsService: NSObject, UIDocumentPickerDelegate {
    struct Environment {
        var read: (String) throws -> Data?
        var write: (String, Data?) throws -> Void
        var now: () -> Date = Date.init
        static let live = Environment(read: { account in
            var query = keychainQuery(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = value as? Data else { throw DesktopRuntimeError("기기의 안전한 로그인 저장소를 열지 못했습니다.") }
            return data
        }, write: { account, data in
            let query = keychainQuery(account)
            guard let data else {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw DesktopRuntimeError("저장한 로그인을 지우지 못했습니다.") }
                return
            }
            let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            let result = status == errSecItemNotFound ? SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil) : status
            guard result == errSecSuccess else { throw DesktopRuntimeError("기기의 안전한 로그인 저장소에 저장하지 못했습니다.") }
        })
    }
    struct Login: Codable {
        var id: String; var origin: String; var username: String; var password: String; var autoSubmit: Bool; var updatedAt: String
        var summary: [String: Any] { ["id": id, "origin": origin, "username": username, "autoSubmit": autoSubmit, "updatedAt": updatedAt] }
    }
    private struct Pending { var target: DesktopCredentialTarget; var username: String; var password: String; var expires: Date }
    private let namespace: String
    private let environment: Environment
    private var staged: [Int: Pending] = [:]
    private var picker: CheckedContinuation<URL?, Error>?
    weak var presenter: UIViewController?
    var profileExists: (String) -> Bool = { $0 == "default" }
    var target: (Int, String) throws -> DesktopCredentialTarget = { _, _ in throw DesktopRuntimeError("브라우저 탭을 먼저 열어 주세요.") }
    var capture: (DesktopCredentialTarget) async throws -> [String: String]? = { _ in nil }
    var fill: (DesktopCredentialTarget, String, String, Bool) async throws -> [String: Bool] = { _, _, _, _ in ["filled": false, "submitted": false] }
    init(namespace: String = "", environment: Environment = .live) { self.namespace = namespace; self.environment = environment }
    private func account(_ profile: String) -> String { namespace.isEmpty ? profile : namespace + ":" + profile }
    nonisolated static func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.bandal.ipad.browser-logins", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func canHandle(_ channel: String) -> Bool {
        ["credentials:availability", "credentials:list", "credentials:save", "credentials:capture", "credentials:forget", "credentials:fill", "credentials:importCsv"].contains(channel)
    }
    static func origin(_ input: String) throws -> String {
        guard let parts = URLComponents(string: input), parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil else { throw DesktopRuntimeError("로그인은 사용자 정보가 없는 HTTPS 사이트에만 저장할 수 있습니다.") }
        var canonical = URLComponents(); canonical.scheme = "https"; canonical.host = host
        canonical.port = parts.port == 443 ? nil : parts.port
        guard let value = canonical.string else { throw DesktopRuntimeError("사이트 주소를 확인해 주세요.") }; return value
    }
    private func profile(_ request: [String: Any]) throws -> String {
        let id = request["profileId"] as? String ?? "default"
        guard (id == "default" || UUID(uuidString: id) != nil), profileExists(id) else { throw DesktopRuntimeError("삭제되었거나 존재하지 않는 브라우저 프로필입니다.") }; return id
    }
    private func load(_ profile: String) throws -> [Login] {
        guard let data = try environment.read(account(profile)) else { return [] }
        guard data.count <= 4 * 1024 * 1024, let values = try? JSONDecoder().decode([Login].self, from: data), values.count <= 10_000,
              Set(values.map(\.id)).count == values.count,
              Set(values.map { $0.origin + "\u{0}" + $0.username }).count == values.count,
              values.allSatisfy({ (try? Self.origin($0.origin)) == $0.origin && !$0.password.isEmpty && $0.password.utf8.count <= 100_000 && $0.username.utf8.count <= 10_000 }) else {
            throw DesktopRuntimeError("저장된 로그인 데이터를 읽지 못했습니다. 기존 데이터는 보존했습니다.")
        }
        return values
    }
    private func persist(_ values: [Login], profile: String) throws {
        guard profileExists(profile) else { throw DesktopRuntimeError("브라우저 프로필이 삭제되었습니다.") }
        let data = try JSONEncoder().encode(values)
        guard values.count <= 10_000, data.count <= 4 * 1024 * 1024 else { throw DesktopRuntimeError("로그인 저장 한도를 초과했습니다.") }
        try environment.write(account(profile), values.isEmpty ? nil : data)
    }
    private func save(_ request: [String: Any], profile: String) throws -> Login {
        let origin = try Self.origin(request["origin"] as? String ?? "")
        guard let username = request["username"] as? String, let password = request["password"] as? String, username.utf8.count <= 10_000, password.utf8.count <= 100_000 else { throw DesktopRuntimeError("로그인 입력을 확인해 주세요.") }
        var values = try load(profile); let id = request["id"] as? String
        let existing = values.first { $0.origin == origin && (id == nil ? $0.username == username : $0.id == id) }
        guard id == nil || existing != nil, !password.isEmpty || (id != nil && existing != nil) else { throw DesktopRuntimeError("수정할 로그인 계정을 확인해 주세요.") }
        guard !values.contains(where: { $0.id != existing?.id && $0.origin == origin && $0.username == username }) else { throw DesktopRuntimeError("같은 계정의 로그인이 이미 있습니다.") }
        let login = Login(id: existing?.id ?? UUID().uuidString, origin: origin, username: username, password: password.isEmpty ? existing!.password : password, autoSubmit: request["autoSubmit"] as? Bool ?? existing?.autoSubmit ?? false, updatedAt: ISO8601DateFormatter().string(from: environment.now()))
        values.removeAll { $0.id == login.id }; values.append(login)
        try persist(values, profile: profile); return login
    }
    /// Only the private, approved agent route may use this entry point. It can
    /// fill one unambiguous account but can never auto-submit a login form.
    func fillForAgent(guestID: Int, origin: String) async throws -> [String: Bool] {
        let normalized = try Self.origin(origin), page = try target(guestID, normalized)
        let values = try load(page.profileID).filter { $0.origin == normalized }
        guard values.count == 1 else { return ["filled": false, "submitted": false] }
        return try await fill(page, values[0].username, values[0].password, false)
    }
    func deleteProfile(_ profile: String) throws {
        try environment.write(account(profile), nil); staged = staged.filter { $0.value.target.profileID != profile }
    }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        staged = staged.filter { $0.value.expires > environment.now() }
        if channel == "credentials:capture" || channel == "credentials:fill" { return try await pageRequest(channel, request: request) }
        let profile = try profile(request)
        switch channel {
        case "credentials:availability":
            do { _ = try load(profile); return ["state": "ready"] }
            catch { return ["state": "unavailable", "reason": error.localizedDescription] }
        case "credentials:list": return try load(profile).sorted { $0.origin < $1.origin }.map(\.summary)
        case "credentials:save": return try save(request, profile: profile).summary
        case "credentials:forget":
            let origin = try Self.origin(request["origin"] as? String ?? ""); var values = try load(profile)
            let matching = values.filter { $0.origin == origin }, id = request["credentialId"] as? String
            let selected = id ?? (matching.count == 1 ? matching[0].id : nil)
            values.removeAll { $0.origin == origin && $0.id == selected }; try persist(values, profile: profile); return ["ok": true]
        case "credentials:importCsv":
            guard let url = try await pickCSV() else { return ["imported": 0, "skipped": 0, "cancelled": true] }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1024 * 1024 else { throw DesktopRuntimeError("10MB 이하 CSV 파일을 선택해 주세요.") }
            let data = try Data(contentsOf: url)
            guard data.count <= 10 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw DesktopRuntimeError("UTF-8 CSV 파일을 읽지 못했습니다.") }
            return try importCSV(text, profile: profile)
        default: throw DesktopRuntimeError("지원하지 않는 로그인 요청입니다.")
        }
    }
    private func pageRequest(_ channel: String, request: [String: Any]) async throws -> Any {
        guard let guest = request["guestWebContentsId"] as? Int else { throw DesktopRuntimeError("브라우저 탭을 확인해 주세요.") }
        let mode = request["mode"] as? String ?? "save"
        if channel == "credentials:capture", mode == "discard" { staged.removeValue(forKey: guest); return NSNull() }
        let origin = try Self.origin(request["origin"] as? String ?? ""), page = try target(guest, origin)
        guard page.origin == origin, profileExists(page.profileID) else { throw DesktopRuntimeError("로그인 사이트와 프로필을 확인해 주세요.") }
        if channel == "credentials:fill" {
            let matching = try load(page.profileID).filter { $0.origin == origin }, id = request["credentialId"] as? String
            let login = id == nil ? (matching.count == 1 ? matching[0] : nil) : matching.first { $0.id == id }
            guard let login else { return ["filled": false, "submitted": false] }
            guard try target(guest, origin) == page else { throw DesktopRuntimeError("페이지가 바뀌었습니다. 다시 시도해 주세요.") }
            // A manual native "fill" action can explicitly suppress an older
            // saved auto-submit preference. It can never enable submission for
            // an account that was not saved with that preference.
            let submit = login.autoSubmit && request["autoSubmit"] as? Bool != false
            return try await fill(page, login.username, login.password, submit)
        }
        guard ["save", "stage", "commit"].contains(mode) else { throw DesktopRuntimeError("로그인 저장 요청을 확인해 주세요.") }
        if mode == "commit" {
            guard let pending = staged[guest], pending.expires > environment.now(), pending.target == page else {
                staged.removeValue(forKey: guest); return NSNull()
            }
            let result = try save(["origin": origin, "username": pending.username, "password": pending.password, "autoSubmit": false], profile: page.profileID)
            staged.removeValue(forKey: guest); return result.summary
        }
        guard let login = try await capture(page), let username = login["username"], !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, username.utf8.count <= 10_000,
              let password = login["password"], !password.isEmpty, password.utf8.count <= 100_000,
              try target(guest, origin) == page else { return NSNull() }
        if mode == "stage" {
            if try load(page.profileID).contains(where: { $0.origin == origin && $0.username == username && $0.password == password }) { staged.removeValue(forKey: guest); return NSNull() }
            let expires = environment.now().addingTimeInterval(60)
            staged[guest] = Pending(target: page, username: username, password: password, expires: expires)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.staged[guest]?.expires == expires else { return }
                self.staged.removeValue(forKey: guest)
            }
            return ["id": "staged:\(guest)", "origin": origin, "username": username, "autoSubmit": false, "updatedAt": ISO8601DateFormatter().string(from: environment.now())]
        }
        return try save(["origin": origin, "username": username, "password": password, "autoSubmit": request["autoSubmit"] as? Bool ?? false], profile: page.profileID).summary
    }
    func importCSV(_ text: String, profile: String) throws -> [String: Any] {
        let rows = try Self.csvRows(text), header = rows.first?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        guard let originIndex = header.firstIndex(where: { ["url", "origin", "hostname"].contains($0) }), let userIndex = header.firstIndex(of: "username"), let passwordIndex = header.firstIndex(of: "password") else { throw DesktopRuntimeError("비밀번호 CSV에 url, username, password 열이 필요합니다.") }
        var values = try load(profile), skipped = 0, imported = 0
        for row in rows.dropFirst() {
            guard max(originIndex, userIndex, passwordIndex) < row.count, let origin = try? Self.origin(row[originIndex].trimmingCharacters(in: .whitespacesAndNewlines)), !row[passwordIndex].isEmpty,
                  row[passwordIndex].utf8.count <= 100_000, row[userIndex].utf8.count <= 10_000,
                  !values.contains(where: { $0.origin == origin && $0.username == row[userIndex] }) else { skipped += 1; continue }
            values.append(Login(id: UUID().uuidString, origin: origin, username: row[userIndex], password: row[passwordIndex], autoSubmit: false, updatedAt: ISO8601DateFormatter().string(from: environment.now()))); imported += 1
        }
        if imported > 0 { try persist(values, profile: profile) }
        return ["imported": imported, "skipped": skipped, "cancelled": false]
    }
    static func csvRows(_ text: String) throws -> [[String]] {
        guard text.utf8.count <= 10 * 1024 * 1024 else { throw DesktopRuntimeError("CSV 파일이 너무 큽니다.") }
        let characters = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, i = 0
        while i < characters.count {
            let c = characters[i]
            if quoted {
                if c == "\"", i + 1 < characters.count, characters[i + 1] == "\"" { field.append("\""); i += 1 }
                else if c == "\"" { quoted = false } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field.hasSuffix("\r") ? String(field.dropLast()) : field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
            guard rows.count <= 10_001 else { throw DesktopRuntimeError("CSV는 한 번에 10,000개 계정까지 가져올 수 있습니다.") }; i += 1
        }
        guard !quoted else { throw DesktopRuntimeError("CSV 따옴표 형식을 확인해 주세요.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard rows.count <= 10_001 else { throw DesktopRuntimeError("CSV는 한 번에 10,000개 계정까지 가져올 수 있습니다.") }; return rows
    }
    private func pickCSV() async throws -> URL? {
        guard picker == nil, let presenter, presenter.presentedViewController == nil else { throw DesktopRuntimeError("열린 파일 선택 창을 먼저 닫아 주세요.") }
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.commaSeparatedText, .plainText], asCopy: false); controller.delegate = self
        return try await withCheckedThrowingContinuation { continuation in picker = continuation; presenter.present(controller, animated: true) }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { let pending = picker; picker = nil; pending?.resume(returning: urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { let pending = picker; picker = nil; pending?.resume(returning: nil) }
}

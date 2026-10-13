import Foundation
import CryptoKit
import WebKit

struct DesktopBrowserProfile: Codable {
    var id: String
    var name: String
    var color: String
    var icon: String
    var json: [String: Any] { ["id": id, "name": name, "color": color, "icon": icon] }
}
struct DesktopBrowserVisit: Codable {
    var profileID: String
    var courseID: String?
    var url: String
    var title: String
    var host: String
    var visitCount: Int
    var lastVisitedAt: String
    var json: [String: Any] { ["url": url, "title": title, "host": host, "visitCount": visitCount, "lastVisitedAt": lastVisitedAt] }
}
struct DesktopBrowserPermission: Codable {
    var id = UUID().uuidString
    var profileID: String
    var origin: String
    var permission: String
    var decision: String
    var decidedAt = ISO8601DateFormatter().string(from: Date())
    var json: [String: Any] { ["id": id, "origin": origin, "permission": permission, "decision": decision, "decidedAt": decidedAt] }
}

@MainActor
final class DesktopBrowserPersistence {
    struct State: Codable {
        var profiles: [DesktopBrowserProfile] = [.init(id: "default", name: "기본", color: "#4d7850", icon: "globe")]
        var visits: [DesktopBrowserVisit] = []
        var permissions: [DesktopBrowserPermission] = []
    }
    private let file: URL
    var state: State
    private var normalStores: [String: WKWebsiteDataStore] = [:]
    private var privateStores: [String: WKWebsiteDataStore] = [:]
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("browser-state.json")
        if FileManager.default.fileExists(atPath: file.path) { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
        else { state = State() }
    }
    func commit(_ replacement: State) throws {
        try JSONEncoder().encode(replacement).write(to: file, options: .atomic)
        state = replacement
    }
    func dataStore(profile: String, isPrivate: Bool) -> WKWebsiteDataStore {
        if isPrivate {
            if let existing = privateStores[profile] { return existing }
            let store = WKWebsiteDataStore.nonPersistent(); privateStores[profile] = store; return store
        }
        if let existing = normalStores[profile] { return existing }
        let store: WKWebsiteDataStore = profile == "default" ? .default() : WKWebsiteDataStore(forIdentifier: Self.identifier(profile))
        normalStores[profile] = store; return store
    }
    func knownDataStores() -> [WKWebsiteDataStore] {
        state.profiles.map { dataStore(profile: $0.id, isPrivate: false) } + Array(privateStores.values)
    }
    func discardPrivateStore(_ profile: String) { privateStores.removeValue(forKey: profile) }
    func forgetProfileStore(_ profile: String) async throws {
        normalStores.removeValue(forKey: profile); privateStores.removeValue(forKey: profile)
        try await WKWebsiteDataStore.remove(forIdentifier: Self.identifier(profile))
    }
    static func identifier(_ profile: String) -> UUID {
        let hex = SHA256.hash(data: Data(("app.bandal.browser.profile:" + profile).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let indices = [8, 12, 16, 20]
        var string = ""
        for (index, character) in hex.enumerated() { if indices.contains(index) { string += "-" }; string.append(character) }
        return UUID(uuidString: string)!
    }
}

enum DesktopBrowserError: LocalizedError {
    case invalid(String), unsupported(String), unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): "브라우저 요청이 올바르지 않습니다: \(detail)"
        case .unsupported(let detail): "iPad 브라우저에서 지원하지 않는 기능입니다: \(detail)"
        case .unavailable(let detail): detail
        }
    }
}

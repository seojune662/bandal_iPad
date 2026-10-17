import Foundation

/// Mirrors the desktop study-market client, with a deliberately read-only
/// operation set until purchase/sale/import flows are implemented natively.
@MainActor
final class NativeStudyMarketClient {
    private let cloud: DesktopCloudService
    init(cloud: DesktopCloudService) { self.cloud = cloud }
    func request(_ request: [String: Any]) async throws -> Any {
        guard let action = request["action"] as? String,
              ["context", "courses", "listings", "listing", "dashboard"].contains(action) else {
            throw DesktopRuntimeError("iPad에서는 마켓플레이스의 자료와 구매·판매 내역을 조회할 수 있습니다. 거래 작업은 아직 지원하지 않습니다.")
        }
        let state = try await cloud.handle(channel: "native:cloudState", request: [:]) as? [String: Any] ?? [:]
        let signedIn = state["signedIn"] as? Bool == true
        guard let configuration = state["supabase"] as? [String: Any], let base = configuration["url"] as? String else {
            return try unavailable(action, signedIn: signedIn)
        }
        if action == "dashboard", !signedIn { return emptyDashboard(configured: true, signedIn: false, notice: "로그인하면 구매한 자료와 판매 내역을 확인할 수 있어요.") }
        let id = UUID().uuidString
        var headers = ["content-type": "application/json", "apikey": "native-configuration"]
        if signedIn { headers["authorization"] = "Bearer native-keychain" }
        let body = try JSONSerialization.data(withJSONObject: ["action": action, "input": request["input"] as? [String: Any] ?? [:]])
        var input: [String: Any] = ["id": id, "url": base + "/functions/v1/study-market", "method": "POST", "headers": headers, "bodyBase64": body.base64EncodedString()]
        if let account = state["accountID"] as? String { input["accountID"] = account }
        do {
            guard let response = try await cloud.handle(channel: "native:cloudRequest", request: input) as? [String: Any], let status = response["status"] as? Int else { throw DesktopRuntimeError("마켓 응답을 확인하지 못했습니다.") }
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard let part = try await cloud.handle(channel: "native:cloudRead", request: ["bodyID": id]) as? [String: Any],
                      let encoded = part["data"] as? String, let chunk = Data(base64Encoded: encoded) else { throw DesktopRuntimeError("마켓 응답을 읽지 못했습니다.") }
                data.append(chunk)
                guard data.count <= 8 * 1024 * 1024 else { throw DesktopRuntimeError("마켓 응답이 너무 큽니다.") }
                if part["done"] as? Bool == true { break }
            }
            let current = try await cloud.handle(channel: "native:cloudState", request: [:]) as? [String: Any] ?? [:]
            guard current["accountID"] as? String == state["accountID"] as? String else { throw CancellationError() }
            if status == 404 { return try unavailable(action, signedIn: signedIn) }
            let decoded = try? JSONSerialization.jsonObject(with: data)
            guard (200..<300).contains(status), let decoded else {
                let detail = (decoded as? [String: Any])?["error"] as? String ?? "마켓 요청을 처리하지 못했어요. 다시 시도해 주세요."
                throw DesktopRuntimeError(String(detail.prefix(500)))
            }
            if action == "context", var context = decoded as? [String: Any] { context["configured"] = true; return context }
            return decoded
        } catch {
            _ = try? await cloud.handle(channel: "native:cloudCancel", request: ["id": id]); throw error
        }
    }
    private func unavailable(_ action: String, signedIn: Bool) throws -> Any {
        let notice = "마켓플레이스를 준비하고 있어요. 실제 거래가 열리면 이곳에서 이용할 수 있어요."
        if action == "context" { return ["configured": false, "universities": [], "tradingEnabled": false, "notice": notice] as [String: Any] }
        if action == "dashboard" { return emptyDashboard(configured: false, signedIn: signedIn, notice: notice) }
        throw DesktopRuntimeError("마켓플레이스 연결을 준비하고 있어요.")
    }
    private func emptyDashboard(configured: Bool, signedIn: Bool, notice: String) -> [String: Any] {
        ["configured": configured, "signedIn": signedIn, "tradingEnabled": false, "operator": false,
         "seller": ["status": "unregistered", "displayName": ""], "listings": [], "purchases": [], "payouts": [],
         "salesCount": 0, "pendingAmount": 0, "paidAmount": 0, "notice": notice]
    }
}

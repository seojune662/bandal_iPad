import Foundation
import StoreKit
import UIKit

struct DesktopAppleTransaction {
    let productID: String
    let appAccountToken: UUID?
    let signedTransaction: String
    let finish: () async -> Void
}
enum DesktopApplePurchaseResult { case purchased(DesktopAppleTransaction), pending, cancelled }

@MainActor
struct DesktopBillingEnvironment {
    var request: ((String, [String: Any]) async throws -> [String: Any])?
    var products: ([String]) async throws -> [[String: Any]] = { ids in
        try await Product.products(for: ids).map { ["id": $0.id, "displayName": $0.displayName, "displayPrice": $0.displayPrice] }
    }
    var purchase: (String, UUID) async throws -> DesktopApplePurchaseResult = { id, token in
        guard let product = try await Product.products(for: [id]).first, product.type == .autoRenewable else { throw DesktopRuntimeError("App Store 상품을 준비하지 못했습니다.", code: "APPLE_PRODUCT_UNAVAILABLE") }
        switch try await product.purchase(options: [.appAccountToken(token)]) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw DesktopRuntimeError("구매 서명을 확인하지 못했습니다.", code: "APPLE_VERIFICATION_FAILED") }
            return .purchased(Self.transaction(transaction, signed: verification.jwsRepresentation))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw DesktopRuntimeError("구매 상태를 확인하지 못했습니다.")
        }
    }
    var restore: () async throws -> Void = { try await AppStore.sync() }
    var transactions: () async -> [DesktopAppleTransaction] = {
        var values: [UInt64: DesktopAppleTransaction] = [:]
        for await verification in Transaction.currentEntitlements {
            if case .verified(let transaction) = verification { values[transaction.id] = Self.transaction(transaction, signed: verification.jwsRepresentation) }
        }
        for await verification in Transaction.unfinished {
            if case .verified(let transaction) = verification { values[transaction.id] = Self.transaction(transaction, signed: verification.jwsRepresentation) }
        }
        return Array(values.values)
    }
    static func transaction(_ value: Transaction, signed: String) -> DesktopAppleTransaction {
        DesktopAppleTransaction(productID: value.productID, appAccountToken: value.appAccountToken, signedTransaction: signed, finish: { await value.finish() })
    }
}

/// StoreKit proves a transaction; the authenticated backend decides ownership
/// and subscription access. Neither a renderer flag nor local receipt unlocks sync.
@MainActor
final class DesktopBillingService {
    var emit: ((String, Any) -> Void)?
    var entitlementChanged: (() -> Void)?
    private let account: DesktopAccountService
    private let environment: DesktopBillingEnvironment
    private var updates: Task<Void, Never>?
    private var busy = false
    var hasActivePurchase: Bool { busy }
    private var generation = 0
    private var cached: [String: Any] = [:]
    private let endpoint: String
    private static let productIDs = ["app.bandal.ipad.sync.monthly", "app.bandal.ipad.sync.yearly"]
    init(account: DesktopAccountService, environment: DesktopBillingEnvironment? = nil) {
        self.account = account; self.environment = environment ?? DesktopBillingEnvironment()
        #if DEBUG
        endpoint = UserDefaults.standard.string(forKey: "appleBilling.environment") == "sandbox" ? "/functions/v1/apple-billing-sandbox" : "/functions/v1/apple-billing"
        #else
        endpoint = "/functions/v1/apple-billing"
        #endif
        if environment == nil {
            updates = Task { [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    guard case .verified(let value) = result else { continue }
                    _ = try? await self?.accept(DesktopBillingEnvironment.transaction(value, signed: result.jwsRepresentation))
                }
            }
        }
    }
    func accountChanged() { generation += 1; cached = [:] }
    func canHandle(_ channel: String) -> Bool { ["billing:getState", "billing:prepareApple", "billing:purchase", "billing:restore", "billing:refresh", "billing:manageApple"].contains(channel) }
    func handle(_ channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "billing:getState", "billing:refresh", "billing:prepareApple": return try await refresh()
        case "billing:purchase": return try await purchase(plan: request["plan"] as? String ?? "")
        case "billing:restore": return try await restore()
        case "billing:manageApple":
            guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { throw DesktopRuntimeError("구독 관리 화면을 열 수 없습니다.") }
            try await AppStore.showManageSubscriptions(in: scene); return ["ok": true]
        default: throw DesktopRuntimeError("지원하지 않는 결제 요청입니다.")
        }
    }
    private func serverRequest(path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        if let request = environment.request { return try await request(path, body) }
        return try await account.serviceRequest(path: path, body: body)
    }
    private func refresh() async throws -> [String: Any] {
        let expected = generation
        async let subscription = serverRequest(path: "/rest/v1/rpc/bandal_subscription_status")
        async let sync = serverRequest(path: "/rest/v1/rpc/bandal_sync_status")
        let available = (try? await environment.products(Self.productIDs)) ?? []
        let products = available.compactMap { product -> [String: Any]? in
            guard let id = product["id"] as? String, let index = Self.productIDs.firstIndex(of: id) else { return nil }
            return product.merging(["plan": index == 0 ? "monthly" : "annual"]) { _, new in new }
        }
        let result: [String: Any] = try await ["subscription": subscription, "sync": sync, "provider": "apple", "products": products]
        guard expected == generation else { throw CancellationError() }
        publish(result); return result
    }
    private struct Prepared { let token: UUID; let products: [String: String]; let raw: [String: Any] }
    private func prepare() async throws -> Prepared {
        let expected = generation
        let response = try await serverRequest(path: endpoint, body: ["action": "prepare"])
        guard expected == generation else { throw CancellationError() }
        guard let raw = response["appAccountToken"] as? String, let token = UUID(uuidString: raw),
              let products = response["productIds"] as? [String: String], !products["monthly", default: ""].isEmpty, !products["annual", default: ""].isEmpty else { throw DesktopRuntimeError("App Store 구독을 준비하지 못했습니다.", code: "APPLE_BILLING_UNAVAILABLE") }
        return Prepared(token: token, products: products, raw: response)
    }
    private func purchase(plan: String) async throws -> [String: Any] {
        guard ["monthly", "annual"].contains(plan), !busy else { throw DesktopRuntimeError("진행 중인 구매를 확인해 주세요.") }
        busy = true; defer { busy = false }
        let expected = generation, prepared = try await prepare()
        if (prepared.raw["subscription"] as? [String: Any])?["active"] as? Bool == true { throw DesktopRuntimeError("이미 이용 중인 구독이 있습니다. 구독 관리에서 확인해 주세요.", code: "subscription_exists") }
        guard let product = prepared.products[plan] else { throw DesktopRuntimeError("구독 상품을 확인해 주세요.") }
        let result = try await environment.purchase(product, prepared.token)
        guard expected == generation else { throw CancellationError() }
        switch result {
        case .pending: return ["ok": true, "status": "pending"]
        case .cancelled: return ["ok": true, "status": "cancelled"]
        case .purchased(let transaction):
            let response = try await accept(transaction, prepared: prepared)
            return response.merging(["ok": true, "status": "purchased"]) { _, new in new }
        }
    }
    private func restore() async throws -> [String: Any] {
        guard !busy else { throw DesktopRuntimeError("진행 중인 구매를 확인해 주세요.") }
        busy = true; defer { busy = false }
        let expected = generation
        _ = try await serverRequest(path: "/rest/v1/rpc/bandal_subscription_status")
        try await environment.restore()
        guard expected == generation else { throw CancellationError() }
        for transaction in await environment.transactions() where Self.productIDs.contains(transaction.productID) {
            _ = try await accept(transaction)
        }
        let response = try await serverRequest(path: endpoint, body: ["action": "refresh"])
        guard expected == generation else { throw CancellationError() }
        publish(response); return response.merging(["ok": true, "status": "restored"]) { _, new in new }
    }
    private func accept(_ transaction: DesktopAppleTransaction, prepared: Prepared? = nil) async throws -> [String: Any] {
        let expected = generation
        let allowed = prepared.map { Array($0.products.values) } ?? Self.productIDs
        guard allowed.contains(transaction.productID), transaction.appAccountToken != nil,
              prepared == nil || transaction.appAccountToken == prepared?.token else {
            throw DesktopRuntimeError("이 구매는 현재 반달 계정과 연결되지 않았습니다.", code: "purchase_owned_by_another_account")
        }
        let response = try await serverRequest(path: endpoint, body: ["action": "verify", "signedTransaction": transaction.signedTransaction])
        guard expected == generation else { throw CancellationError() }
        // A network/server failure intentionally leaves StoreKit unfinished.
        // Transaction.updates/restore can safely retry the same signed payload.
        await transaction.finish()
        guard expected == generation else { throw CancellationError() }
        publish(response); entitlementChanged?(); return response
    }
    private func publish(_ state: [String: Any]) { cached = state; emit?("billing:changed", state) }
    deinit { updates?.cancel() }
}

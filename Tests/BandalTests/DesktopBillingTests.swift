import XCTest
@testable import Bandal

@MainActor
final class DesktopBillingTests: XCTestCase {
    private let token = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private func account() -> DesktopAccountService {
        var environment = DesktopAccountEnvironment(); environment.configuration = { ("", "") }; environment.readCredential = { nil }
        return DesktopAccountService(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), environment: environment)
    }
    func testStatusReadsLocalizedProductsWithoutReservingPurchase() async throws {
        var paths: [String] = []
        var environment = DesktopBillingEnvironment()
        environment.request = { path, body in
            XCTAssertNil(body["action"]); paths.append(path)
            return path.hasSuffix("bandal_sync_status") ? ["writeAllowed": false] : ["active": false]
        }
        environment.products = { _ in [["id": "app.bandal.ipad.sync.yearly", "displayName": "Annual", "displayPrice": "₩12,000"], ["id": "unrelated", "displayPrice": "$99"]] }
        environment.purchase = { _, _ in XCTFail("Status must never purchase"); return .cancelled }
        let service = DesktopBillingService(account: account(), environment: environment)
        let result = try await service.handle("billing:getState", request: [:]) as? [String: Any]
        let products = try XCTUnwrap(result?["products"] as? [[String: Any]])
        XCTAssertEqual(products.count, 1); XCTAssertEqual(products[0]["plan"] as? String, "annual")
        XCTAssertEqual(products[0]["displayPrice"] as? String, "₩12,000")
        XCTAssertEqual(Set(paths), ["/rest/v1/rpc/bandal_subscription_status", "/rest/v1/rpc/bandal_sync_status"])
    }
    func testServerVerificationPrecedesFinishAndUsesOnlySignedTransaction() async throws {
        var finished = false, verified = false, calls: [String] = []
        var environment = DesktopBillingEnvironment()
        environment.request = { path, body in
            let action = body["action"] as? String ?? ""; calls.append(action)
            if action == "prepare" { return ["appAccountToken": self.token.uuidString, "productIds": ["monthly": "app.bandal.ipad.sync.monthly", "annual": "app.bandal.ipad.sync.yearly"], "subscription": ["active": false]] }
            XCTAssertEqual(path, "/functions/v1/apple-billing")
            XCTAssertEqual(Set(body.keys), ["action", "signedTransaction"])
            XCTAssertEqual(body["signedTransaction"] as? String, "signed.fixture")
            XCTAssertFalse(finished); verified = true
            return ["subscription": ["active": true], "sync": ["writeAllowed": true]]
        }
        environment.purchase = { product, token in
            XCTAssertEqual(token, self.token)
            return .purchased(DesktopAppleTransaction(productID: product, appAccountToken: token, signedTransaction: "signed.fixture", finish: { XCTAssertTrue(verified); finished = true }))
        }
        let service = DesktopBillingService(account: account(), environment: environment)
        let result = try await service.handle("billing:purchase", request: ["plan": "monthly"]) as? [String: Any]
        XCTAssertEqual(result?["status"] as? String, "purchased"); XCTAssertTrue(finished); XCTAssertEqual(calls, ["prepare", "verify"])
    }
    func testFailedVerificationRetainsUnfinishedPurchaseAndRestoreDoesNotPrepare() async throws {
        var finished = false, actions: [String] = []
        var environment = DesktopBillingEnvironment()
        environment.request = { _, body in
            let action = body["action"] as? String ?? "status"; actions.append(action)
            if action == "verify" { throw URLError(.notConnectedToInternet) }
            return ["active": true]
        }
        environment.restore = {}
        environment.transactions = { [DesktopAppleTransaction(productID: "app.bandal.ipad.sync.monthly", appAccountToken: self.token, signedTransaction: "signed.restore", finish: { finished = true })] }
        let service = DesktopBillingService(account: account(), environment: environment)
        do { _ = try await service.handle("billing:restore", request: [:]); XCTFail("Expected server outage") } catch { }
        XCTAssertFalse(finished); XCTAssertEqual(actions, ["status", "verify"])
    }
    func testExistingSubscriptionPreventsPurchaseAndPendingNeverUnlocks() async throws {
        var purchases = 0, active = true, verifications = 0
        var environment = DesktopBillingEnvironment()
        environment.request = { _, body in
            if body["action"] as? String == "verify" { verifications += 1 }
            return ["appAccountToken": self.token.uuidString, "productIds": ["monthly": "app.bandal.ipad.sync.monthly", "annual": "app.bandal.ipad.sync.yearly"], "subscription": ["active": active]]
        }
        environment.purchase = { _, _ in purchases += 1; return .pending }
        let service = DesktopBillingService(account: account(), environment: environment)
        do { _ = try await service.handle("billing:purchase", request: ["plan": "monthly"]); XCTFail("Existing subscription must prevent purchase") } catch { }
        XCTAssertEqual(purchases, 0)
        active = false
        let pending = try await service.handle("billing:purchase", request: ["plan": "annual"]) as? [String: Any]
        XCTAssertEqual(pending?["status"] as? String, "pending"); XCTAssertEqual(verifications, 0)
    }
}

import XCTest
@testable import Bandal

/// Buying on 요금제 and from a 충전 button (StorePurchase), and paying a credit pack (StoreSync), without
/// StoreKit: a purchase step, the membership refresh and the `ipad-store` server are fakes. PlansPurchaseFlowUITests
/// presses the screen's buttons; StoreKit's own part (the sheet, renewals taking effect) is the BandalStoreKit
/// scheme in Xcode and the sandbox check in docs/release/ai-credit-submission.md.
@MainActor
final class PlansPurchaseTests: XCTestCase {
    private let plusMonthly = StoreOffer(id: "app.bandal.ipad.plus.monthly", displayPrice: "₩1,500", price: 1500, yearly: false, trialDays: 7, product: nil)
    private let plusYearly = StoreOffer(id: "app.bandal.ipad.plus.yearly", displayPrice: "₩11,000", price: 11000, yearly: true, trialDays: nil, product: nil)
    private let proMonthly = StoreOffer(id: "app.bandal.ipad.pro.monthly", displayPrice: "₩4,500", price: 4500, yearly: false, trialDays: nil, product: nil)
    private let pack = StoreOffer(id: StoreSync.creditPack, displayPrice: "₩5,500", price: 5500, yearly: nil, trialDays: nil, product: nil)

    /// `ipad-store` as the function behaves: a transaction id is paid once; `failing` is an unreachable server.
    private final class FakeServer {
        var failing: Error?
        /// Keeps a request in flight, so a second one can meet it.
        var delay: Duration?
        var requests: [String] = []
        var paid: [String] = []
        let amount: Int64 = 200_000_000
        func post(_ body: [String: Any]) async throws -> [String: Any] {
            let action = body["action"] as? String ?? ""
            requests.append(action)
            if let delay { try await Task.sleep(for: delay) }
            if let failing { throw failing }
            if action == "redeem", let jws = body["transaction"] as? String, !paid.contains(jws) { paid.append(jws) }
            return ["plan": "pro", "percent": 100, "creditUcents": Int64(paid.count) * amount]
        }
    }

    /// StoreKit's unfinished transactions: a pack stays here until it is finished.
    private final class FakeLedger {
        var unfinished: [UInt64: String] = [:]
        var finished: [UInt64] = []
        func pack(_ id: UInt64) -> StoreSync.Pack {
            StoreSync.Pack(id: id, jws: unfinished[id] ?? "jws-\(id)") { [weak self] in
                self?.unfinished[id] = nil; self?.finished.append(id)
            }
        }
        func buy(_ id: UInt64) -> StoreSync.Pack { unfinished[id] = "jws-\(id)"; return pack(id) }
    }

    private func sync(_ server: FakeServer, _ ledger: FakeLedger, status: @escaping ([String: Any]) -> Void = { _ in }) -> StoreSync {
        let sync = StoreSync()
        sync.post = { try await server.post($0) }
        sync.onStatus = status
        sync.unfinishedPacks = { ledger.unfinished.keys.sorted().map { ledger.pack($0) } }
        return sync
    }

    private func store(_ step: StorePurchase.Step, current: String?, synced: @escaping () -> Void = {}) -> StorePurchase.Store {
        StorePurchase.Store(purchase: { _ in step }, refresh: { current }, syncSubscriptions: { synced() })
    }

    // MARK: Plans

    /// An upgrade (or a first subscription) is in effect at once; the server hears of it.
    func testAnUpgradeStartsAtOnceAndIsSynced() async {
        var synced = 0
        let outcome = await StorePurchase.plan(proMonthly, store: store(.success(settle: { true }), current: proMonthly.id) { synced += 1 })
        XCTAssertEqual(outcome, .started(.pro))
        XCTAssertEqual(synced, 1)
    }

    /// A downgrade keeps the current plan until renewal: StoreKit still reports the old product.
    func testADowngradeIsBookedForRenewal() async {
        let outcome = await StorePurchase.plan(plusYearly, store: store(.success(settle: { true }), current: proMonthly.id))
        XCTAssertEqual(outcome, .scheduled(productID: plusYearly.id))
    }

    /// Monthly to yearly on the same plan also waits for the next renewal.
    func testAChangeOfPeriodIsBookedForRenewal() async {
        let outcome = await StorePurchase.plan(plusYearly, store: store(.success(settle: { true }), current: plusMonthly.id))
        XCTAssertEqual(outcome, .scheduled(productID: plusYearly.id))
    }

    func testCancelPendingAndUnverifiedChangeNothing() async {
        var synced = 0
        let cancelled = await StorePurchase.plan(plusMonthly, store: store(.cancelled, current: nil) { synced += 1 })
        let pending = await StorePurchase.plan(plusMonthly, store: store(.pending, current: nil) { synced += 1 })
        let unverified = await StorePurchase.plan(plusMonthly, store: store(.success(settle: { false }), current: nil) { synced += 1 })
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(pending, .pending, "Ask to Buy: the approval comes later through Transaction.updates")
        XCTAssertEqual(unverified, .unverified)
        XCTAssertEqual(synced, 0)
    }

    func testAStoreErrorIsSaid() async {
        let failing = StorePurchase.Store(purchase: { _ in throw URLError(.notConnectedToInternet) }, refresh: { nil }, syncSubscriptions: {})
        guard case .failed(let reason) = await StorePurchase.plan(plusMonthly, store: failing) else { return XCTFail() }
        XCTAssertFalse(reason.isEmpty)
        guard case .failed = await StorePurchase.credit(pack, store: failing) else { return XCTFail() }
    }

    // MARK: Credit packs

    /// Bought → the server pays → the transaction is finished, and the new balance reaches the screen.
    func testAPackIsPaidThenFinished() async {
        let server = FakeServer(), ledger = FakeLedger()
        var balance: Int64?
        let sync = sync(server, ledger) { balance = ($0["creditUcents"] as? Int64) }
        let bought = ledger.buy(1)
        let outcome = await StorePurchase.credit(pack, store: store(.success(settle: { await sync.settle(bought) }), current: nil))
        XCTAssertEqual(outcome, .credited)
        XCTAssertEqual(server.paid, ["jws-1"])
        XCTAssertEqual(ledger.finished, [1])
        XCTAssertTrue(ledger.unfinished.isEmpty)
        XCTAssertEqual(balance, server.amount)
    }

    /// The server cannot be reached: the transaction stays open; the next launch pays it and finishes it.
    func testAPackTheServerMissedIsPaidAtTheNextLaunch() async {
        let server = FakeServer(), ledger = FakeLedger()
        server.failing = URLError(.notConnectedToInternet)
        let sync = sync(server, ledger)
        let bought = ledger.buy(7)
        let outcome = await StorePurchase.credit(pack, store: store(.success(settle: { await sync.settle(bought) }), current: nil))
        XCTAssertEqual(outcome, .awaitingServer)
        XCTAssertEqual(ledger.finished, [], "not finished while unpaid")
        XCTAssertEqual(Array(ledger.unfinished.keys), [7])

        // Still down at a foreground: kept again.
        await sync.redeemPending()
        XCTAssertEqual(ledger.finished, [])

        // The next launch, server back.
        server.failing = nil
        await sync.redeemPending()
        XCTAssertEqual(server.paid, ["jws-7"])
        XCTAssertEqual(ledger.finished, [7])
        XCTAssertTrue(ledger.unfinished.isEmpty)
    }

    /// Signed out (or another account's purchase): kept for the buyer to sign in.
    func testAPackIsKeptWhileSignedOut() async {
        let server = FakeServer(), ledger = FakeLedger()
        server.failing = AIError.server(code: "SIGN_IN_REQUIRED", info: [:])
        let sync = sync(server, ledger)
        let settled = await sync.settle(ledger.buy(3))
        XCTAssertFalse(settled)
        server.failing = DesktopRuntimeError("x", code: "purchase_owned_by_another_account")
        await sync.redeemPending()
        XCTAssertEqual(ledger.finished, [])
    }

    /// One pack is never paid twice: a purchase and the launch's retry meeting send it once, a finished
    /// pack is not sent again, and a repeat the server already paid (the app quit before finishing) pays nothing.
    func testAPackIsNeverPaidTwice() async {
        let server = FakeServer(), ledger = FakeLedger()
        let sync = sync(server, ledger)
        server.delay = .milliseconds(200)
        let bought = ledger.buy(9)
        async let first = sync.settle(bought)
        async let second = sync.settle(ledger.pack(9))
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1, "the second, while the first is in flight, is not sent")
        XCTAssertEqual(server.requests.filter { $0 == "redeem" }.count, 1)
        await sync.redeemPending()
        XCTAssertEqual(server.requests.filter { $0 == "redeem" }.count, 1, "finished: not in the unfinished list again")

        // Paid, but the app quit before finish(): the retry sends the same transaction; the server pays it once.
        let crashed = ledger.buy(10)
        server.delay = nil
        _ = try? await server.post(["action": "redeem", "transaction": crashed.jws])
        await sync.redeemPending()
        XCTAssertEqual(server.paid.filter { $0 == "jws-10" }.count, 1)
        XCTAssertEqual(ledger.finished, [9, 10])
    }

    /// A pack refunded before it was paid: the server refuses it for good, so it is finished, unpaid.
    func testARefundedPackIsFinishedUnpaid() async {
        let server = FakeServer(), ledger = FakeLedger()
        server.failing = DesktopRuntimeError("x", code: "purchase_revoked")
        let sync = sync(server, ledger)
        _ = ledger.buy(4)
        await sync.redeemPending()
        XCTAssertEqual(ledger.finished, [4])
        XCTAssertEqual(server.paid, [])
    }

    func testCancelAndPendingPacksAreNotSent() async {
        let server = FakeServer(), ledger = FakeLedger()
        _ = sync(server, ledger)
        let cancelled = await StorePurchase.credit(pack, store: store(.cancelled, current: nil))
        let pending = await StorePurchase.credit(pack, store: store(.pending, current: nil))
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(server.requests, [])
        let korean = Locale(identifier: "ko-KR")
        XCTAssertNil(AICreditPurchase.message(.cancelled, korean), "a cancel says nothing")
        XCTAssertEqual(AICreditPurchase.message(.pending, korean), "승인을 기다리고 있어요")
        XCTAssertEqual(AICreditPurchase.message(.credited, korean), "충전했어요")
        XCTAssertEqual(AICreditPurchase.message(.awaitingServer, korean), "결제됐어요. 곧 사용량에 더해져요.")
    }

    // MARK: Status

    func testStatusLines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(26 * 86_400)
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.plus.monthly", periodEnd: later).lines(now: now), [.renews(later)])
        let trialEnd = now.addingTimeInterval(4.5 * 86_400)
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.pro.monthly", periodEnd: trialEnd, trial: true).lines(now: now),
                       [.trial(daysLeft: 5, ends: trialEnd, renews: true)])
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.pro.monthly", periodEnd: trialEnd, willRenew: false, trial: true).lines(now: now),
                       [.trial(daysLeft: 5, ends: trialEnd, renews: false)], "a trial cancelled ends without a charge")
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.plus.yearly", periodEnd: later, willRenew: false).lines(now: now), [.ends(later)])
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.pro.yearly", periodEnd: later, nextProductID: "app.bandal.ipad.pro.monthly").lines(now: now),
                       [.renews(later), .changes(to: "app.bandal.ipad.pro.monthly", on: later)])
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.pro.yearly", periodEnd: later, willRenew: false, nextProductID: "app.bandal.ipad.plus.monthly").lines(now: now),
                       [.ends(later)], "nothing changes on a renewal that will not happen")
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.plus.monthly", periodEnd: later, nextProductID: "app.bandal.ipad.plus.monthly").scheduledProductID, nil,
                       "renewing into the same product is no change")
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.plus.monthly", periodEnd: later, billingIssue: true).lines(now: now), [.billingIssue])
        XCTAssertEqual(PlanStatus(productID: "app.bandal.ipad.pro.yearly", periodEnd: later).tier, .pro)
        XCTAssertTrue(PlanStatus(productID: "app.bandal.ipad.pro.yearly", periodEnd: later).yearly)
    }
}

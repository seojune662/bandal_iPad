import StoreKit
import XCTest
@testable import Bandal

/// The membership tier from StoreKit's entitlements (design §8.1), without StoreKit itself. StoreKit Testing
/// in the unit-test process got a later, heavy test's host killed in every full run (none without it), and
/// its entitlement reads stall for seconds to minutes here, so purchase, expiry, refunds and restore are
/// checked in the sandbox on a device.
@MainActor
final class MembershipTests: XCTestCase {
    func testEitherPlusPlanGivesPlusUnlessRefunded() {
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.plus.monthly", false)]), .plus)
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.sync.monthly", false), ("app.bandal.ipad.plus.yearly", false)]), .plus)
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.plus.yearly", true)]), .free, "Refunded")
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.sync.monthly", false)]), .free, "The old server-verified product")
        XCTAssertEqual(Membership.tier(of: []), .free)
    }

    /// Pro is the higher level; a refunded Pro falls back to a Plus still held.
    func testProOutranksPlus() {
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.pro.monthly", false)]), .pro)
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.plus.yearly", false), ("app.bandal.ipad.pro.yearly", false)]), .pro)
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.pro.yearly", true), ("app.bandal.ipad.plus.monthly", false)]), .plus)
        XCTAssertTrue(Membership.lifts(.pro))
    }

    /// Out of AI: free or Plus → the plans (Pro picked), Pro → 충전. A task cap opens nothing.
    func testAIRefusalDestinations() {
        XCTAssertEqual(AIUsage.destination("BUDGET_EXHAUSTED", plan: "none"), .plans)
        XCTAssertEqual(AIUsage.destination("BUDGET_EXHAUSTED", plan: "plus"), .plans)
        XCTAssertEqual(AIUsage.destination("BUDGET_EXHAUSTED", plan: "pro"), .credit)
        XCTAssertEqual(AIUsage.destination("TASK_CAP_REACHED", plan: "plus"), .none)
    }

    /// A credit pack is finished only when it can never be paid here again, or was paid.
    func testAPackIsFinishedOnlyWhenPaidOrNeverPayable() {
        XCTAssertEqual(StoreSync.outcome(of: nil), .finish, "paid")
        XCTAssertEqual(StoreSync.outcome(of: DesktopRuntimeError("x", code: "purchase_revoked")), .finish, "refunded before redeem")
        XCTAssertEqual(StoreSync.outcome(of: DesktopRuntimeError("x", code: "apple_product_mismatch")), .finish)
        XCTAssertEqual(StoreSync.outcome(of: DesktopRuntimeError("x", code: "purchase_owned_by_another_account")), .keep, "the buyer may sign in again")
        XCTAssertEqual(StoreSync.outcome(of: DesktopRuntimeError("x", code: "sandbox_tester_required")), .keep)
        XCTAssertEqual(StoreSync.outcome(of: AIError.server(code: "SIGN_IN_REQUIRED", info: [:])), .keep, "signed out")
        XCTAssertEqual(StoreSync.outcome(of: URLError(.notConnectedToInternet)), .keep, "offline")
    }

    func testUsageFollowsTheServerAndResetsOnSignOut() {
        let usage = AIUsage()
        usage.update(["plan": "pro", "trial": true, "percent": 37, "autoQuestionsLeft": 1100, "creditUcents": 5])
        XCTAssertEqual(usage.plan, "pro"); XCTAssertTrue(usage.trial); XCTAssertEqual(usage.percent, 37); XCTAssertEqual(usage.autoQuestionsLeft, 1100)
        usage.update(["percent": 40])
        XCTAssertEqual(usage.plan, "pro", "a partial update keeps the rest")
        usage.reset()
        XCTAssertNil(usage.percent); XCTAssertEqual(usage.plan, "none"); XCTAssertEqual(usage.creditUcents, 0)
    }

    /// Plus lifts the free allowance; so does a StoreKit that has not answered yet.
    func testPlusOrNoAnswerYetLiftsTheFreeAllowance() {
        XCTAssertTrue(Membership.lifts(.plus))
        XCTAssertFalse(Membership.lifts(.free))
        XCTAssertTrue(Membership.lifts(nil))
    }

    /// Signed out nothing is attached and the purchase still goes through; signed in, the 반달 user id goes along.
    func testTheAccountTokenIsTheSignedInIDOrNothing() async {
        let membership = Membership()
        let signedOut = await membership.purchaseOptions()
        XCTAssertTrue(signedOut.isEmpty)
        let user = UUID()
        membership.accountToken = { user }
        let signedIn = await membership.purchaseOptions()
        XCTAssertEqual(signedIn, [.appAccountToken(user)])
    }
}

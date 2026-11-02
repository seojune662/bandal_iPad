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
        XCTAssertEqual(Membership.tier(of: [("app.bandal.ipad.pro.monthly", false)]), .free, "Not on sale")
        XCTAssertEqual(Membership.tier(of: []), .free)
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

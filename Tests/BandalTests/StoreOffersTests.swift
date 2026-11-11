import XCTest
@testable import Bandal

/// The paywall's numbers and buttons, from plain offers (no StoreKit).
final class StoreOffersTests: XCTestCase {
    private func offer(_ id: String, _ price: Decimal, trial: Int? = nil) -> StoreOffer {
        StoreOffer(id: id, displayPrice: "₩\(price)", price: price, yearly: id.hasSuffix("yearly"), trialDays: trial, product: nil)
    }
    private lazy var kor = [
        offer("app.bandal.ipad.plus.monthly", 1500), offer("app.bandal.ipad.plus.yearly", 11000),
        offer("app.bandal.ipad.pro.monthly", 4500), offer("app.bandal.ipad.pro.yearly", 29000),
    ]

    /// Plus 1 − 11,000 / 18,000 = 38.9 % → 39, Pro 1 − 29,000 / 54,000 = 46.3 % → 46; the badge shows the larger.
    func testYearlySavingIsTheBestPlanRounded() {
        XCTAssertEqual(StoreOffers.yearlySaving(kor), 46)
        XCTAssertEqual(StoreOffers.yearlySaving(Array(kor.prefix(2))), 39)
        XCTAssertNil(StoreOffers.yearlySaving([offer("app.bandal.ipad.plus.monthly", 1500)]), "no yearly price")
        XCTAssertNil(StoreOffers.yearlySaving([offer("app.bandal.ipad.plus.monthly", 1000), offer("app.bandal.ipad.plus.yearly", 12000)]), "no saving")
    }

    func testCardButtonFollowsTheCurrentPlan() {
        let plusYearly = offer("app.bandal.ipad.plus.yearly", 11000, trial: 7)
        let proYearly = offer("app.bandal.ipad.pro.yearly", 29000, trial: 7)
        let proNoTrial = offer("app.bandal.ipad.pro.yearly", 29000)
        XCTAssertEqual(StoreOffers.action(for: plusYearly, currentProduct: nil, tier: .free), .trial(7))
        XCTAssertEqual(StoreOffers.action(for: proNoTrial, currentProduct: nil, tier: .free), .upgrade)
        XCTAssertEqual(StoreOffers.action(for: plusYearly, currentProduct: "app.bandal.ipad.plus.yearly", tier: .plus), .current)
        XCTAssertEqual(StoreOffers.action(for: offer("app.bandal.ipad.plus.monthly", 1500), currentProduct: "app.bandal.ipad.plus.yearly", tier: .plus), .change, "period change")
        XCTAssertEqual(StoreOffers.action(for: proYearly, currentProduct: "app.bandal.ipad.plus.yearly", tier: .plus), .trial(7), "upgrade with a trial left")
        XCTAssertEqual(StoreOffers.action(for: plusYearly, currentProduct: "app.bandal.ipad.pro.yearly", tier: .pro), .change, "downgrade")
    }

    func testCurrentProductIsTheHighestUnrefundedSubscription() {
        XCTAssertEqual(Membership.product(of: [("app.bandal.ipad.plus.yearly", false), ("app.bandal.ipad.pro.monthly", false)]), "app.bandal.ipad.pro.monthly")
        XCTAssertEqual(Membership.product(of: [("app.bandal.ipad.pro.monthly", true), ("app.bandal.ipad.plus.monthly", false)]), "app.bandal.ipad.plus.monthly")
        XCTAssertNil(Membership.product(of: [("app.bandal.ipad.credit.pack1", false)]))
    }
}

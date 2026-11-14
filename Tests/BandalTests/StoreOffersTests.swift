import XCTest
@testable import Bandal

/// The 요금제 screen's numbers and buttons, from plain offers (no StoreKit).
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
        XCTAssertEqual(StoreOffers.saving(for: .plus, in: kor), 39)
        XCTAssertEqual(StoreOffers.saving(for: .pro, in: kor), 46)
        XCTAssertNil(StoreOffers.yearlySaving([offer("app.bandal.ipad.plus.monthly", 1500)]), "no yearly price")
        XCTAssertNil(StoreOffers.yearlySaving([offer("app.bandal.ipad.plus.monthly", 1000), offer("app.bandal.ipad.plus.yearly", 12000)]), "no saving")
    }

    /// The group's levels decide the button: an upgrade starts now, a downgrade or another period of the
    /// same plan waits for renewal (monthly to yearly is offered as such), a booked change says so.
    func testCardButtonFollowsTheCurrentPlan() {
        let plusMonthly = offer("app.bandal.ipad.plus.monthly", 1500, trial: 7), plusYearly = offer("app.bandal.ipad.plus.yearly", 11000, trial: 7)
        let proMonthly = offer("app.bandal.ipad.pro.monthly", 4500), proYearly = offer("app.bandal.ipad.pro.yearly", 29000, trial: 7)
        let proNoTrial = offer("app.bandal.ipad.pro.yearly", 29000)
        // Free.
        XCTAssertEqual(StoreOffers.action(for: plusYearly, currentProduct: nil, tier: .free), .trial(7))
        XCTAssertEqual(StoreOffers.action(for: proNoTrial, currentProduct: nil, tier: .free), .upgrade)
        // Plus monthly.
        XCTAssertEqual(StoreOffers.action(for: plusMonthly, currentProduct: plusMonthly.id, tier: .plus), .current)
        XCTAssertEqual(StoreOffers.action(for: plusYearly, currentProduct: plusMonthly.id, tier: .plus), .toYearly, "monthly to yearly")
        XCTAssertEqual(StoreOffers.action(for: proMonthly, currentProduct: plusMonthly.id, tier: .plus), .upgrade)
        XCTAssertEqual(StoreOffers.action(for: proYearly, currentProduct: plusMonthly.id, tier: .plus), .trial(7), "upgrade with a trial left")
        // Plus yearly.
        XCTAssertEqual(StoreOffers.action(for: plusMonthly, currentProduct: plusYearly.id, tier: .plus), .atRenewal, "yearly to monthly")
        // Pro.
        XCTAssertEqual(StoreOffers.action(for: plusYearly, currentProduct: proMonthly.id, tier: .pro), .atRenewal, "downgrade")
        XCTAssertEqual(StoreOffers.action(for: plusMonthly, currentProduct: proYearly.id, tier: .pro), .atRenewal, "downgrade")
        XCTAssertEqual(StoreOffers.action(for: proYearly, currentProduct: proMonthly.id, tier: .pro), .toYearly)
        // A change booked for renewal.
        XCTAssertEqual(StoreOffers.action(for: proMonthly, currentProduct: proYearly.id, tier: .pro, scheduledProduct: proMonthly.id), .scheduled)
        XCTAssertEqual(StoreOffers.action(for: plusMonthly, currentProduct: proYearly.id, tier: .pro, scheduledProduct: proMonthly.id), .atRenewal)
    }

    func testCurrentProductIsTheHighestUnrefundedSubscription() {
        XCTAssertEqual(Membership.product(of: [("app.bandal.ipad.plus.yearly", false), ("app.bandal.ipad.pro.monthly", false)]), "app.bandal.ipad.pro.monthly")
        XCTAssertEqual(Membership.product(of: [("app.bandal.ipad.pro.monthly", true), ("app.bandal.ipad.plus.monthly", false)]), "app.bandal.ipad.plus.monthly")
        XCTAssertNil(Membership.product(of: [("app.bandal.ipad.credit.pack1", false)]))
    }

    /// Prices that did not load are a failure the screen says, never cards without a price.
    func testAStorefrontMissingAProductIsAFailure() throws {
        let ids = kor.map(\.id)
        XCTAssertEqual(try StoreOffers.complete(kor, ids: ids).count, 4)
        XCTAssertThrowsError(try StoreOffers.complete(Array(kor.dropLast()), ids: ids), "one missing")
        XCTAssertThrowsError(try StoreOffers.complete([], ids: ids), "none at all (offline)")
        XCTAssertThrowsError(try StoreOffers.complete([], ids: [StoreSync.creditPack]), "the pack")
    }

    /// The labels the cards show.
    func testCardLabels() {
        let korean = Locale(identifier: "ko-KR")
        XCTAssertEqual(MembershipPaywall.label(.current, korean), "현재 요금제")
        XCTAssertEqual(MembershipPaywall.label(.trial(7), korean), "7일 무료 체험 시작")
        XCTAssertEqual(MembershipPaywall.label(.upgrade, korean), "업그레이드")
        XCTAssertEqual(MembershipPaywall.label(.toYearly, korean), "연간으로 변경")
        XCTAssertEqual(MembershipPaywall.label(.atRenewal, korean), "다음 갱신일에 변경")
        XCTAssertEqual(MembershipPaywall.label(.scheduled, korean), "변경 예약됨")
        XCTAssertEqual(MembershipPaywall.fullName("app.bandal.ipad.plus.yearly", korean), "반달 플러스 · 연간")
        XCTAssertEqual(MembershipPaywall.shortName("app.bandal.ipad.pro.monthly", korean), "프로 월간")
        let english = Locale(identifier: "en-US")
        XCTAssertEqual(MembershipPaywall.label(.trial(7), english), "Start 7-day free trial")
        XCTAssertEqual(MembershipPaywall.fullName("app.bandal.ipad.pro.monthly", english), "Bandal Pro · Monthly")
    }
}

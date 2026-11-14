import Foundation
import StoreKit

/// One App Store product as the 요금제 screen and the credit popover show it. Every price on screen is
/// StoreKit's `displayPrice` for the device's storefront; nothing is typed in or converted here.
struct StoreOffer: Identifiable, Equatable {
    let id: String
    let displayPrice: String
    let price: Decimal
    /// Subscriptions: yearly or monthly. Nil for the credit pack.
    let yearly: Bool?
    /// Days of free trial this Apple ID can still start (nil: none offered or already used).
    let trialDays: Int?
    let product: Product?

    var tier: Membership.Tier? { Membership.products[id] }

    static func == (a: StoreOffer, b: StoreOffer) -> Bool {
        a.id == b.id && a.displayPrice == b.displayPrice && a.price == b.price && a.yearly == b.yearly && a.trialDays == b.trialDays
    }
}

enum StoreOffers {
    enum LoadError: Error { case empty }

    /// Loads the products; throws when StoreKit returns none (offline, storefront without them).
    static func load(_ ids: [String]) async throws -> [StoreOffer] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-store-unavailable") { throw LoadError.empty }
        if let fixture = await fixture { return fixture.filter { ids.contains($0.id) } }
        #endif
        var offers: [StoreOffer] = []
        for product in try await Product.products(for: ids) {
            offers.append(StoreOffer(id: product.id, displayPrice: product.displayPrice, price: product.price,
                                     yearly: product.subscription.map { $0.subscriptionPeriod.unit == .year },
                                     trialDays: await trialDays(product), product: product))
        }
        return try complete(offers, ids: ids)
    }

    /// A storefront missing any of them is a failure, not a card without a price.
    static func complete(_ offers: [StoreOffer], ids: [String]) throws -> [StoreOffer] {
        guard !offers.isEmpty, Set(offers.map(\.id)) == Set(ids) else { throw LoadError.empty }
        return offers
    }

    private static func trialDays(_ product: Product) async -> Int? {
        guard let subscription = product.subscription, let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial,
              await subscription.isEligibleForIntroOffer else { return nil }
        let period = offer.period
        switch period.unit {
        case .day: return period.value
        case .week: return period.value * 7
        case .month: return period.value * 30
        case .year: return period.value * 365
        @unknown default: return nil
        }
    }

    /// "최대 N% 할인": the best yearly saving against twelve months, rounded; nil when there is none.
    static func yearlySaving(_ offers: [StoreOffer]) -> Int? {
        [Membership.Tier.plus, .pro].compactMap { saving(for: $0, in: offers) }.max()
    }

    /// One plan's yearly price against twelve of its months, in whole percent; nil without a saving.
    static func saving(for tier: Membership.Tier, in offers: [StoreOffer]) -> Int? {
        guard let monthly = offers.first(where: { $0.tier == tier && $0.yearly == false })?.price,
              let yearly = offers.first(where: { $0.tier == tier && $0.yearly == true })?.price, monthly > 0 else { return nil }
        let saving = Int((NSDecimalNumber(decimal: 1 - yearly / (monthly * 12)).doubleValue * 100).rounded())
        return saving > 0 ? saving : nil
    }

    /// The card's button for a paid plan, judged against what this Apple ID has now. The group's levels
    /// (Pro 1, Plus 2) decide when a change applies: an upgrade at once, a downgrade or another period
    /// of the same plan at the next renewal (Apple's crossgrade with a different duration).
    enum Action: Equatable {
        case current, trial(Int), upgrade
        /// Monthly to yearly on the same plan.
        case toYearly
        /// A downgrade, or yearly to monthly.
        case atRenewal
        /// Already booked for the next renewal.
        case scheduled
    }
    static func action(for offer: StoreOffer, currentProduct: String?, tier: Membership.Tier, scheduledProduct: String? = nil) -> Action {
        if offer.id == currentProduct { return .current }
        if offer.id == scheduledProduct { return .scheduled }
        guard let target = offer.tier else { return .atRenewal }
        if target > tier { return offer.trialDays.map(Action.trial) ?? .upgrade }
        if target == tier, offer.yearly == true, let currentProduct, !PlanStatus.yearly(currentProduct) { return .toYearly }
        return .atRenewal
    }

    #if DEBUG
    static let fixtureEnabled = ProcessInfo.processInfo.arguments.contains("--native-store-fixture")
    /// `--native-store-fixture`: the App Store Connect KOR prices (2026-11-07), for UI tests and the
    /// review screenshots, where the simulator has no App Store products. With `--plans-state` the trial is
    /// offered while the simulated Apple ID has not used it.
    @MainActor static var fixture: [StoreOffer]? {
        guard fixtureEnabled else { return nil }
        let trial = PlansStoreSimulator.active ? PlansStoreSimulator.shared.trialDays : 7
        return [
            .init(id: "app.bandal.ipad.plus.monthly", displayPrice: "₩1,500", price: 1500, yearly: false, trialDays: trial, product: nil),
            .init(id: "app.bandal.ipad.plus.yearly", displayPrice: "₩11,000", price: 11000, yearly: true, trialDays: trial, product: nil),
            .init(id: "app.bandal.ipad.pro.monthly", displayPrice: "₩4,500", price: 4500, yearly: false, trialDays: trial, product: nil),
            .init(id: "app.bandal.ipad.pro.yearly", displayPrice: "₩29,000", price: 29000, yearly: true, trialDays: trial, product: nil),
            .init(id: StoreSync.creditPack, displayPrice: "₩5,500", price: 5500, yearly: nil, trialDays: nil, product: nil),
        ]
    }
    #endif
}

import Foundation
import StoreKit

/// One App Store product as the paywall and the credit popover show it. Every price on screen is
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
        if let fixture { return fixture.filter { ids.contains($0.id) } }
        #endif
        var offers: [StoreOffer] = []
        for product in try await Product.products(for: ids) {
            offers.append(StoreOffer(id: product.id, displayPrice: product.displayPrice, price: product.price,
                                     yearly: product.subscription.map { $0.subscriptionPeriod.unit == .year },
                                     trialDays: await trialDays(product), product: product))
        }
        guard !offers.isEmpty else { throw LoadError.empty }
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
        let savings = [Membership.Tier.plus, .pro].compactMap { tier -> Int? in
            guard let monthly = offers.first(where: { $0.tier == tier && $0.yearly == false })?.price,
                  let yearly = offers.first(where: { $0.tier == tier && $0.yearly == true })?.price, monthly > 0 else { return nil }
            let saving = NSDecimalNumber(decimal: 1 - yearly / (monthly * 12)).doubleValue * 100
            return Int(saving.rounded())
        }
        return savings.max().flatMap { $0 > 0 ? $0 : nil }
    }

    /// The card's button for a paid plan, judged against what this Apple ID has now.
    enum Action: Equatable { case current, trial(Int), upgrade, change }
    static func action(for offer: StoreOffer, currentProduct: String?, tier: Membership.Tier) -> Action {
        if offer.id == currentProduct { return .current }
        guard let target = offer.tier, target > tier else { return .change }
        if let days = offer.trialDays { return .trial(days) }
        return .upgrade
    }

    #if DEBUG
    /// `--native-store-fixture`: the App Store Connect KOR prices (2026-11-07), for UI tests and the
    /// review screenshots, where the simulator has no App Store products.
    static let fixture: [StoreOffer]? = ProcessInfo.processInfo.arguments.contains("--native-store-fixture") ? [
        .init(id: "app.bandal.ipad.plus.monthly", displayPrice: "₩1,500", price: 1500, yearly: false, trialDays: 7, product: nil),
        .init(id: "app.bandal.ipad.plus.yearly", displayPrice: "₩11,000", price: 11000, yearly: true, trialDays: 7, product: nil),
        .init(id: "app.bandal.ipad.pro.monthly", displayPrice: "₩4,500", price: 4500, yearly: false, trialDays: 7, product: nil),
        .init(id: "app.bandal.ipad.pro.yearly", displayPrice: "₩29,000", price: 29000, yearly: true, trialDays: 7, product: nil),
        .init(id: StoreSync.creditPack, displayPrice: "₩5,500", price: 5500, yearly: nil, trialDays: nil, product: nil),
    ] : nil
    #endif
}

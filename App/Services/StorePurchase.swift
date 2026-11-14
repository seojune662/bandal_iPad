import Foundation
import StoreKit

/// One purchase from the 요금제 screen or a 충전 button, and what it came to. Both places buy through here,
/// so a plan and a credit pack are settled the same way: a subscription is finished at once, a credit pack
/// only after the server paid it (StoreSync); an unfinished pack is redeemed again at the next launch.
@MainActor
enum StorePurchase {
    /// What `Product.purchase` returned, without StoreKit's types: tests drive the flow with their own.
    enum Step {
        /// Paid. `settle` checks the signature, tells the server (a pack) and finishes; false when it could not.
        case success(settle: () async -> Bool)
        /// Waiting for approval (Ask to Buy, or a bank's confirmation): it arrives later through `Transaction.updates`.
        case pending
        case cancelled
    }

    /// The seams of a purchase: StoreKit, the membership refresh and the server sync.
    struct Store {
        var purchase: (StoreOffer) async throws -> Step
        /// Re-reads the entitlements; returns the subscription now in effect.
        var refresh: () async -> String?
        var syncSubscriptions: () async -> Void
    }

    /// The App Store; in a UI test with `--plans-state`, the simulated one.
    static var live: Store {
        #if DEBUG
        if PlansStoreSimulator.active { return PlansStoreSimulator.shared.store }
        #endif
        return appStore
    }

    private static let appStore = Store(
        purchase: { offer in
            // A fixture offer (`--native-store-fixture`) has no product: nothing to buy.
            guard let product = offer.product else { return .cancelled }
            do {
                switch try await product.purchase(options: await Membership.shared.purchaseOptions()) {
                case .success(let verification): return .success(settle: { await Membership.settle(verification) })
                case .pending: return .pending
                case .userCancelled: return .cancelled
                @unknown default: return .cancelled
                }
            } catch StoreKitError.userCancelled { return .cancelled }
        },
        refresh: { await Membership.shared.refresh(); return Membership.shared.currentProduct },
        syncSubscriptions: { await StoreSync.shared.syncSubscriptions() })

    enum PlanOutcome: Equatable {
        /// In effect now (a first subscription, a trial, an upgrade).
        case started(Membership.Tier)
        /// Booked for the next renewal (a downgrade or a change of period).
        case scheduled(productID: String)
        case pending, cancelled
        /// StoreKit could not verify the transaction; restore later.
        case unverified
        case failed(String)
    }

    static func plan(_ offer: StoreOffer, store: Store? = nil) async -> PlanOutcome {
        guard let tier = offer.tier else { return .failed("") }
        let store = store ?? live
        do {
            switch try await store.purchase(offer) {
            case .cancelled: return .cancelled
            case .pending: return .pending
            case .success(let settle):
                guard await settle() else { return .unverified }
                let current = await store.refresh()
                // Purchases made here do not come through Transaction.updates: tell the server now.
                await store.syncSubscriptions()
                return current == offer.id ? .started(tier) : .scheduled(productID: offer.id)
            }
        } catch { return .failed(error.localizedDescription) }
    }

    enum CreditOutcome: Equatable {
        /// The server paid it and the transaction is finished.
        case credited
        /// Paid at the App Store, not yet by the server: the transaction stays open and is redeemed again.
        case awaitingServer
        case pending, cancelled
        case failed(String)
    }

    static func credit(_ offer: StoreOffer, store: Store? = nil) async -> CreditOutcome {
        let store = store ?? live
        do {
            switch try await store.purchase(offer) {
            case .cancelled: return .cancelled
            case .pending: return .pending
            case .success(let settle): return await settle() ? .credited : .awaitingServer
            }
        } catch { return .failed(error.localizedDescription) }
    }
}

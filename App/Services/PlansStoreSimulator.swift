#if DEBUG
import Foundation

/// `--plans-state <name>`: a stand-in for the App Store in UI tests, so 요금제's buttons can be pressed without
/// StoreKit (xcodebuild cannot load Tests/StoreKit/Bandal.storekit on this simulator; the BandalStoreKit scheme
/// does in Xcode). It starts in the named state and follows Apple's rules for the group's levels: a first
/// subscription takes the free trial once, an upgrade is in effect at once, a downgrade or another period is
/// booked for renewal. `--plans-store-mode cancel|ask` makes every purchase cancelled or wait for approval
/// (Ask to Buy). A 충전 is an unfinished transaction until StoreSync finishes it after the server paid; open ones
/// survive a relaunch (UserDefaults, cleared by `--reset-native-ui-testing`), as StoreKit's do.
@MainActor
final class PlansStoreSimulator {
    static let shared = PlansStoreSimulator()
    static var active: Bool { PlanStatus.Fixture.active }

    private(set) var status: PlanStatus?
    private var trialUsed: Bool
    private let mode: String?
    private static let unfinishedKey = "plans.sim.unfinished", nextKey = "plans.sim.next"

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        status = PlanStatus.Fixture.initial
        // Whoever holds a subscription already had the group's one introductory offer.
        trialUsed = status != nil
        mode = arguments.firstIndex(of: "--plans-store-mode").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        if arguments.contains("--reset-native-ui-testing") {
            for key in [Self.unfinishedKey, Self.nextKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// The trial this "Apple ID" can still start.
    var trialDays: Int? { trialUsed ? nil : 7 }

    var store: StorePurchase.Store {
        StorePurchase.Store(purchase: { [unowned self] offer in self.purchase(offer) },
                            refresh: { [unowned self] in self.status?.productID },
                            syncSubscriptions: { await StoreSync.shared.syncSubscriptions() })
    }

    private func purchase(_ offer: StoreOffer) -> StorePurchase.Step {
        switch mode {
        case "cancel": return .cancelled
        case "ask": return .pending
        default: break
        }
        if offer.id == StoreSync.creditPack {
            let id = UInt64(UserDefaults.standard.integer(forKey: Self.nextKey) + 1)
            UserDefaults.standard.set(Int(id), forKey: Self.nextKey)
            unfinished.append(id)
            let pack = self.pack(id)
            return .success(settle: { await StoreSync.shared.settle(pack) })
        }
        guard let target = offer.tier else { return .cancelled }
        let now = Date(), period: TimeInterval = (offer.yearly == true ? 365 : 30) * 86_400
        if let current = status, target <= current.tier {
            status = PlanStatus(productID: current.productID, periodEnd: current.periodEnd, willRenew: true, trial: current.trial, nextProductID: offer.id)
        } else {
            let trial = !trialUsed && offer.trialDays != nil
            status = PlanStatus(productID: offer.id, periodEnd: now.addingTimeInterval(trial ? 7 * 86_400 : period), trial: trial)
            trialUsed = true
        }
        return .success(settle: { true })
    }

    // MARK: Credit packs as StoreKit's unfinished transactions

    private var unfinished: [UInt64] {
        get { (UserDefaults.standard.array(forKey: Self.unfinishedKey) as? [Int] ?? []).map(UInt64.init) }
        set { UserDefaults.standard.set(newValue.map(Int.init), forKey: Self.unfinishedKey) }
    }

    /// StoreSync's view of `Transaction.unfinished` while simulating.
    func unfinishedPacks() -> [StoreSync.Pack] { unfinished.map(pack) }

    private func pack(_ id: UInt64) -> StoreSync.Pack {
        // A JWS whose payload names the transaction, as the server reads it.
        let payload = try? JSONSerialization.data(withJSONObject: ["transactionId": "\(id)", "productId": StoreSync.creditPack])
        let jws = "e30." + (payload?.base64EncodedString() ?? "").replacingOccurrences(of: "=", with: "") + ".sig"
        return StoreSync.Pack(id: id, jws: jws) { [weak self] in self?.unfinished.removeAll { $0 == id } }
    }
}
#endif

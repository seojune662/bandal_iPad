import Foundation
import StoreKit

/// The subscription in effect, as the 요금제 screen and Settings › 구독·사용량 describe it: plan and period,
/// when it renews or ends, a free trial's days left, and a change booked for the next renewal. Read from
/// StoreKit (`Transaction.currentEntitlements` and the group's `Product.SubscriptionInfo.Status`), whose
/// renewal info carries auto-renew and the product the next period switches to.
struct PlanStatus: Equatable {
    let productID: String
    /// Where the current period ends: the next charge when it renews, the last day when it does not.
    let periodEnd: Date?
    let willRenew: Bool
    /// In the introductory free period.
    let trial: Bool
    /// The product the next renewal switches to (a downgrade or a change of period), nil when it stays.
    let nextProductID: String?
    /// The App Store could not charge the renewal (billing retry or grace period).
    let billingIssue: Bool

    init(productID: String, periodEnd: Date?, willRenew: Bool = true, trial: Bool = false, nextProductID: String? = nil, billingIssue: Bool = false) {
        self.productID = productID; self.periodEnd = periodEnd; self.willRenew = willRenew; self.trial = trial
        self.nextProductID = nextProductID == productID ? nil : nextProductID; self.billingIssue = billingIssue
    }

    var tier: Membership.Tier { Membership.products[productID] ?? .free }
    var yearly: Bool { Self.yearly(productID) }
    /// A change that will happen: booked and the subscription still renewing.
    var scheduledProductID: String? { willRenew ? nextProductID : nil }

    nonisolated static func yearly(_ productID: String) -> Bool { productID.hasSuffix(".yearly") }

    /// One line under the plan's name.
    enum Line: Equatable {
        case renews(Date)
        case trial(daysLeft: Int, ends: Date, renews: Bool)
        /// Auto-renew is off: the last day.
        case ends(Date)
        /// From the next renewal, this product.
        case changes(to: String, on: Date)
        case billingIssue
    }

    func lines(now: Date = Date()) -> [Line] {
        if billingIssue { return [.billingIssue] }
        guard let periodEnd else { return [] }
        var lines: [Line] = []
        if trial {
            let days = max(0, Int((periodEnd.timeIntervalSince(now) / 86_400).rounded(.up)))
            lines.append(.trial(daysLeft: days, ends: periodEnd, renews: willRenew))
        } else if willRenew {
            lines.append(.renews(periodEnd))
        } else {
            lines.append(.ends(periodEnd))
        }
        if let next = scheduledProductID { lines.append(.changes(to: next, on: periodEnd)) }
        return lines
    }

    /// The live status; nil without a paid subscription (and in a UI test's `--plans-state free`).
    @MainActor static func load() async -> PlanStatus? {
        #if DEBUG
        if Fixture.active { return Fixture.status }
        #endif
        var current: Transaction?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil, !transaction.isUpgraded,
                  let tier = Membership.products[transaction.productID] else { continue }
            if current.map({ tier > Membership.products[$0.productID] ?? .free }) ?? true { current = transaction }
        }
        guard let transaction = current else { return nil }
        var willRenew = true, next: String?, billing = false
        if let group = transaction.subscriptionGroupID, let statuses = try? await Product.SubscriptionInfo.status(for: group) {
            let status = statuses.first { status in
                guard case .verified(let latest) = status.transaction else { return false }
                return latest.originalID == transaction.originalID
            } ?? statuses.first
            if let status {
                billing = status.state == .inBillingRetryPeriod || status.state == .inGracePeriod
                if case .verified(let renewal) = status.renewalInfo {
                    willRenew = renewal.willAutoRenew
                    next = renewal.autoRenewPreference
                }
            }
        }
        let trial = transaction.offer?.type == .introductory && transaction.offer?.paymentMode == .freeTrial
        return PlanStatus(productID: transaction.productID, periodEnd: transaction.expirationDate, willRenew: willRenew,
                          trial: trial, nextProductID: next, billingIssue: billing)
    }

    #if DEBUG
    /// `--plans-state <name>`: the subscription a UI test starts from, without StoreKit; purchases then change
    /// it (PlansStoreSimulator). free · plus-monthly · plus-yearly · pro · trial · canceled · scheduled · billing.
    enum Fixture {
        static let name: String? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--plans-state"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }()
        static var active: Bool { name != nil }
        /// The start of the day `days` from today: "N일 남음" reads the same all day.
        private static func day(_ days: Int) -> Date {
            Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date()))!
        }
        @MainActor static var status: PlanStatus? { PlansStoreSimulator.shared.status }
        static var initial: PlanStatus? {
            switch name {
            case "plus-monthly": PlanStatus(productID: "app.bandal.ipad.plus.monthly", periodEnd: day(26))
            case "plus-yearly": PlanStatus(productID: "app.bandal.ipad.plus.yearly", periodEnd: day(200))
            case "pro": PlanStatus(productID: "app.bandal.ipad.pro.monthly", periodEnd: day(26))
            case "trial": PlanStatus(productID: "app.bandal.ipad.pro.monthly", periodEnd: day(5), trial: true)
            case "canceled": PlanStatus(productID: "app.bandal.ipad.plus.yearly", periodEnd: day(40), willRenew: false)
            case "scheduled": PlanStatus(productID: "app.bandal.ipad.pro.yearly", periodEnd: day(60), nextProductID: "app.bandal.ipad.pro.monthly")
            case "billing": PlanStatus(productID: "app.bandal.ipad.plus.monthly", periodEnd: day(3), billingIssue: true)
            default: nil
            }
        }
    }
    #endif
}

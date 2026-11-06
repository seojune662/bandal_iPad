import StoreKit
import os

/// Reports App Store purchases to the Bandal server (ipad-store), which decides the AI plan and
/// pays credit packs. Subscriptions keep working on the device without it (Membership); only the
/// server-side AI budget depends on it. Nothing is sent while signed out.
@MainActor
final class StoreSync {
    static let shared = StoreSync()
    nonisolated static let creditPack = "app.bandal.ipad.credit.pack1"
    /// `ipad-store` call for the signed-in account; nil while signed out.
    var post: (([String: Any]) async throws -> [String: Any])?
    /// The AI status the server returned (plan, budget, credit).
    var onStatus: ([String: Any]) -> Void = { _ in }
    private var account: String?

    /// Purchases made while signed out (or by another account on this iPad) reach the server once
    /// someone signs in; repeated account events for the same user do nothing.
    func accountChanged(_ user: String?) {
        guard user != account else { return }
        account = user
        guard user != nil else { return }
        Task { await syncSubscriptions(); await redeemPending() }
    }

    /// Sends every current subscription transaction. Runs one at a time so an older snapshot is
    /// never the last write. A failed sync only leaves the server's plan as it was until the next one.
    func syncSubscriptions() async {
        let previous = syncing
        let next = Task { [weak self] in
            await previous?.value
            guard let self, let post = self.post else { return }
            var signed: [String] = []
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, transaction.productType == .autoRenewable { signed.append(result.jwsRepresentation) }
            }
            do { self.onStatus(try await post(["action": "sync", "transactions": Array(signed.prefix(20))])) }
            catch { Self.log.error("ipad-store sync failed: \(error.localizedDescription, privacy: .public)") }
        }
        syncing = next
        await next.value
    }
    private var syncing: Task<Void, Never>?
    private var redeeming: Set<UInt64> = []

    /// What to do with a pack transaction after asking the server.
    enum Outcome: Equatable { case finish, keep }
    /// Paid (or already paid), refunded, or not a pack at all: finish. Signed out, another account's
    /// purchase on this iPad, or the server unreachable: keep it for the next launch, foreground or sign-in.
    static func outcome(of error: Error?) -> Outcome {
        guard let error else { return .finish }
        switch (error as? DesktopRuntimeError)?.code {
        case "purchase_revoked", "apple_product_mismatch", "invalid_apple_data": return .finish
        default: return .keep
        }
    }

    /// Redeems one credit pack. Returns true when the transaction may be finished.
    func redeem(_ result: VerificationResult<Transaction>) async -> Bool {
        guard let post, case .verified(let transaction) = result, transaction.productID == Self.creditPack,
              redeeming.insert(transaction.id).inserted else { return false }
        defer { redeeming.remove(transaction.id) }
        var failure: Error?
        do { onStatus(try await post(["action": "redeem", "transaction": result.jwsRepresentation])) }
        catch {
            failure = error
            Self.log.error("ipad-store redeem failed: \(error.localizedDescription, privacy: .public)")
        }
        return Self.outcome(of: failure) == .finish
    }

    /// Credit packs bought while the server could not be reached, or before signing in.
    func redeemPending() async {
        guard post != nil else { return }
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result, transaction.productID == Self.creditPack else { continue }
            if await redeem(result) { await transaction.finish() }
        }
    }

    private static let log = Logger(subsystem: "app.bandal.ipad", category: "store-sync")
}

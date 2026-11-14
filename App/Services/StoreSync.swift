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
    /// Credit packs StoreKit has not had finished yet (`Transaction.unfinished`); tests hand in their own.
    var unfinishedPacks: () async -> [Pack] = {
        var packs: [Pack] = []
        for await result in Transaction.unfinished { if let pack = Pack(result) { packs.append(pack) } }
        return packs
    }
    private var account: String?

    /// One credit pack transaction as the server needs it: its id, the signed JWS, and how to finish it.
    struct Pack {
        let id: UInt64
        let jws: String
        let finish: () async -> Void
        init(id: UInt64, jws: String, finish: @escaping () async -> Void) { self.id = id; self.jws = jws; self.finish = finish }
        /// A verified transaction of the credit pack; nil for anything else.
        init?(_ result: VerificationResult<Transaction>) {
            guard case .verified(let transaction) = result, transaction.productID == StoreSync.creditPack else { return nil }
            self.init(id: transaction.id, jws: result.jwsRepresentation, finish: { await transaction.finish() })
        }
    }

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
        guard let pack = Pack(result) else { return false }
        return await redeem(pack)
    }

    /// Asks the server to pay one pack. The same transaction is never sent twice at once (a purchase
    /// and the launch's or foreground's retry can meet); the server pays a transaction id only once.
    func redeem(_ pack: Pack) async -> Bool {
        guard let post, redeeming.insert(pack.id).inserted else { return false }
        defer { redeeming.remove(pack.id) }
        var failure: Error?
        do { onStatus(try await post(["action": "redeem", "transaction": pack.jws])) }
        catch {
            failure = error
            Self.log.error("ipad-store redeem failed: \(error.localizedDescription, privacy: .public)")
        }
        return Self.outcome(of: failure) == .finish
    }

    /// Redeems a pack and finishes its transaction once the server has it; otherwise leaves it
    /// unfinished, so StoreKit hands it back at the next launch, foreground or sign-in.
    func settle(_ pack: Pack) async -> Bool {
        guard await redeem(pack) else { return false }
        await pack.finish()
        return true
    }

    /// Credit packs bought while the server could not be reached, or before signing in.
    func redeemPending() async {
        guard post != nil else { return }
        for pack in await unfinishedPacks() { _ = await settle(pack) }
    }

    private static let log = Logger(subsystem: "app.bandal.ipad", category: "store-sync")
}

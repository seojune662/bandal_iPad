import Foundation
import StoreKit
import os

/// 반달 멤버십 (design §8.1): the App Store subscription group "Bandal Membership", judged on this iPad from
/// StoreKit's signed entitlements, which work offline and carry expiry and refunds. Courses and documents
/// need no account. The AI budget is the server's: signed in, transactions are reported to ipad-store
/// (StoreSync), and credit packs are finished only after the server paid them.
@MainActor
final class Membership: ObservableObject {
    /// The group's tiers, lowest first. Plus and Pro differ only in the AI budget.
    enum Tier: Comparable { case free, plus, pro }
    nonisolated static let products: [String: Tier] = [
        "app.bandal.ipad.plus.monthly": .plus, "app.bandal.ipad.plus.yearly": .plus,
        "app.bandal.ipad.pro.monthly": .pro, "app.bandal.ipad.pro.yearly": .pro,
    ]
    static let shared = Membership()
    @Published private(set) var tier = Tier.free
    /// The subscription giving `tier` (the one in effect, not a downgrade waiting for renewal).
    @Published private(set) var currentProduct: String?
    /// The signed-in 반달 user id, sent as `appAccountToken` when there is one. Signed out, purchases go through the same.
    var accountToken: () async -> UUID? = { nil }
    private var updates: Task<Void, Never>?

    /// Whether the free allowance is lifted (Plus or above), read on the storage queue where it is checked.
    /// Until StoreKit has answered once, nothing is refused: a subscriber is not met by the paywall at launch,
    /// and a device whose App Store does not answer is not offered what it cannot buy.
    nonisolated static var unlimited: Bool { forced ?? lifts(entitled.withLock { $0 }) }
    nonisolated static func lifts(_ tier: Tier?) -> Bool { tier.map { $0 >= .plus } ?? true }
    private nonisolated static let entitled = OSAllocatedUnfairLock<Tier?>(initialState: nil)
    /// UI tests make many courses, so they run as Plus; `--native-free-tier` runs them free.
    private nonisolated static let forced: Bool? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--native-ui-testing") else { return nil }
        return !arguments.contains("--native-free-tier")
        #else
        return nil
        #endif
    }()

    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                await Self.settle(update)
                await self?.refresh()
                await StoreSync.shared.syncSubscriptions()
            }
        }
        Task {
            for await result in Transaction.unfinished { await Self.settle(result) }
            await refresh()
            await StoreSync.shared.syncSubscriptions()
        }
    }

    /// Finishes a transaction once it is accounted for: a credit pack only after the server paid it
    /// (otherwise it stays unfinished and is redeemed at the next launch or sign-in).
    /// Returns false for a pack the server has not paid yet.
    @discardableResult
    static func settle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let transaction) = result else { return false }
        if transaction.productType == .consumable {
            guard await StoreSync.shared.redeem(result) else { return false }
        }
        await transaction.finish()
        return true
    }

    func refresh() async {
        var entitlements: [(productID: String, refunded: Bool)] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result { entitlements.append((transaction.productID, transaction.revocationDate != nil)) }
        }
        let tier = Self.tier(of: entitlements)
        self.tier = tier
        currentProduct = Self.product(of: entitlements)
        Self.entitled.withLock { $0 = tier }
    }

    /// The highest tier entitled. StoreKit leaves expired subscriptions out of the current entitlements;
    /// a refund shows as a revocation.
    nonisolated static func tier(of entitlements: [(productID: String, refunded: Bool)]) -> Tier {
        entitlements.filter { !$0.refunded }.compactMap { products[$0.productID] }.max() ?? .free
    }

    nonisolated static func product(of entitlements: [(productID: String, refunded: Bool)]) -> String? {
        entitlements.filter { !$0.refunded && products[$0.productID] != nil }.max { products[$0.productID]! < products[$1.productID]! }?.productID
    }

    func purchaseOptions() async -> Set<Product.PurchaseOption> {
        guard let token = await accountToken() else { return [] }
        return [.appAccountToken(token)]
    }
}

/// The free allowance (design §8.2–8.3, user decisions 2026-10-30 and 11-02): one course and ten documents (PDF or md)
/// made on this iPad. AI is metered on the server (ai-proxy). What arrived through sync does not count, and nothing
/// already here is ever locked; only making more is refused, with `PLUS_REQUIRED`.
enum FreeTier {
    static let courses = 1, documents = 10
    static let code = "PLUS_REQUIRED"

    /// Runs on the storage queue before a channel, with the runtime's library. Sync applies what it receives
    /// without channels, so received courses and documents are never refused.
    static func check(_ channel: String, _ request: [String: Any], library: NativeLibraryRepository) throws {
        let makesCourse = ["courses:create", "courses:addFromFolder"].contains(channel)
            || channel == "learning:create" && request["placement"] as? String ?? "standalone" == "standalone"
        if makesCourse, try usage(library: library).courses >= courses {
            throw DesktopRuntimeError("무료로는 이 iPad에서 폴더를 \(courses)개까지 만들 수 있어요.", code: code)
        }
        let adding = try documentsAdded(channel, request, library: library)
        guard adding > 0 else { return }
        let left = documents - (try usage(library: library).documents)
        guard adding > left else { return }
        throw DesktopRuntimeError(left > 0 && adding > 1 ? "무료로는 자료를 \(left)개 더 추가할 수 있어요." : "무료로는 이 iPad에서 자료를 \(documents)개까지 만들 수 있어요.", code: code)
    }

    /// Live courses and documents made on this iPad: everything but what sync created (`origin = 'remote'`).
    static func usage(library: NativeLibraryRepository) throws -> (courses: Int, documents: Int) {
        let context = library.context
        // The index catches up with the disk on a folder walk (as the outbox does before it reads it).
        for row in try context.query("SELECT id FROM courses WHERE deleted_at IS NULL") { _ = try? library.handle("materials:tree", ["courseId": row["id"] ?? ""]) }
        let synced = try !context.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cloud_sync_docs'").isEmpty
        let courses = try context.query("SELECT COUNT(*) AS n FROM courses c WHERE c.deleted_at IS NULL"
            + (synced ? " AND NOT EXISTS (SELECT 1 FROM cloud_sync_courses s WHERE s.local_id=c.id AND s.origin='remote')" : ""))
        let documents = try context.query("""
            SELECT COUNT(*) AS n FROM materials_index m JOIN courses c ON c.id=m.course_id
            WHERE m.deleted_at IS NULL AND c.deleted_at IS NULL AND m.kind IN ('pdf','note')
            """ + (synced ? " AND NOT EXISTS (SELECT 1 FROM cloud_sync_docs d WHERE d.course_id=m.course_id AND d.rel_path=m.rel_path AND d.origin='remote')" : ""))
        return ((courses.first?["n"] as? NSNumber)?.intValue ?? 0, (documents.first?["n"] as? NSNumber)?.intValue ?? 0)
    }

    private static func documentsAdded(_ channel: String, _ request: [String: Any], library: NativeLibraryRepository) throws -> Int {
        func counted(_ name: Any?) -> Bool { ["pdf", "note"].contains(NativeLibraryRepository.kind(for: name as? String ?? "")) }
        switch channel {
        case "notes:create", "pdfNotes:create", "pdf:recoverPagesCopy": return 1
        case "materials:import": return NativeLibraryRepository.importedDocumentCount(request["paths"] as? [String] ?? [])
        case "materials:importShared", "materials:writeFile", "materials:adoptFile": return counted(request["fileName"]) ? 1 : 0
        case "materials:duplicate":
            // A folder copies every document under it.
            guard let course = request["courseId"] as? String, let path = request["relPath"] as? String else { return 0 }
            _ = try? library.handle("materials:tree", ["courseId": course])
            let rows = try library.context.query("""
                SELECT COUNT(*) AS n FROM materials_index WHERE course_id=? AND deleted_at IS NULL AND kind IN ('pdf','note')
                AND (rel_path=? OR substr(rel_path,1,length(?)+1)=?||'/')
                """, [course, path, path, path])
            return (rows.first?["n"] as? NSNumber)?.intValue ?? 0
        default: return 0
        }
    }
}

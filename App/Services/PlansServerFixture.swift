#if DEBUG
import Foundation

/// `--plans-server ok|fail`: a stand-in for `ipad-store` in UI tests, so a 충전 bought through the StoreKit
/// configuration can be paid, refused and paid again without an account or the network. It answers like the
/// real function: `sync` returns the AI status, `redeem` pays a transaction id once (a repeat returns the
/// status without paying again), and `fail` throws as an unreachable server does. What it paid survives a
/// relaunch (UserDefaults, cleared by `--reset-native-ui-testing`), and its counts are on the 충전 card's
/// accessibility value for the test to read.
@MainActor
enum PlansServerFixture {
    static let mode: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--plans-server"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()
    /// `ai_settings.pack_ucents` as seeded (backend/supabase/migrations/202611060001_ai_metering.sql).
    private static let pack: Int64 = 200_000_000
    private static let paidKey = "plans.fixture.server.paid", callsKey = "plans.fixture.server.redeems"

    static var paid: [String] { UserDefaults.standard.stringArray(forKey: paidKey) ?? [] }
    static var redeemCalls: Int { UserDefaults.standard.integer(forKey: callsKey) }
    /// "redeems=2 paid=1": every redeem request so far and the transactions paid.
    static var summary: String? { mode == nil ? nil : "redeems=\(redeemCalls) paid=\(paid.count)" }

    static func install() {
        if PlansStoreSimulator.active {
            // The simulated store's open 충전 transactions stand for StoreKit's; redeemed at launch as those are.
            StoreSync.shared.unfinishedPacks = { PlansStoreSimulator.shared.unfinishedPacks() }
        }
        guard let mode else { return }
        if ProcessInfo.processInfo.arguments.contains("--reset-native-ui-testing") {
            for key in [paidKey, callsKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        var plan = "none"
        StoreSync.shared.post = { body in
            switch body["action"] as? String {
            case "sync":
                let products = (body["transactions"] as? [String] ?? []).compactMap { claims($0)?["productId"] as? String }
                plan = products.compactMap { Membership.products[$0] }.max().map { $0 == .pro ? "pro" : "plus" } ?? "none"
            case "redeem":
                UserDefaults.standard.set(redeemCalls + 1, forKey: callsKey)
                if mode == "fail" { throw URLError(.notConnectedToInternet) }
                guard let jws = body["transaction"] as? String, let id = claims(jws)?["transactionId"].map({ "\($0)" }) else {
                    throw DesktopRuntimeError("x", code: "invalid_apple_data")
                }
                if !paid.contains(id) { UserDefaults.standard.set(paid + [id], forKey: paidKey) }
            default: break
            }
            return ["plan": plan, "trial": false, "percent": 40, "autoQuestionsLeft": 900, "creditUcents": Int64(paid.count) * pack]
        }
        if PlansStoreSimulator.active { Task { await StoreSync.shared.redeemPending() } }
    }

    /// The payload of a StoreKit JWS (header.payload.signature, base64url).
    private static func claims(_ jws: String) -> [String: Any]? {
        let parts = jws.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
#endif

import SwiftUI

/// The server's AI usage for the signed-in account (from ai-proxy config and every answer),
/// shown in Settings › 구독 and the AI panel.
@MainActor
final class AIUsage: ObservableObject {
    static let shared = AIUsage()
    @Published private(set) var plan = "none"
    @Published private(set) var trial = false
    @Published private(set) var percent: Int?
    @Published private(set) var autoQuestionsLeft: Int?
    @Published private(set) var creditUcents: Int64 = 0

    /// Signed out: nothing of the previous account stays on screen.
    func reset() { plan = "none"; trial = false; percent = nil; autoQuestionsLeft = nil; creditUcents = 0 }

    func update(_ usage: [String: Any]) {
        guard !usage.isEmpty else { return }
        plan = usage["plan"] as? String ?? plan
        trial = usage["trial"] as? Bool ?? trial
        percent = (usage["percent"] as? NSNumber)?.intValue ?? percent
        autoQuestionsLeft = (usage["autoQuestionsLeft"] as? NSNumber)?.intValue ?? autoQuestionsLeft
        creditUcents = (usage["creditUcents"] as? NSNumber)?.int64Value ?? creditUcents
    }

    /// Where a refusal sends the user: free → membership (Plus first), Plus → Pro (with a credit link),
    /// Pro → credit. A task cap only stops that task; the chat says so and nothing opens.
    enum Destination: Equatable { case none, membership, upgrade, credit }
    static func destination(_ code: String, plan: String) -> Destination {
        guard code == "BUDGET_EXHAUSTED" else { return .none }
        switch plan { case "pro": return .credit; case "plus": return .upgrade; default: return .membership }
    }

    /// A budget or task-cap refusal from the proxy.
    static func presentLimit(_ code: String, usage: [String: Any]) {
        shared.update(usage)
        let message = AIError.describe(code, usage)
        switch destination(code, plan: usage["plan"] as? String ?? shared.plan) {
        case .none: break
        case .membership: MembershipPaywall.present(message: message, variant: .all)
        case .upgrade: MembershipPaywall.present(message: message, variant: .upgrade)
        case .credit: AICreditSheet.present(message: message)
        }
    }
}

import SwiftUI
import UserNotifications

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
        let before = percent
        percent = (usage["percent"] as? NSNumber)?.intValue ?? percent
        if Self.crossesAlert(from: before, to: percent), UserDefaults.standard.object(forKey: NativeAIPreferences.usageAlertKey) as? Bool ?? true { notifyUsage() }
        autoQuestionsLeft = (usage["autoQuestionsLeft"] as? NSNumber)?.intValue ?? autoQuestionsLeft
        creditUcents = (usage["creditUcents"] as? NSNumber)?.int64Value ?? creditUcents
    }

    static let alertPercent = 80
    /// True the one time usage climbs from under 80% to 80% or more (not on first load, not while it stays above).
    nonisolated static func crossesAlert(from before: Int?, to after: Int?) -> Bool {
        guard let before, let after else { return false }
        return before < alertPercent && after >= alertPercent
    }
    var postNotification: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    private func notifyUsage() {
        let content = UNMutableNotificationContent()
        content.title = "반달"; content.body = "이번 달 AI 사용량의 \(Self.alertPercent)%를 썼어요."
        postNotification(UNNotificationRequest(identifier: "ai-usage-\(Self.alertPercent)", content: content, trigger: nil))
    }

    /// A Pro member out of AI: the chat's 충전 button opens its popover with this reason, then clears it.
    /// Only fresh: a refusal nobody showed (no chat open) must not pop up minutes later.
    @Published var creditPrompt: CreditPrompt?
    struct CreditPrompt: Equatable {
        let message: String
        let at = Date()
        var fresh: Bool { Date().timeIntervalSince(at) < 10 }
    }

    /// Where a refusal sends the user: free or Plus → the plans with Pro picked, Pro → 충전.
    /// A task cap only stops that task; the chat says so and offers 충전 there.
    enum Destination: Equatable { case none, plans, credit }
    static func destination(_ code: String, plan: String) -> Destination {
        guard code == "BUDGET_EXHAUSTED" else { return .none }
        return plan == "pro" ? .credit : .plans
    }

    /// A budget or task-cap refusal from the proxy.
    static func presentLimit(_ code: String, usage: [String: Any]) {
        shared.update(usage)
        let message = AIError.describe(code, usage)
        switch destination(code, plan: usage["plan"] as? String ?? shared.plan) {
        case .none: break
        case .plans: MembershipPaywall.present(message: message, highlight: .pro)
        case .credit: shared.creditPrompt = CreditPrompt(message: message)
        }
    }
}

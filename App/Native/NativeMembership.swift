import StoreKit
import SwiftUI
import UIKit

/// 충전 (consumable `app.bandal.ipad.credit.pack1`): one line and one price button, in a popover on the
/// 충전 button that opened it. The server holds the credit, so the transaction is finished only after it paid.
struct AICreditPopover: View {
    var message: String?
    let close: () -> Void
    @State private var offer: StoreOffer?
    @State private var failed = false
    @State private var buying = false
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                Text(message).font(.system(size: BandalMetrics.bodySize, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("credit-reason")
            }
            Text("이번 달 사용량을 다 쓴 뒤 쓰여요. 만료 없음.").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome {
                Label(outcome, systemImage: "checkmark.circle").font(.system(size: BandalMetrics.bodySize)).foregroundStyle(NativeDesktopTheme.text)
                    .accessibilityIdentifier("credit-outcome")
            } else if failed {
                HStack {
                    Text("불러오지 못했어요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityIdentifier("credit-unavailable")
                    Spacer()
                    Button("다시 시도") { Task { await load() } }.buttonStyle(NativeToolButtonStyle(compact: true)).accessibilityIdentifier("credit-retry")
                }
            } else {
                Button { Task { await buy() } } label: {
                    // Blank until StoreKit answers: the storefront's own price, never a placeholder number.
                    Text(offer.map { "\($0.displayPrice) 충전" } ?? " ").frame(maxWidth: .infinity)
                }
                .buttonStyle(NativeToolButtonStyle(primary: true)).disabled(offer == nil || buying)
                .overlay { if offer == nil || buying { ProgressView().controlSize(.small) } }
                .accessibilityIdentifier("credit-buy")
            }
        }
        .padding(BandalMetrics.padding)
        .accessibilityElement(children: .contain).accessibilityIdentifier("ai-credit-popover")
        .task {
            await load()
            await StoreSync.shared.redeemPending()
        }
    }

    private func load() async {
        failed = false
        do { offer = try await StoreOffers.load([StoreSync.creditPack]).first; failed = offer == nil }
        catch { failed = true }
    }

    private func buy() async {
        guard let product = offer?.product else { return }
        buying = true; defer { buying = false }
        do {
            switch try await product.purchase(options: await Membership.shared.purchaseOptions()) {
            case .success(let verification):
                outcome = await Membership.settle(verification) ? "충전했어요" : "결제됐어요. 곧 사용량에 더해져요."
            case .pending: outcome = "승인을 기다리고 있어요"
            case .userCancelled: break
            @unknown default: break
            }
        } catch { failed = true }
    }
}

/// A 충전 button with its popover. `opensOnLimit`: also opens when a Pro member runs out of AI
/// (AIUsage.creditPrompt), with the reason on top. Only the chat's button does, so one popover opens.
struct AICreditButton: View {
    var title = "충전"
    var opensOnLimit = false
    var identifier = "native-ai-credit-open"
    @ObservedObject private var usage = AIUsage.shared
    @State private var open = false
    @State private var message: String?

    var body: some View {
        Button(title) { message = nil; open.toggle() }
            .accessibilityIdentifier(identifier)
            .bandalPopover(isPresented: $open, arrowEdge: .bottom, width: 280) { AICreditPopover(message: message) { open = false } }
            .onAppear { takePrompt() }
            .onChange(of: usage.creditPrompt) { _, _ in takePrompt() }
    }

    private func takePrompt() {
        guard opensOnLimit, let prompt = usage.creditPrompt else { return }
        usage.creditPrompt = nil
        message = prompt; open = true
    }
}

/// Settings › 구독: what this iPad has made against the free allowance, the paywall, restore and
/// Apple's subscription management. Signing in is never asked for.
struct NativeSettingsSubscriptionPanel: View {
    var store: NativeWorkspaceStore
    @ObservedObject private var membership = Membership.shared
    @ObservedObject private var ai = AIUsage.shared
    @State private var usage: [String: Any] = [:]
    @State private var managing = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error { NativeToolError(message: error) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(NativeDesktopTheme.font(13)).foregroundStyle(.green) }
            NativeSettingsCard(title: "반달 멤버십", description: "Plus는 과목·자료 무제한, Pro는 AI를 Plus의 4배") {
                LabeledContent("상태", value: Self.title(membership.tier)).accessibilityIdentifier("native-membership-state")
                if membership.tier < .plus {
                    LabeledContent("이 iPad에서 만든 과목", value: "\(usage["courses"] as? Int ?? 0) / \(FreeTier.courses)")
                    LabeledContent("이 iPad에서 만든 자료", value: "\(usage["documents"] as? Int ?? 0) / \(FreeTier.documents)")
                }
                Button("플랜 변경") { MembershipPaywall.present() }.accessibilityIdentifier("native-membership-open")
                HStack {
                    Button("구매 복원") { restore() }
                    Button("구독 관리") { managing = true }
                }
                Text("이미 있는 과목과 자료는 구독과 관계없이 계속 열고 고칠 수 있어요.").font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
            }
            // Only with an account (the server's numbers); this panel never asks anyone to sign in.
            if let percent = ai.percent {
                NativeSettingsCard(title: "AI 사용량", description: "매달 1일 00시(한국 시간)에 다시 채워져요") {
                    ProgressView(value: Double(min(percent, 100)), total: 100) { Text("AI 사용량 \(percent)%") }
                        .accessibilityIdentifier("native-ai-usage")
                    if let left = ai.autoQuestionsLeft { Text("Auto 질문 약 \(left.formatted())회 남음").font(.callout) }
                    if ai.creditUcents > 0 { Text("충전한 사용량이 남아 있어요 (위 회수에 포함).").font(.caption).foregroundStyle(NativeDesktopTheme.secondary) }
                    AICreditButton()
                }
            }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .task(id: membership.tier) {
            do { usage = try await store.invokePrivate("nativeMembership:usage") as? [String: Any] ?? [:] }
            catch { self.error = error.localizedDescription }
        }
        .task {
            await membership.refresh()
            _ = try? await store.invokePrivate("native:aiConfig", ["refresh": true])
            #if DEBUG
            // A Pro account out of AI, for the 충전 popover's UI test and screenshot.
            if ProcessInfo.processInfo.arguments.contains("--native-ai-usage-fixture") { ai.update(["plan": "pro", "percent": 100, "autoQuestionsLeft": 0]) }
            #endif
        }
    }

    static func title(_ tier: Membership.Tier) -> String {
        switch tier { case .free: "무료"; case .plus: "플러스 이용 중"; case .pro: "프로 이용 중" }
    }

    private func restore() {
        Task {
            error = nil; notice = nil
            do { try await AppStore.sync() } catch { self.error = "구매를 복원하지 못했어요. \(error.localizedDescription)"; return }
            await membership.refresh()
            await StoreSync.shared.syncSubscriptions()
            notice = membership.tier >= .plus ? "\(membership.tier == .pro ? "반달 프로" : "반달 플러스")를 복원했어요." : "복원할 구독이 없어요."
        }
    }
}

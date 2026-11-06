import StoreKit
import SwiftUI
import UIKit

/// The 반달 멤버십 sheet (design §8.4). StoreKit draws the prices, periods, free trial, renewal terms and
/// purchase button. Nothing here mentions sync or another way to pay.
struct MembershipPaywall: View {
    /// `.all`: Plus and Pro (Plus yearly first). `.upgrade`: Pro only, for a Plus member out of AI.
    enum Variant { case all, upgrade }
    var message: String?
    var variant = Variant.all
    let close: () -> Void
    /// Closes the paywall, then opens the credit sheet once it is gone.
    var openCredit: () -> Void = {}
    @ObservedObject private var membership = Membership.shared
    private var productIDs: [String] {
        Membership.products.filter { variant == .all || $0.value == .pro }.map(\.key)
    }

    var body: some View {
        NavigationStack {
            store
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기", action: close).accessibilityIdentifier("membership-close") } }
        }
        .onChange(of: membership.tier) { old, tier in if tier > old { close() } }
    }

    private var store: some View {
        SubscriptionStoreView(productIDs: productIDs) {
            VStack(spacing: 14) {
                // Inside the store's scroll content: as a pinned banner above it, it hid the title.
                if let message {
                    Text(message).font(.headline).multilineTextAlignment(.center).padding().frame(maxWidth: .infinity)
                        .background(NativeDesktopTheme.accent.opacity(0.1), in: .rect(cornerRadius: 12)).accessibilityIdentifier("membership-reason")
                }
                Text(variant == .upgrade ? "반달 프로" : "반달 멤버십").font(.largeTitle.weight(.bold))
                VStack(alignment: .leading, spacing: 8) {
                    if variant == .all {
                        Label("플러스: 과목·자료 무제한 + AI (Auto 질문 약 400회 분량)", systemImage: "folder.badge.plus")
                    }
                    Label("프로: AI 4배 (약 1,700회 분량), 어떤 모델이든", systemImage: "sparkles")
                }
                if variant == .upgrade {
                    Button("이번 달만 더 쓰려면 AI 충전", action: openCredit).accessibilityIdentifier("membership-credit")
                }
                if variant == .all {
                    Text("무료로는 이 iPad에서 과목 \(FreeTier.courses)개와 자료 \(FreeTier.documents)개를 만들 수 있고, AI는 로그인하면 매달 조금씩 쓸 수 있어요. 이미 있는 자료는 구독과 관계없이 계속 열고 고칠 수 있어요.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true) // the store's header otherwise cuts it to one line
                }
            }.padding()
        }
        .subscriptionStoreControlStyle(PlanButtons())
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .policies)
        .storeButton(.hidden, for: .cancellation) // 닫기 in the toolbar also tells the store the sheet is gone
        .subscriptionStorePolicyDestination(url: URL(string: "https://bandal.io/privacy")!, for: .privacyPolicy)
        .subscriptionStorePolicyDestination(url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!, for: .termsOfService)
        .inAppPurchaseOptions { _ in await Membership.shared.purchaseOptions() }
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(.verified(let transaction))) = result { await transaction.finish() }
            await Membership.shared.refresh()
            // In-app purchases do not come through Transaction.updates: tell the server here.
            await StoreSync.shared.syncSubscriptions()
        }
    }

    /// Opens over whatever is showing, once: a refused course or document, the AI allowance, or settings.
    static func present(message: String?, variant: Variant = .all, onClose: @escaping () -> Void = {}) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.keyWindow?.rootViewController else { onClose(); return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIHostingController<MembershipPaywall>) else { return }
        var paywall = MembershipPaywall(message: message, variant: variant) { [weak presenter] in
            presenter?.dismiss(animated: true)
            onClose()
        }
        paywall.openCredit = { [weak presenter] in
            presenter?.dismiss(animated: true) { onClose(); AICreditSheet.present() }
        }
        let controller = UIHostingController(rootView: paywall)
        controller.modalPresentationStyle = .formSheet
        controller.isModalInPresentation = true
        presenter.present(controller, animated: true)
    }
}

/// One button per plan so the trial wording is ours: StoreKit's own button reads 특가 적용 for a free trial.
private struct PlanButtons: SubscriptionStoreControlStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 16) {
            if configuration.options.isEmpty {
                Text("구독 상품을 불러오지 못했어요. 잠시 후 다시 시도해 주세요.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("membership-unavailable")
            }
            // Plus before Pro, yearly before monthly: Plus yearly is the first choice.
            ForEach(configuration.options.sorted { (Self.rank($0.id), $1.price) < (Self.rank($1.id), $0.price) }) { option in
                let price = "\(option.displayPrice) / \(option.subscriptionPeriod.map { Self.text($0, single: true) } ?? "")"
                let trial = option.activeOffer.flatMap { $0.paymentMode == .freeTrial ? Self.text($0.period, single: false) : nil }
                VStack(spacing: 6) {
                    Text(option.displayName).font(.headline)
                    Text(trial.map { "\($0) 무료, 이후 \(price)" } ?? price).font(.subheadline).foregroundStyle(.secondary)
                    if trial != nil, Membership.products[option.id] == .pro {
                        Text("체험 기간에는 AI가 플러스 한도로 제공되고, 유료로 전환되면 4배가 돼요.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier("membership-trial-note")
                    }
                    Button { option.subscribe() } label: {
                        Text(trial.map { "\($0) 무료로 시작" } ?? "구독하기").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .padding(.horizontal)
    }

    private static func rank(_ id: String) -> Int { Membership.products[id] == .pro ? 1 : 0 }

    /// 7일, 1개월 … ; `single` drops a leading 1 for a renewal period (월, 년).
    private static func text(_ period: Product.SubscriptionPeriod, single: Bool) -> String {
        switch period.unit {
        case .day: "\(period.value)일"
        case .week: "\(period.value * 7)일"
        case .month: single && period.value == 1 ? "월" : "\(period.value)개월"
        case .year: single && period.value == 1 ? "년" : "\(period.value)년"
        @unknown default: "\(period.value)"
        }
    }
}

/// AI credit (consumable `app.bandal.ipad.credit.pack1`): more AI this month, never expires. Needs an
/// account, since the server holds the credit; the transaction is finished only after it paid.
struct AICreditSheet: View {
    var message: String?
    let close: () -> Void
    @ObservedObject private var usage = AIUsage.shared
    @State private var signedIn: Bool?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let message {
                    Text(message).font(.headline).multilineTextAlignment(.center).padding().frame(maxWidth: .infinity)
                        .background(NativeDesktopTheme.accent.opacity(0.1), in: .rect(cornerRadius: 12)).accessibilityIdentifier("credit-reason")
                }
                Text("AI 충전").font(.largeTitle.weight(.bold))
                Text("이번 달 AI 사용량에 더해 쓰는 충전분이에요. 만료되지 않고, 이번 달 사용량을 다 쓴 뒤에 쓰여요.")
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if usage.plan == "pro", usage.trial {
                    Text("체험이 끝나면 프로 한도(플러스의 4배, Auto 질문 약 1,700회 분량)로 늘어나요.").font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("credit-trial-note")
                }
                if signedIn == false {
                    Text("충전은 반달 계정에 쌓여요. 설정 › 반달 계정에서 먼저 로그인해 주세요.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .accessibilityIdentifier("credit-sign-in")
                } else {
                    ProductView(id: StoreSync.creditPack).productViewStyle(.large)
                        .inAppPurchaseOptions { _ in await Membership.shared.purchaseOptions() }
                        .onInAppPurchaseCompletion { _, result in
                            if case .success(.success(let verification)) = result { await Membership.settle(verification) }
                        }
                }
                Text("다음 달 1일에 이번 달 사용량이 다시 채워져요. 충전은 소비성 구매라 구매 복원 대상이 아니에요.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기", action: close).accessibilityIdentifier("credit-close") } }
        }
        .accessibilityIdentifier("ai-credit-sheet")
        .task {
            signedIn = await Membership.shared.accountToken() != nil
            await StoreSync.shared.redeemPending()
        }
    }

    static func present(message: String? = nil) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.keyWindow?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIHostingController<AICreditSheet>) else { return }
        let controller = UIHostingController(rootView: AICreditSheet(message: message) { [weak presenter] in presenter?.dismiss(animated: true) })
        controller.modalPresentationStyle = .formSheet
        presenter.present(controller, animated: true)
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
            NativeSettingsCard(title: "반달 멤버십", description: "플러스는 과목과 자료를 개수 제한 없이 만들고 AI를 더 많이 씁니다. 프로는 AI를 플러스의 4배 씁니다. 구독은 이 기기의 Apple ID로 확인합니다.") {
                LabeledContent("상태", value: Self.title(membership.tier)).accessibilityIdentifier("native-membership-state")
                if membership.tier < .plus {
                    LabeledContent("이 iPad에서 만든 과목", value: "\(usage["courses"] as? Int ?? 0) / \(FreeTier.courses)")
                    LabeledContent("이 iPad에서 만든 자료", value: "\(usage["documents"] as? Int ?? 0) / \(FreeTier.documents)")
                }
                if membership.tier < .pro {
                    Button(membership.tier == .plus ? "반달 프로 보기" : "반달 멤버십 보기") {
                        MembershipPaywall.present(message: nil, variant: membership.tier == .plus ? .upgrade : .all)
                    }.accessibilityIdentifier("native-membership-open")
                }
                HStack {
                    Button("구매 복원") { restore() }
                    Button("구독 관리") { managing = true }
                }
                Text("이미 있는 과목과 자료는 구독과 관계없이 계속 열고 고칠 수 있어요.").font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
            }
            // Only with an account (the server's numbers); this panel never asks anyone to sign in.
            if let percent = ai.percent {
                NativeSettingsCard(title: "AI 사용량", description: "이번 달 AI 사용량이에요. 매달 1일 00시(한국 시간)에 다시 채워져요.") {
                    ProgressView(value: Double(min(percent, 100)), total: 100) { Text("AI 사용량 \(percent)%") }
                        .accessibilityIdentifier("native-ai-usage")
                    if let left = ai.autoQuestionsLeft { Text("Auto 질문 약 \(left.formatted())회 남음").font(.callout) }
                    if ai.creditUcents > 0 { Text("충전한 사용량이 남아 있어요 (위 회수에 포함).").font(.caption).foregroundStyle(NativeDesktopTheme.secondary) }
                    Button("AI 충전") { AICreditSheet.present() }.accessibilityIdentifier("native-ai-credit-open")
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

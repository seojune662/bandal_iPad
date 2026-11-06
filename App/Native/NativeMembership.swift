import StoreKit
import SwiftUI
import UIKit

/// The 반달 플러스 sheet (design §8.4). StoreKit draws the prices, periods, free trial, renewal terms and
/// purchase button. Nothing here mentions sync or another way to pay.
struct MembershipPaywall: View {
    var message: String?
    let close: () -> Void
    @ObservedObject private var membership = Membership.shared

    var body: some View {
        NavigationStack {
            store
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기", action: close).accessibilityIdentifier("membership-close") } }
        }
        .onChange(of: membership.tier) { old, tier in if tier > old { close() } }
    }

    private var store: some View {
        SubscriptionStoreView(productIDs: Membership.products.keys) {
            VStack(spacing: 14) {
                // Inside the store's scroll content: as a pinned banner above it, it hid the title.
                if let message {
                    Text(message).font(.headline).multilineTextAlignment(.center).padding().frame(maxWidth: .infinity)
                        .background(NativeDesktopTheme.accent.opacity(0.1), in: .rect(cornerRadius: 12)).accessibilityIdentifier("membership-reason")
                }
                Text("반달 플러스").font(.largeTitle.weight(.bold))
                VStack(alignment: .leading, spacing: 8) {
                    Label("과목과 자료를 개수 제한 없이 만들 수 있어요.", systemImage: "folder.badge.plus")
                    Label("등록한 API 키로 쓰는 AI 기능을 횟수 제한 없이 쓸 수 있어요.", systemImage: "sparkles")
                }
                Text("무료로는 이 iPad에서 과목 \(FreeTier.courses)개와 자료 \(FreeTier.documents)개를 만들고 AI 기능을 매달 \(FreeTier.aiPerMonth)회 쓸 수 있어요. 이미 있는 자료는 구독과 관계없이 계속 열고 고칠 수 있어요.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true) // the store's header otherwise cuts it to one line
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
        }
    }

    /// Opens over whatever is showing, once: a refused course or document, the AI allowance, or settings.
    static func present(message: String?, onClose: @escaping () -> Void = {}) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.keyWindow?.rootViewController else { onClose(); return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIHostingController<MembershipPaywall>) else { return }
        let controller = UIHostingController(rootView: MembershipPaywall(message: message) { [weak presenter] in
            presenter?.dismiss(animated: true)
            onClose()
        })
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
            ForEach(configuration.options.sorted { $0.price < $1.price }) { option in
                let price = "\(option.displayPrice) / \(option.subscriptionPeriod.map { Self.text($0, single: true) } ?? "")"
                let trial = option.activeOffer.flatMap { $0.paymentMode == .freeTrial ? Self.text($0.period, single: false) : nil }
                VStack(spacing: 6) {
                    Text(option.displayName).font(.headline)
                    Text(trial.map { "\($0) 무료, 이후 \(price)" } ?? price).font(.subheadline).foregroundStyle(.secondary)
                    Button { option.subscribe() } label: {
                        Text(trial.map { "\($0) 무료로 시작" } ?? "구독하기").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .padding(.horizontal)
    }

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

/// Settings › 구독: what this iPad has made against the free allowance, the paywall, restore and
/// Apple's subscription management. Signing in is never asked for.
struct NativeSettingsSubscriptionPanel: View {
    var store: NativeWorkspaceStore
    @ObservedObject private var membership = Membership.shared
    @State private var usage: [String: Any] = [:]
    @State private var managing = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error { NativeToolError(message: error) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(NativeDesktopTheme.font(13)).foregroundStyle(.green) }
            NativeSettingsCard(title: "반달 플러스", description: "과목과 자료를 개수 제한 없이 만들고, 등록한 API 키로 쓰는 AI 기능을 횟수 제한 없이 씁니다. 구독은 이 기기의 Apple ID로 확인합니다.") {
                LabeledContent("상태", value: membership.tier >= .plus ? "이용 중" : "무료").accessibilityIdentifier("native-membership-state")
                if membership.tier < .plus {
                    LabeledContent("이 iPad에서 만든 과목", value: "\(usage["courses"] as? Int ?? 0) / \(FreeTier.courses)")
                    LabeledContent("이 iPad에서 만든 자료", value: "\(usage["documents"] as? Int ?? 0) / \(FreeTier.documents)")
                    LabeledContent("이번 달 AI", value: "\(FreeTier.AIAllowance().used()) / \(FreeTier.aiPerMonth)")
                    Button("반달 플러스 보기") { MembershipPaywall.present(message: nil) }.accessibilityIdentifier("native-membership-open")
                }
                HStack {
                    Button("구매 복원") { restore() }
                    Button("구독 관리") { managing = true }
                }
                Text("이미 있는 과목과 자료는 구독과 관계없이 계속 열고 고칠 수 있어요.").font(.caption).foregroundStyle(NativeDesktopTheme.secondary)
            }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .task(id: membership.tier) {
            do { usage = try await store.invokePrivate("nativeMembership:usage") as? [String: Any] ?? [:] }
            catch { self.error = error.localizedDescription }
        }
        .task { await membership.refresh() }
    }

    private func restore() {
        Task {
            error = nil; notice = nil
            do { try await AppStore.sync() } catch { self.error = "구매를 복원하지 못했어요. \(error.localizedDescription)"; return }
            await membership.refresh()
            notice = membership.tier >= .plus ? "반달 플러스를 복원했어요." : "복원할 구독이 없어요."
        }
    }
}

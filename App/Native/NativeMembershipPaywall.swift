import StoreKit
import SwiftUI
import UIKit

/// 플랜 선택: our own screen over StoreKit 2 (`Product.purchase()`), full screen. Free · Plus · Pro cards,
/// monthly or yearly, prices from StoreKit's `displayPrice`. Up- and downgrades follow the subscription
/// group's levels (Pro 1, Plus 2): an upgrade starts now, a downgrade or a period change at renewal.
/// The credit pack is not here; it is the 충전 popover.
struct MembershipPaywall: View {
    var message: String?
    /// The card picked when the screen opens (Pro when AI ran out).
    var highlight: Membership.Tier?
    let close: () -> Void
    @ObservedObject private var membership = Membership.shared
    @State private var yearly = true
    @State private var offers: [StoreOffer] = []
    @State private var failed = false
    @State private var selected: Membership.Tier = .plus
    @State private var buying: String?
    @State private var toast: String?
    @State private var closed = false

    private var loading: Bool { offers.isEmpty && !failed }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    periodToggle
                    if failed { unavailable } else { cards }
                    footer
                }
                .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 32)
                // Centred when it fits (portrait); scrolls when it does not.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(NativeDesktopTheme.bgApp.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            Button(action: finish) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.leading, 12).padding(.top, 8)
            .accessibilityLabel("닫기").accessibilityIdentifier("membership-close")
        }
        .bandalToast($toast)
        .task {
            selected = highlight ?? (membership.tier == .free ? .plus : membership.tier)
            await load()
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("membership-paywall")
    }

    // MARK: Header and period

    private var header: some View {
        VStack(spacing: 6) {
            Text("플랜 선택").font(NativeDesktopTheme.font(28, weight: .bold)).foregroundStyle(NativeDesktopTheme.text)
                .accessibilityIdentifier("membership-title")
            Text(membership.tier == .free ? "무료 이용 중" : "현재 \(Self.name(membership.tier)) 이용 중")
                .font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityIdentifier("membership-current")
            if let message {
                Text(message).font(NativeDesktopTheme.font(13, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
                    .multilineTextAlignment(.center).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(NativeDesktopTheme.raised, in: .rect(cornerRadius: BandalMetrics.radius)).padding(.top, 6)
                    .accessibilityIdentifier("membership-reason")
            }
        }.padding(.top, 28)
    }

    private var periodToggle: some View {
        HStack(spacing: 2) {
            periodButton("월간", isYearly: false)
            periodButton("연간", isYearly: true, badge: StoreOffers.yearlySaving(offers).map { "최대 \($0)% 할인" })
        }
        .padding(3).background(NativeDesktopTheme.raised, in: Capsule())
    }

    private func periodButton(_ title: String, isYearly: Bool, badge: String? = nil) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { yearly = isYearly } } label: {
            HStack(spacing: 6) {
                Text(title).font(NativeDesktopTheme.font(13, weight: .semibold))
                if let badge {
                    Text(badge).font(NativeDesktopTheme.font(11, weight: .semibold))
                        .foregroundStyle(yearly == isYearly ? NativeDesktopTheme.accent : NativeDesktopTheme.onAccent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(yearly == isYearly ? NativeDesktopTheme.onAccent : NativeDesktopTheme.accent, in: Capsule())
                        .accessibilityIdentifier("membership-saving")
                }
            }
            .foregroundStyle(yearly == isYearly ? NativeDesktopTheme.onAccent : NativeDesktopTheme.text)
            .padding(.horizontal, 16).frame(height: 34)
            .background(yearly == isYearly ? NativeDesktopTheme.accent : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(yearly == isYearly ? .isSelected : [])
        .accessibilityIdentifier(isYearly ? "membership-period-yearly" : "membership-period-monthly")
    }

    // MARK: Cards

    private var cards: some View {
        let row = HStack(alignment: .top, spacing: 16) { ForEach(Plan.all) { card($0) } }.padding(.vertical, 4)
        // Landscape fits all three; portrait (and narrow windows) scroll sideways.
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row.padding(.horizontal, 2) }
        }
    }

    private func card(_ plan: Plan) -> some View {
        let offer = offers.first { $0.tier == plan.tier && $0.yearly == yearly }
        let picked = selected == plan.tier
        return VStack(alignment: .leading, spacing: 0) {
            Text(plan.band ?? " ").font(NativeDesktopTheme.font(12, weight: .semibold))
                .foregroundStyle(NativeDesktopTheme.onAccent).frame(maxWidth: .infinity).frame(height: 28)
                .background(plan.band == nil ? Color.clear : NativeDesktopTheme.accent)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.title).font(NativeDesktopTheme.font(20, weight: .bold)).foregroundStyle(NativeDesktopTheme.text)
                    price(plan, offer)
                    Text(plan.summary).font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                }
                cta(plan, offer)
                Rectangle().fill(NativeDesktopTheme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 9) {
                    if let lead = plan.lead { Text(lead).font(NativeDesktopTheme.font(12, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted) }
                    ForEach(plan.features, id: \.self) { feature in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(NativeDesktopTheme.text)
                            Text(feature).font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.padding(20)
        }
        .frame(width: 296, alignment: .top)
        .background(NativeDesktopTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge)
            .strokeBorder(picked ? NativeDesktopTheme.accent : NativeDesktopTheme.border, lineWidth: picked ? 2 : 1))
        .shadow(color: picked ? BandalMetrics.shadow : .clear, radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge))
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = plan.tier } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("membership-card-" + plan.id)
    }

    @ViewBuilder private func price(_ plan: Plan, _ offer: StoreOffer?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if plan.tier == .free {
                // Zero in the storefront's own currency, once StoreKit has answered.
                Text(zeroPrice ?? "₩0").font(NativeDesktopTheme.font(26, weight: .bold))
            } else {
                Text(offer?.displayPrice ?? "₩00,000").font(NativeDesktopTheme.font(26, weight: .bold))
                Text(yearly ? "/년" : "/월").font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary)
            }
        }
        .foregroundStyle(NativeDesktopTheme.text)
        .redacted(reason: loading ? .placeholder : [])
        .accessibilityIdentifier("membership-price-" + plan.id)
    }

    private var zeroPrice: String? {
        #if DEBUG
        if StoreOffers.fixture != nil { return "₩0" }
        #endif
        return offers.lazy.compactMap(\.product).first.map { Decimal(0).formatted($0.priceFormatStyle) }
    }

    @ViewBuilder private func cta(_ plan: Plan, _ offer: StoreOffer?) -> some View {
        if plan.tier == .free {
            Color.clear.frame(height: 40)
        } else {
            let action = offer.map { StoreOffers.action(for: $0, currentProduct: membership.currentProduct, tier: membership.tier) }
            Button { if let offer { selected = plan.tier; Task { await buy(offer) } } } label: {
                ZStack {
                    Text(Self.label(action)).opacity(buying == offer?.id && buying != nil ? 0 : 1)
                    if buying != nil, buying == offer?.id { ProgressView().controlSize(.small).tint(NativeDesktopTheme.onAccent) }
                }
                .font(NativeDesktopTheme.font(14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 40)
                .foregroundStyle(action == .current ? NativeDesktopTheme.secondary : NativeDesktopTheme.onAccent)
                .background(action == .current ? NativeDesktopTheme.raised : NativeDesktopTheme.accent, in: .rect(cornerRadius: BandalMetrics.radius))
            }
            .buttonStyle(.plain)
            .disabled(offer == nil || action == .current || buying != nil)
            .opacity(offer == nil ? 0.4 : 1)
            .accessibilityIdentifier("membership-cta-" + plan.id)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Text("불러오지 못했어요").font(NativeDesktopTheme.font(15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
                .accessibilityIdentifier("membership-unavailable")
            Button("다시 시도") { Task { await load() } }.buttonStyle(NativeToolButtonStyle(primary: true)).accessibilityIdentifier("membership-retry")
        }.frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button("구매 복원") { Task { await restore() } }.accessibilityIdentifier("membership-restore")
                Text("·")
                Link("이용약관", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text("·")
                Link("개인정보처리방침", destination: URL(string: "https://bandal.io/privacy")!)
            }
            .font(NativeDesktopTheme.font(13, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).buttonStyle(.plain)
            Text("""
            Plus와 Pro는 고른 기간(월간 또는 연간)마다 위 카드에 표시된 가격으로 자동 갱신되며, 요금은 구매를 확인할 때 Apple ID로 청구돼요. \
            현재 기간(무료 체험 포함)이 끝나기 24시간 전까지 해지하지 않으면 다음 기간 요금이 청구돼요. \
            구독은 설정 › Apple ID › 구독에서 관리하고 해지할 수 있어요. Pro 무료 체험 기간의 AI 사용량은 Plus와 같아요.
            """)
            .font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted).multilineTextAlignment(.center)
            .frame(maxWidth: 640).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("membership-terms")
        }
    }

    // MARK: StoreKit

    private func load() async {
        failed = false
        do { offers = try await StoreOffers.load(Array(Membership.products.keys)) }
        catch { offers = []; failed = true }
    }

    private func buy(_ offer: StoreOffer) async {
        guard let product = offer.product, let tier = offer.tier else { return }
        buying = offer.id; defer { buying = nil }
        do {
            switch try await product.purchase(options: await membership.purchaseOptions()) {
            case .success(let verification):
                guard await Membership.settle(verification) else { toast = "구매를 확인하지 못했어요. 잠시 후 구매 복원을 눌러 주세요."; return }
                await membership.refresh()
                // Purchases made here do not come through Transaction.updates: tell the server now.
                await StoreSync.shared.syncSubscriptions()
                if membership.currentProduct == offer.id {
                    toast = "\(Self.name(tier)) 시작됐어요"
                    try? await Task.sleep(for: .seconds(1.4))
                    finish()
                } else {
                    toast = "다음 갱신일부터 \(Self.name(tier)) \(offer.yearly == true ? "연간" : "월간")으로 바뀌어요"
                }
            case .pending: toast = "승인을 기다리고 있어요"
            case .userCancelled: break
            @unknown default: break
            }
        } catch { toast = "구매하지 못했어요. \(error.localizedDescription)" }
    }

    /// X and the close after a purchase both end here; whichever comes second does nothing.
    private func finish() {
        guard !closed else { return }
        closed = true
        close()
    }

    private func restore() async {
        do { try await AppStore.sync() } catch { toast = "구매를 복원하지 못했어요."; return }
        await membership.refresh()
        await StoreSync.shared.syncSubscriptions()
        toast = membership.tier == .free ? "복원할 구독이 없어요" : "\(Self.name(membership.tier))를 복원했어요"
    }

    // MARK: Copy

    static func name(_ tier: Membership.Tier) -> String {
        switch tier { case .free: "무료"; case .plus: "Plus"; case .pro: "Pro" }
    }

    static func label(_ action: StoreOffers.Action?) -> String {
        switch action {
        case .current: "현재 플랜"
        case .trial(let days): "\(days)일 무료로 시작"
        case .upgrade: "업그레이드"
        case .change: "변경"
        case nil: "업그레이드"
        }
    }

    struct Plan: Identifiable {
        let id: String, tier: Membership.Tier, title: String, band: String?, summary: String, lead: String?, features: [String]
        static let all = [
            Plan(id: "free", tier: .free, title: "무료", band: nil, summary: "시작해 보기", lead: nil,
                 features: ["과목 \(FreeTier.courses)개 · 자료 \(FreeTier.documents)개", "AI 월 약 30회 (Auto)", "본인 iCloud·Drive 동기화"]),
            Plan(id: "plus", tier: .plus, title: "Plus", band: "가장 인기", summary: "과목이 많고 AI를 가끔 쓰는 학생", lead: "무료의 모든 기능과…",
                 features: ["과목·자료 무제한", "AI 사용량 기본 (Auto 약 400회)", "모든 모델 선택 가능"]),
            Plan(id: "pro", tier: .pro, title: "Pro", band: "AI 4배", summary: "AI로 공부하는 학생", lead: "Plus의 모든 기능과…",
                 features: ["AI 사용량 4배 (Auto 약 1,700회)", "작업 1회 상한 $0.50", "우선 지원"]),
        ]
    }

    /// Opens over whatever is showing, once: a refused course or document, AI out of budget, settings, the profile menu.
    static func present(message: String? = nil, highlight: Membership.Tier? = nil, onClose: @escaping () -> Void = {}) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.keyWindow?.rootViewController else { onClose(); return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIHostingController<MembershipPaywall>) else { return }
        let paywall = MembershipPaywall(message: message, highlight: highlight) { [weak presenter] in
            presenter?.dismiss(animated: true)
            onClose()
        }
        let controller = UIHostingController(rootView: paywall)
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }
}

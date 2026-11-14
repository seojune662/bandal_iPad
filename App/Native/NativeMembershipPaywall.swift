import StoreKit
import SwiftUI
import UIKit

/// 요금제: our own screen over StoreKit 2 (`Product.purchase()`), full screen, and the one place for plans,
/// AI 충전 and the App Store's own management. Top to bottom: the plan in effect (period, next charge,
/// trial, cancellation, a change booked for renewal), monthly or yearly with Free · Plus · Pro cards, AI 충전,
/// then restore, billing history, the App Store's manage sheet, terms and the auto-renew notice. Every price
/// is StoreKit's `displayPrice`. Up- and downgrades follow the subscription group's levels (Pro 1, Plus 2):
/// an upgrade starts now, a downgrade or a change of period at renewal.
struct MembershipPaywall: View {
    var message: String?
    /// The card picked when the screen opens (Pro when AI ran out).
    var highlight: Membership.Tier?
    /// Scrolled to on open (설정 › 더 보기's 충전 goes to the credit card).
    var focus: Focus?
    let close: () -> Void
    enum Focus: Hashable { case credit }

    @ObservedObject private var membership = Membership.shared
    @State private var yearly = true
    @State private var offers: [StoreOffer] = []
    @State private var failed = false
    @State private var selected: Membership.Tier = .plus
    @State private var buying: String?
    @State private var toast: String?
    @State private var closed = false
    @State private var status: PlanStatus?
    @State private var usage: (courses: Int, documents: Int)?
    @State private var managing = false
    /// Bumped after anything that may change the status StoreKit reports (a purchase, restore, the manage sheet).
    @State private var revision = 0
    /// The app's language: this view applies `bandalLocalized()` to its content, so its own environment is the
    /// hosting controller's, not the app's.
    private var locale: Locale { Locale(identifier: NativeAppLocale.current) }

    /// What the free allowance counts (folders and documents made on this iPad), handed in by the app at start.
    static var freeUsage: (() async -> [String: Any]?)?

    private var loading: Bool { offers.isEmpty && !failed }
    private var fixture: Bool {
        #if DEBUG
        PlanStatus.Fixture.active
        #else
        false
        #endif
    }
    /// The plan in effect: StoreKit's (through Membership), or the UI test's `--plans-state`.
    private var tier: Membership.Tier { fixture ? status?.tier ?? .free : membership.tier }
    private var currentProduct: String? { fixture ? status?.productID : membership.currentProduct }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    header
                    PlanCurrentCard(tier: tier, status: tier == .free ? nil : status, usage: usage)
                        .frame(maxWidth: Self.contentWidth)
                    VStack(spacing: 16) {
                        periodToggle
                        if failed { unavailable } else { cards }
                        if tier != .free {
                            Text("업그레이드는 바로 적용되고, 낮추기와 기간 변경은 다음 갱신일부터 적용돼요.")
                                .font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("plans-change-notice")
                        }
                    }
                    PlanCreditCard().frame(maxWidth: Self.contentWidth).id(Focus.credit)
                    PlanFooter(restore: { Task { await restore() } }, manage: { managing = true })
                        .frame(maxWidth: Self.contentWidth)
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .task {
                guard let focus else { return }
                // After the first layout pass, so the target exists.
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(focus, anchor: .center) }
            }
        }
        .modifier(PlanWidthFixture())
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
        .manageSubscriptionsSheet(isPresented: $managing)
        .onChange(of: managing) { _, open in if !open { Task { await membership.refresh(); revision += 1 } } }
        .task {
            selected = highlight ?? (membership.tier == .free ? .plus : membership.tier)
            await load()
        }
        .task(id: "\(membership.currentProduct ?? "-") \(revision)") {
            status = await PlanStatus.load()
            if fixture { selected = highlight ?? (tier == .free ? .plus : tier) }
            if let value = await Self.freeUsage?() {
                usage = ((value["courses"] as? NSNumber)?.intValue ?? 0, (value["documents"] as? NSNumber)?.intValue ?? 0)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("membership-paywall")
        .bandalLocalized()
    }

    /// The cards' row: three 296 pt cards and two 16 pt gaps; the other sections line up with it.
    static let contentWidth: CGFloat = 920

    // MARK: Header and period

    private var header: some View {
        VStack(spacing: 6) {
            Text("요금제").font(NativeDesktopTheme.font(28, weight: .bold)).foregroundStyle(NativeDesktopTheme.text)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("membership-title")
            if let message {
                Text(message).font(NativeDesktopTheme.font(13, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
                    .multilineTextAlignment(.center).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(NativeDesktopTheme.raised, in: .rect(cornerRadius: BandalMetrics.radius)).padding(.top, 6)
                    .accessibilityIdentifier("membership-reason")
            }
        }.padding(.top, 24)
    }

    private var periodToggle: some View {
        HStack(spacing: 2) {
            periodButton("월간", isYearly: false)
            periodButton("연간", isYearly: true, badge: StoreOffers.yearlySaving(offers))
        }
        .padding(3).background(NativeDesktopTheme.raised, in: Capsule())
    }

    private func periodButton(_ title: String, isYearly: Bool, badge: Int? = nil) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { yearly = isYearly } } label: {
            HStack(spacing: 6) {
                BandalText(title).font(NativeDesktopTheme.font(13, weight: .semibold))
                if let badge {
                    Text("최대 \(badge)% 할인").font(NativeDesktopTheme.font(11, weight: .semibold))
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
        let row = HStack(alignment: .top, spacing: 16) { ForEach(Plan.all) { card($0).id($0.tier) } }.padding(.vertical, 4)
        // Landscape and portrait fit all three; a narrow window scrolls them sideways, to the card picked.
        return ViewThatFits(in: .horizontal) {
            row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { row.padding(.horizontal, 2) }
                    .task(id: selected) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected, anchor: .center) } }
            }
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
                    priceNote(plan, offer)
                    Text(plan.summary).font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                }
                cta(plan, offer)
                Rectangle().fill(NativeDesktopTheme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 9) {
                    if let lead = plan.lead { Text(lead).font(NativeDesktopTheme.font(12, weight: .medium)).foregroundStyle(NativeDesktopTheme.muted) }
                    ForEach(plan.features.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(NativeDesktopTheme.text)
                            Text(plan.features[index]).font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.text).fixedSize(horizontal: false, vertical: true)
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
                Text(verbatim: zeroPrice ?? "₩0").font(NativeDesktopTheme.font(26, weight: .bold))
            } else {
                Text(verbatim: offer?.displayPrice ?? "₩00,000").font(NativeDesktopTheme.font(26, weight: .bold))
                Text(yearly ? "/년" : "/월").font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary)
            }
        }
        .foregroundStyle(NativeDesktopTheme.text)
        .redacted(reason: loading ? .placeholder : [])
        .accessibilityIdentifier("membership-price-" + plan.id)
    }

    /// Under a paid price: the yearly saving of this plan, and the free trial this Apple ID can still start.
    @ViewBuilder private func priceNote(_ plan: Plan, _ offer: StoreOffer?) -> some View {
        let saving = yearly ? StoreOffers.saving(for: plan.tier, in: offers) : nil
        let trial = tier < plan.tier ? offer?.trialDays : nil
        if plan.tier != .free, saving != nil || trial != nil {
            HStack(spacing: 6) {
                if let saving { Text("월간보다 \(saving)% 저렴") }
                if saving != nil, trial != nil { Text(verbatim: "·") }
                if let trial { Text("\(trial)일 무료 체험 후 결제") }
            }
            .font(NativeDesktopTheme.font(12, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
            .accessibilityElement(children: .combine).accessibilityIdentifier("membership-note-" + plan.id)
        } else {
            Text(verbatim: " ").font(NativeDesktopTheme.font(12)).accessibilityHidden(true)
        }
    }

    private var zeroPrice: String? {
        #if DEBUG
        if StoreOffers.fixtureEnabled { return "₩0" }
        #endif
        return offers.lazy.compactMap(\.product).first.map { Decimal(0).formatted($0.priceFormatStyle) }
    }

    @ViewBuilder private func cta(_ plan: Plan, _ offer: StoreOffer?) -> some View {
        if plan.tier == .free {
            // On Free, Free is what this is; from a paid plan the way down is cancelling, in the App Store (below).
            if tier == .free { ctaLabel(.current, busy: false).accessibilityElement(children: .combine).accessibilityIdentifier("membership-cta-free") }
            else { Color.clear.frame(height: 40) }
        } else {
            let action = offer.map { StoreOffers.action(for: $0, currentProduct: currentProduct, tier: tier, scheduledProduct: status?.scheduledProductID) }
            Button { if let offer { selected = plan.tier; Task { await buy(offer) } } } label: {
                ctaLabel(action, busy: buying != nil && buying == offer?.id)
            }
            .buttonStyle(.plain)
            .disabled(offer == nil || action == .current || action == .scheduled || buying != nil)
            .opacity(offer == nil ? 0.4 : 1)
            .accessibilityIdentifier("membership-cta-" + plan.id)
        }
    }

    /// Filled for what starts now, outlined for what waits for renewal, flat for what is already so.
    private func ctaLabel(_ action: StoreOffers.Action?, busy: Bool) -> some View {
        let flat = action == .current || action == .scheduled
        let outlined = action == .toYearly || action == .atRenewal
        return ZStack {
            Text(verbatim: Self.label(action, locale)).opacity(busy ? 0 : 1)
            if busy { ProgressView().controlSize(.small).tint(outlined ? NativeDesktopTheme.text : NativeDesktopTheme.onAccent) }
        }
        .font(NativeDesktopTheme.font(14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 40)
        .foregroundStyle(flat ? NativeDesktopTheme.secondary : outlined ? NativeDesktopTheme.text : NativeDesktopTheme.onAccent)
        .background(flat ? NativeDesktopTheme.raised : outlined ? NativeDesktopTheme.bgApp : NativeDesktopTheme.accent, in: .rect(cornerRadius: BandalMetrics.radius))
        .overlay { if outlined { RoundedRectangle(cornerRadius: BandalMetrics.radius).strokeBorder(NativeDesktopTheme.border) } }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Text("요금제를 불러오지 못했어요").font(NativeDesktopTheme.font(15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
                .accessibilityIdentifier("membership-unavailable")
            Text("인터넷 연결을 확인한 뒤 다시 시도해 주세요.").font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.secondary)
            Button("다시 시도") { Task { await load() } }.buttonStyle(NativeToolButtonStyle(primary: true)).accessibilityIdentifier("membership-retry")
        }.frame(maxWidth: .infinity, minHeight: 260)
    }

    // MARK: StoreKit

    private func load() async {
        failed = false
        do { offers = try await StoreOffers.load(Array(Membership.products.keys)) }
        catch { offers = []; failed = true }
    }

    private func buy(_ offer: StoreOffer) async {
        buying = offer.id; defer { buying = nil }
        let outcome = await StorePurchase.plan(offer)
        revision += 1
        // A trial once used is no longer offered: the cards ask StoreKit again.
        if case .started = outcome { await load() }
        switch outcome {
        case .started(let tier):
            toast = String(format: NativeAppLocale.string("%@ 시작됐어요", locale), Self.name(tier, locale))
            // Opened by a refusal (a second folder, AI out): back to what was being done.
            if message != nil {
                try? await Task.sleep(for: .seconds(1.4))
                finish()
            }
        case .scheduled(let product):
            toast = String(format: NativeAppLocale.string("다음 갱신일부터 %@으로 바뀌어요", locale), Self.shortName(product, locale))
        case .pending: toast = NativeAppLocale.string("승인을 기다리고 있어요. 승인되면 바로 적용돼요.", locale)
        case .cancelled: break
        case .unverified: toast = NativeAppLocale.string("구매를 확인하지 못했어요. 잠시 후 구매 복원을 눌러 주세요.", locale)
        case .failed(let reason): toast = NativeAppLocale.string("구매하지 못했어요.", locale) + (reason.isEmpty ? "" : " " + reason)
        }
    }

    /// X and the close after a purchase both end here; whichever comes second does nothing.
    private func finish() {
        guard !closed else { return }
        closed = true
        close()
    }

    private func restore() async {
        do { try await AppStore.sync() } catch { toast = NativeAppLocale.string("구매를 복원하지 못했어요.", locale); return }
        await membership.refresh()
        await StoreSync.shared.syncSubscriptions()
        revision += 1
        toast = membership.tier == .free ? NativeAppLocale.string("복원할 구독이 없어요", locale)
            : String(format: NativeAppLocale.string("%@를 복원했어요", locale), Self.name(membership.tier, locale))
    }

    // MARK: Copy

    /// "Plus", "Pro": the cards' names, which the toasts repeat.
    static func name(_ tier: Membership.Tier, _ locale: Locale) -> String {
        switch tier { case .free: NativeAppLocale.string("무료", locale); case .plus: "Plus"; case .pro: "Pro" }
    }

    /// "반달 플러스 · 연간": the plan in effect.
    static func fullName(_ productID: String, _ locale: Locale) -> String {
        let plan = Membership.products[productID] == .pro ? "반달 프로" : "반달 플러스"
        return NativeAppLocale.string(plan, locale) + " · " + NativeAppLocale.string(PlanStatus.yearly(productID) ? "연간" : "월간", locale)
    }

    /// "프로 월간": a plan and period in a sentence.
    static func shortName(_ productID: String, _ locale: Locale) -> String {
        let plan = Membership.products[productID] == .pro ? "프로" : "플러스"
        return NativeAppLocale.string(plan, locale) + " " + NativeAppLocale.string(PlanStatus.yearly(productID) ? "연간" : "월간", locale)
    }

    /// A card's button, in the app language.
    static func label(_ action: StoreOffers.Action?, _ locale: Locale) -> String {
        switch action {
        case .trial(let days): String(format: NativeAppLocale.string("%lld일 무료 체험 시작", locale), days)
        case .current: NativeAppLocale.string("현재 요금제", locale)
        case .toYearly: NativeAppLocale.string("연간으로 변경", locale)
        case .atRenewal: NativeAppLocale.string("다음 갱신일에 변경", locale)
        case .scheduled: NativeAppLocale.string("변경 예약됨", locale)
        case .upgrade, nil: NativeAppLocale.string("업그레이드", locale)
        }
    }

    struct Plan: Identifiable {
        let id: String, tier: Membership.Tier, title: LocalizedStringKey, band: LocalizedStringKey?, summary: LocalizedStringKey, lead: LocalizedStringKey?
        let features: [LocalizedStringKey]
        static let all = [
            Plan(id: "free", tier: .free, title: "무료", band: nil, summary: "시작해 보기", lead: nil,
                 features: ["폴더 \(FreeTier.courses)개 · 자료 \(FreeTier.documents)개", "AI 월 약 30회 (자동)", "본인 iCloud·Drive 동기화"]),
            Plan(id: "plus", tier: .plus, title: "Plus", band: "가장 인기", summary: "폴더가 많고 AI를 가끔 쓰는 학생", lead: "무료의 모든 기능과…",
                 features: ["폴더·자료 무제한", "AI 사용량 기본 (자동 약 400회)", "모든 모델 선택 가능"]),
            Plan(id: "pro", tier: .pro, title: "Pro", band: "AI 4배", summary: "AI로 공부하는 학생", lead: "Plus의 모든 기능과…",
                 features: ["AI 사용량 4배 (Auto 약 1,700회)", "작업 1회 상한 Plus의 5배", "우선 지원"]),
        ]
    }

    /// Opens over whatever is showing, once: a refused course or document, AI out of budget, settings, the profile menu.
    static func present(message: String? = nil, highlight: Membership.Tier? = nil, focus: Focus? = nil, onClose: @escaping () -> Void = {}) {
        // A turn later: a menu row closes its popover first, and that popover starts going away only then.
        DispatchQueue.main.async { present(message: message, highlight: highlight, focus: focus, onClose: onClose, attempt: 0) }
    }

    private static func present(message: String?, highlight: Membership.Tier?, focus: Focus?, onClose: @escaping () -> Void, attempt: Int) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.keyWindow?.rootViewController else { onClose(); return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIHostingController<MembershipPaywall>) else { return }
        // Presented over a popover on its way out, the screen would be what its dismiss() closes (the profile menu's
        // 요금제 보기 opened nothing): wait for it to go. A popover that stays (a refused new folder's form) gets
        // half a second, then the screen opens over it as before.
        if attempt < 15, presenter.isBeingDismissed || presenter.modalPresentationStyle == .popover && attempt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { present(message: message, highlight: highlight, focus: focus, onClose: onClose, attempt: attempt + 1) }
            return
        }
        let paywall = MembershipPaywall(message: message, highlight: highlight, focus: focus) { [weak presenter] in
            presenter?.dismiss(animated: true)
            onClose()
        }
        let controller = UIHostingController(rootView: paywall)
        controller.modalPresentationStyle = .fullScreen
        // Settings › 화면's light or dark (the root view's `preferredColorScheme`) does not reach a controller presented here.
        let appearance = UserDefaults.standard.string(forKey: "native.appearance")
        controller.overrideUserInterfaceStyle = appearance == "dark" ? .dark : appearance == "light" ? .light : .unspecified
        presenter.present(controller, animated: true)
    }
}

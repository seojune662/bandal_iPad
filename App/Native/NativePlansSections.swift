import StoreKit
import SwiftUI

/// The plan card's colours (Figma 132:3441): a warm fill and the moon's badge. Settings › 구독·사용량 uses them too.
enum PlanPalette {
    static let fill = NativeDesktopTheme.adaptive(0xfff5de, 0x3a2f1a)
    static let badge = NativeDesktopTheme.adaptive(0xf5b83d, 0xe6a93a)
}

/// 요금제 › 현재 요금제: the plan and period in effect and what happens next, or 무료 with what is used of it.
struct PlanCurrentCard: View {
    let tier: Membership.Tier
    let status: PlanStatus?
    let usage: (courses: Int, documents: Int)?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "moon").font(.system(size: 22)).foregroundStyle(NativeDesktopTheme.bgApp).frame(width: 48, height: 48)
                .background(PlanPalette.badge, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("현재 요금제").font(NativeDesktopTheme.font(12, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if let status { Text(verbatim: MembershipPaywall.fullName(status.productID, locale)) }
                    else if tier == .free { Text("무료 이용 중") }
                    else { Text(tier == .pro ? "반달 프로" : "반달 플러스") }
                }
                .font(NativeDesktopTheme.font(20, weight: .bold)).foregroundStyle(NativeDesktopTheme.text)
                .accessibilityIdentifier("membership-current")
                VStack(alignment: .leading, spacing: 3) {
                    if let status {
                        let lines = status.lines()
                        ForEach(lines.indices, id: \.self) { index in line(lines[index]).accessibilityIdentifier("plans-current-line-\(index)") }
                    } else if tier == .free {
                        if let usage {
                            Text("이 iPad에서 만든 폴더 \(usage.courses)/\(FreeTier.courses) · 자료 \(usage.documents)/\(FreeTier.documents)")
                                .accessibilityIdentifier("plans-free-usage")
                        }
                        Text("플러스는 폴더·자료 무제한, 프로는 AI를 플러스의 4배")
                    }
                }
                .font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(PlanPalette.fill, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge))
        .accessibilityElement(children: .contain).accessibilityIdentifier("plans-current")
    }

    @ViewBuilder private func line(_ line: PlanStatus.Line) -> some View {
        switch line {
        case .renews(let date): Text("다음 결제일 \(date, format: .dateTime.year().month().day())")
        case .trial(let days, let ends, let renews):
            if renews { Text("무료 체험 중 · \(days)일 남음 · \(ends, format: .dateTime.month().day())에 첫 결제") }
            else { Text("무료 체험 중 · \(days)일 남음 · \(ends, format: .dateTime.month().day())에 끝나요") }
        case .ends(let date): Text("자동 갱신 꺼짐 · \(date, format: .dateTime.year().month().day())에 끝나요")
        case .changes(let product, let date):
            Text("다음 갱신일(\(date, format: .dateTime.month().day()))부터 \(MembershipPaywall.shortName(product, locale))")
                .fontWeight(.semibold).foregroundStyle(NativeDesktopTheme.text)
        case .billingIssue: Text("결제가 되지 않았어요. App Store에서 결제 수단을 확인해 주세요.").foregroundStyle(Color.orange)
        }
    }
}

/// 요금제 › AI 충전 (consumable `app.bandal.ipad.credit.pack1`): its price, what it does, the balance left and
/// the purchase. The server holds the credit, so it is sold to a signed-in account, and the transaction is
/// finished only after the server paid it (StorePurchase.credit, the same as the 충전 popover).
struct PlanCreditCard: View {
    @ObservedObject private var usage = AIUsage.shared
    @State private var offer: StoreOffer?
    @State private var failed = false
    @State private var buying = false
    @State private var outcome: String?
    @Environment(\.locale) private var locale

    /// Signed in: the server has answered with this account's AI status (as Settings › 구독·사용량 decides).
    private var signedIn: Bool { usage.percent != nil }

    var body: some View {
        let wide = HStack(alignment: .center, spacing: 20) { about; Spacer(minLength: 12); purchase.frame(width: 220) }
        let narrow = VStack(alignment: .leading, spacing: 14) { about; purchase }
        ViewThatFits(in: .horizontal) { wide; narrow }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: BandalMetrics.radiusLarge).strokeBorder(NativeDesktopTheme.border))
            .accessibilityElement(children: .contain).accessibilityIdentifier("plans-credit")
            .accessibilityValue(fixtureSummary)
            .task {
                await load()
                await StoreSync.shared.redeemPending()
            }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("AI 충전").font(NativeDesktopTheme.font(20, weight: .bold)).foregroundStyle(NativeDesktopTheme.text).accessibilityAddTraits(.isHeader)
                Text(verbatim: offer?.displayPrice ?? "₩0,000").font(NativeDesktopTheme.font(17, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
                    .redacted(reason: offer == nil && !failed ? .placeholder : []).opacity(failed ? 0 : 1)
                    .accessibilityIdentifier("plans-credit-price")
            }
            Text("이번 달 AI 사용량에 더해지고, 만료되지 않아요.").font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if signedIn {
                Text("남은 충전 잔액: AI 약 \(Referral.uses(usage.creditUcents).formatted())회").font(NativeDesktopTheme.font(13, weight: .medium))
                    .foregroundStyle(NativeDesktopTheme.text).accessibilityIdentifier("plans-credit-balance")
            } else {
                Text("로그인한 계정에 충전돼요. 로그인하면 살 수 있어요.").font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plans-credit-signin")
            }
        }
    }

    @ViewBuilder private var purchase: some View {
        VStack(alignment: .leading, spacing: 8) {
            if failed {
                HStack {
                    Text("가격을 불러오지 못했어요").font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.secondary)
                        .accessibilityIdentifier("plans-credit-unavailable")
                    Spacer(minLength: 4)
                    Button("다시 시도") { Task { await load() } }.buttonStyle(NativeToolButtonStyle(compact: true)).accessibilityIdentifier("plans-credit-retry")
                }
            } else {
                Button { Task { await buy() } } label: {
                    // Blank until StoreKit answers: the storefront's own price, never a placeholder number.
                    Group { if let offer { Text("\(offer.displayPrice) 충전") } else { Text(verbatim: " ") } }.frame(maxWidth: .infinity)
                }
                .buttonStyle(BandalButtonStyle(kind: .filled, fills: true))
                .disabled(offer == nil || buying || !signedIn)
                .overlay { if offer == nil || buying { ProgressView().controlSize(.small).tint(NativeDesktopTheme.onAccent) } }
                .accessibilityIdentifier("plans-credit-buy")
            }
            if let outcome {
                Label(outcome, systemImage: "checkmark.circle").font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.text)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plans-credit-outcome")
            }
        }
    }

    private func load() async {
        failed = false
        do { offer = try await StoreOffers.load([StoreSync.creditPack]).first; failed = offer == nil }
        catch { failed = true }
    }

    private func buy() async {
        guard let offer else { return }
        buying = true; defer { buying = false }
        outcome = AICreditPurchase.message(await StorePurchase.credit(offer), locale)
    }

    /// The fake server's counts, for the UI test (`--plans-server`); empty otherwise. Read in `body`, so it is
    /// current after every purchase.
    private var fixtureSummary: String {
        #if DEBUG
        PlansServerFixture.summary ?? ""
        #else
        ""
        #endif
    }
}

/// `--plans-width N` (DEBUG): 요금제 laid out N points wide, as in Split View or Slide Over, which a UI test
/// cannot open. The layout has no size-class branch, so the width is what decides it.
struct PlanWidthFixture: ViewModifier {
    #if DEBUG
    private static let width: CGFloat? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--plans-width"), index + 1 < arguments.count, let value = Double(arguments[index + 1]) else { return nil }
        return CGFloat(value)
    }()
    #endif
    func body(content: Content) -> some View {
        #if DEBUG
        if let width = Self.width {
            content.frame(width: width).overlay { Rectangle().strokeBorder(Color.red.opacity(0.5)) }.frame(maxWidth: .infinity)
        } else { content }
        #else
        content
        #endif
    }
}

/// What a 충전 came to, in one line: the plans screen and the 충전 popover say the same.
enum AICreditPurchase {
    static func message(_ outcome: StorePurchase.CreditOutcome, _ locale: Locale) -> String? {
        switch outcome {
        case .credited: NativeAppLocale.string("충전했어요", locale)
        case .awaitingServer: NativeAppLocale.string("결제됐어요. 곧 사용량에 더해져요.", locale)
        case .pending: NativeAppLocale.string("승인을 기다리고 있어요", locale)
        case .cancelled: nil
        case .failed(let reason): NativeAppLocale.string("구매하지 못했어요.", locale) + (reason.isEmpty ? "" : " " + reason)
        }
    }
}

/// 요금제's foot: restore, Apple's purchase history and manage sheet, the terms and the auto-renew notice.
struct PlanFooter: View {
    let restore: () -> Void
    let manage: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(spacing: 8) { actions }
            }
            .font(NativeDesktopTheme.font(13, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
            HStack(spacing: 8) {
                Link("이용약관", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    .accessibilityIdentifier("plans-terms-link")
                Text(verbatim: "·").accessibilityHidden(true)
                Link("개인정보처리방침", destination: URL(string: "https://bandal.io/privacy")!)
                    .accessibilityIdentifier("plans-privacy-link")
            }
            .font(NativeDesktopTheme.font(13, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).buttonStyle(.plain)
            VStack(spacing: 6) {
                Text("""
                Plus와 Pro는 고른 기간(월간 또는 연간)마다 위 카드에 표시된 가격으로 자동 갱신되며, 요금은 구매를 확인할 때 Apple ID로 청구돼요. \
                현재 기간(무료 체험 포함)이 끝나기 24시간 전까지 해지하지 않으면 다음 기간 요금이 청구돼요. \
                구독은 설정 › Apple ID › 구독에서 관리하고 해지할 수 있어요. Pro 무료 체험 기간의 AI 사용량은 Plus와 같아요.
                """)
                .accessibilityIdentifier("membership-terms")
                Text("AI 충전은 자동 갱신되지 않는 한 번의 구매예요. 로그인한 계정에 남고, 구매 복원으로 다시 받는 상품이 아니에요.")
                    .accessibilityIdentifier("plans-credit-terms")
            }
            .font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted).multilineTextAlignment(.center)
            .frame(maxWidth: 640).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        Button("구매 복원", action: restore).buttonStyle(BandalButtonStyle(kind: .soft)).accessibilityIdentifier("membership-restore")
        Link(destination: URL(string: "https://reportaproblem.apple.com")!) { Text("결제 내역") }
            .buttonStyle(BandalButtonStyle(kind: .soft)).accessibilityIdentifier("plans-purchase-history")
        Button("App Store에서 구독 해지·관리", action: manage).buttonStyle(BandalButtonStyle(kind: .soft)).accessibilityIdentifier("plans-manage")
    }
}

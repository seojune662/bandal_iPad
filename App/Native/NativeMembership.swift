import StoreKit
import SwiftUI
import UIKit

/// 충전 (consumable `app.bandal.ipad.credit.pack1`): one line and one price button, in a popover on the
/// 충전 button that opened it. It buys like 요금제 › AI 충전 (StorePurchase.credit): the server holds the
/// credit, so the transaction is finished only after it paid.
struct AICreditPopover: View {
    var message: String?
    let close: () -> Void
    @State private var offer: StoreOffer?
    @State private var failed = false
    @State private var buying = false
    @State private var outcome: String?
    @Environment(\.locale) private var locale

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
        guard let offer else { return }
        buying = true; defer { buying = false }
        if let line = AICreditPurchase.message(await StorePurchase.credit(offer), locale) { outcome = line }
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
        guard prompt.fresh else { return }
        message = prompt.message; open = true
    }
}

/// Settings › 구독·사용량 (Figma 132:3441): the plan card, this month's AI use and this iPad's storage, the usage
/// alert and Apple's purchase history. `detail` is its 더 보기: the free allowance, 충전 and invitation credit.
/// Buying, changing, restoring and cancelling are all on 요금제 (MembershipPaywall), which the card opens.
/// Signing in is never asked for.
struct NativeSettingsSubscriptionPanel: View {
    var store: NativeWorkspaceStore
    var detail = false
    var openDetail: () -> Void = {}
    @ObservedObject private var membership = Membership.shared
    @ObservedObject private var ai = AIUsage.shared
    @State private var usage: [String: Any] = [:]
    @AppStorage(NativeAIPreferences.usageAlertKey) private var usageAlert = true
    @State private var error: String?
    /// What the subscription does next (StoreKit), and what Bandal keeps on this iPad against the iPad's capacity.
    @State private var status: PlanStatus?
    @State private var storage: (used: Int64, total: Int64)?
    @Environment(\.locale) private var locale
    #if DEBUG
    /// A Plus member renewing on 10 December, for the design screenshots.
    private static let fixture = ProcessInfo.processInfo.arguments.contains("--native-settings-plan-fixture")
    #else
    private static let fixture = false
    #endif
    private var tier: Membership.Tier {
        #if DEBUG
        // `--plans-state`: the same plan as 요금제 shows.
        if PlanStatus.Fixture.active { return status?.tier ?? .free }
        #endif
        return Self.fixture ? .plus : membership.tier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let error { NativeToolError(message: error) }
            if detail { details } else { overview }
        }
        .task(id: membership.tier) {
            do { usage = try await store.invokePrivate("nativeMembership:usage") as? [String: Any] ?? [:] }
            catch { self.error = error.localizedDescription }
        }
        .task(id: membership.currentProduct) {
            status = Self.fixture ? PlanStatus(productID: "app.bandal.ipad.plus.monthly", periodEnd: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 10)))
                : await PlanStatus.load()
        }
        .task {
            await membership.refresh()
            _ = try? await store.invokePrivate("native:aiConfig", ["refresh": true])
            _ = try? await store.referral.loadStatus()
            if let status = try? await store.invokePrivate("nativeSettings:status") as? [String: Any],
               let used = ((status["storage"] as? [String: Any])?["documentsBytes"] as? NSNumber)?.int64Value,
               let total = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity { storage = (used, Int64(total)) }
            #if DEBUG
            // A Pro account out of AI, for the 충전 popover's UI test and screenshot.
            if ProcessInfo.processInfo.arguments.contains("--native-ai-usage-fixture") { ai.update(["plan": "pro", "percent": 100, "autoQuestionsLeft": 0]) }
            #endif
        }
    }

    @ViewBuilder private var overview: some View {
        HStack(spacing: 16) {
            Image(systemName: "moon").font(.system(size: 22)).foregroundStyle(NativeDesktopTheme.bgApp).frame(width: 48, height: 48)
                .background(PlanPalette.badge, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(tier == .pro ? "반달 프로" : tier == .plus ? "반달 플러스" : "반달 무료").font(.system(size: 20, weight: .bold))
                Group {
                    if tier == .free { Text("플러스는 폴더·자료 무제한, 프로는 AI를 플러스의 4배") }
                    else { summary(status?.lines().first) }
                }.font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("요금제 보기") { MembershipPaywall.present() }
                .buttonStyle(BandalButtonStyle(kind: .soft)).frame(height: 31).accessibilityIdentifier("native-membership-manage")
        }.padding(20).background(PlanPalette.fill, in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 8) {
            Text("이번 달 사용량").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityAddTraits(.isHeader)
            VStack(spacing: 20) {
                // Only with an account (the server's numbers); this panel never asks anyone to sign in.
                if let percent = ai.percent { meter("AI 사용량", value: "\(percent)%", fraction: Double(percent) / 100).accessibilityIdentifier("native-ai-usage") }
                if let storage { meter("저장 공간", value: Self.bytes(storage.used) + " / " + Self.bytes(storage.total), fraction: Double(storage.used) / Double(max(storage.total, 1))).accessibilityIdentifier("native-settings-storage") }
            }.padding(17).frame(maxWidth: .infinity).background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border))
            Text("AI 사용량은 매달 1일에 다시 채워져요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted)
        }
        NativeSettingsGroup {
            NativeSettingsToggle(title: "사용량 \(AIUsage.alertPercent)%가 되면 알림", isOn: $usageAlert).accessibilityIdentifier("native-settings-usage-alert")
            Link(destination: URL(string: "https://reportaproblem.apple.com")!) { NativeSettingsRow(title: "결제 내역") { NativeSettingsValue() } }
                .buttonStyle(.plain).accessibilityIdentifier("native-settings-purchase-history")
        }
        NativeSettingsMoreRow(action: openDetail)
    }

    /// The plan card's second line: what happens next, in short (요금제 has it in full).
    @ViewBuilder private func summary(_ line: PlanStatus.Line?) -> some View {
        switch line {
        case .renews(let date): Text("다음 결제일 \(date, format: .dateTime.month().day())")
        case .trial(let days, _, _): Text("무료 체험 중 · \(days)일 남음")
        case .ends(let date): Text("\(date, format: .dateTime.month().day())에 끝나요")
        case .billingIssue: Text("결제가 되지 않았어요")
        case .changes, nil: Text("결제일과 해지는 요금제 보기에서 볼 수 있어요")
        }
    }

    /// One line of the usage card: the name, the amount, and a 6 pt bar.
    private func meter(_ title: String, value: String, fraction: Double) -> some View {
        VStack(spacing: 8) {
            HStack { BandalText(title); Spacer(minLength: 8); Text(verbatim: value).fontWeight(.semibold) }.font(.system(size: 15))
            GeometryReader { bar in
                Capsule().fill(NativeDesktopTheme.surface)
                    .overlay(alignment: .leading) { Capsule().fill(NativeDesktopTheme.accent).frame(width: max(fraction > 0 ? 6 : 0, bar.size.width * min(fraction, 1))) }
            }.frame(height: 6)
        }.accessibilityElement(children: .ignore).accessibilityLabel(NativeAppLocale.string(title, locale)).accessibilityValue(value)
    }

    /// "3.2GB", as the design writes it.
    private static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file).replacingOccurrences(of: " ", with: "") }

    /// 구독·사용량 › 더 보기.
    @ViewBuilder private var details: some View {
        NativeSettingsGroup(title: "반달 멤버십", description: "이미 있는 폴더와 자료는 구독과 관계없이 계속 열고 고칠 수 있어요.") {
            LabeledContent("상태", value: Self.title(membership.tier)).accessibilityIdentifier("native-membership-state")
            if membership.tier < .plus {
                LabeledContent("이 iPad에서 만든 폴더", value: "\(usage["courses"] as? Int ?? 0) / \(FreeTier.courses)")
                LabeledContent("이 iPad에서 만든 자료", value: "\(usage["documents"] as? Int ?? 0) / \(FreeTier.documents)")
            }
        }
        if ai.percent != nil {
            NativeSettingsGroup(title: "AI 사용량", description: "매달 1일 00시(한국 시간)에 다시 채워져요") {
                if let left = ai.autoQuestionsLeft { Text("Auto 질문 약 \(left.formatted())회 남음") }
                if ai.creditUcents > 0 { Text("충전한 사용량이 남아 있어요 (위 회수에 포함).").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary) }
                // 충전 is bought on 요금제, as everything else here.
                Button("충전") { MembershipPaywall.present(focus: .credit) }.accessibilityIdentifier("native-settings-credit")
            }
        }
        // What invitations have brought this account so far. The server keeps one pooled balance,
        // so this is not what is left of it.
        if let uses = store.referral.status.map({ Referral.uses($0.creditMicrocents) }), uses > 0 {
            NativeSettingsGroup(title: NativeAppLocale.string("친구 초대", locale)) {
                NativeSettingsRow(title: NativeAppLocale.string("초대 크레딧", locale), note: NativeAppLocale.string("친구 초대로 지금까지 받은 양이에요", locale)) {
                    Text("AI \(uses)회").accessibilityIdentifier("native-referral-credit")
                }
            }
        }
    }

    static func title(_ tier: Membership.Tier) -> String {
        switch tier { case .free: "무료"; case .plus: "플러스 이용 중"; case .pro: "프로 이용 중" }
    }
}

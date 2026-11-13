import SwiftUI

/// The last model and effort picked anywhere; a conversation that never chose one uses these.
enum NativeAIPreferences {
    static let modelKey = "native.ai.model", effortKey = "native.ai.effort"
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "default" }
    static var effort: String { UserDefaults.standard.string(forKey: effortKey) ?? "medium" }
    static func remember(model: String, effort: String?) {
        UserDefaults.standard.set(model, forKey: modelKey)
        if let effort { UserDefaults.standard.set(effort, forKey: effortKey) }
    }
    static let efforts = ["low", "medium", "high", "max"]
    /// Settings › AI › 답변 언어: "auto" follows the question.
    static let answerLanguageKey = "native.ai.answerLanguage"
    static func languageInstruction(_ value: String? = UserDefaults.standard.string(forKey: answerLanguageKey)) -> String {
        switch value { case "ko": " 항상 한국어로 답하세요."; case "en": " Always answer in English."; default: "" }
    }
    /// Settings › AI › 참고 범위: "course" lets an answer read any material of the course, "note" only the note the question came from.
    static let referenceScopeKey = "native.ai.referenceScope"
    static var referenceScope: String { UserDefaults.standard.string(forKey: referenceScopeKey) == "note" ? "note" : "course" }
    /// Settings › AI › AI 답변 출처 표시: chips under an answer for the materials it read.
    static let showsSourcesKey = "native.ai.showsSources"
    /// Settings › AI › 대화 기록 저장: off, a conversation begun from then on is not listed and is deleted by the next launch.
    static let savesHistoryKey = "native.ai.savesHistory"
    static var savesHistory: Bool { NativeLocalPreferences.bool(savesHistoryKey) }
    /// Settings › 구독·사용량 › 사용량 80%가 되면 알림.
    static let usageAlertKey = "native.ai.usageAlert"
}

/// Colour and one-line use per model family, shared by the pill and the picker (Figma 194:10932).
enum NativeAIModelLook {
    private static let claude = NativeDesktopTheme.adaptive(0xd97757, 0xd97757), opus = NativeDesktopTheme.adaptive(0xa8502f, 0xa8502f)
    private static let gpt = NativeDesktopTheme.adaptive(0x10a37f, 0x10a37f), gemini = NativeDesktopTheme.adaptive(0x4c8df6, 0x4c8df6)
    static let premiumTag = NativeDesktopTheme.adaptive(0xfff5de, 0x3a2f1a)
    static func color(_ model: NativeAIModelCatalog.Model) -> Color {
        switch model.provider {
        case "anthropic": model.id.lowercased().contains("opus") ? opus : claude
        case "openai": gpt
        case "google": gemini
        default: NativeDesktopTheme.muted
        }
    }
    static func hint(_ model: NativeAIModelCatalog.Model) -> String {
        let id = model.id.lowercased()
        if id.contains("opus") { return "어려운 문제 · 깊은 분석" }
        if id.contains("haiku") { return "가벼운 질문 · 빠른 답변" }
        if model.provider == "anthropic" { return "긴 자료 요약 · 글쓰기" }
        if model.provider == "google" { return "이미지 · PDF 읽기" }
        return model.badge > 4 ? "가장 깊은 추론" : model.badge > 1 ? "복잡한 풀이 · 코드" : "빠른 답변 · 퀴즈 만들기"
    }
    /// Auto's dot: the three providers left to right.
    static var autoDot: some View { Circle().fill(LinearGradient(colors: [claude, gpt, gemini], startPoint: .leading, endPoint: .trailing)) }
}

/// "● Auto ⌄" / "● Sonnet 5.5 ⌄": the pill in the panel header, a capsule in the full tab.
/// Opens `NativeAIModelPicker` right under itself, leading edges 8 pt apart as in Figma.
struct NativeAIModelPill: View {
    let catalog: NativeAIModelCatalog
    let model: String
    let effort: String?
    var disabled = false
    /// The full tab's 39 pt capsule (F1) instead of the header's 22 pt pill (A1).
    var capsule = false
    let onSelect: (String, String?) -> Void
    let onOpenUsage: () -> Void
    var onAppear: () async -> Void = {}
    /// Composer actions the design has no button for; they sit at the foot of the popover.
    var onAttachDocument: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var canAnnotate = false
    /// 짚어주기 on or off; nil while no PDF is open.
    var onGuide: (() -> Void)?
    var guiding = false
    @State private var open = false
    private static let popoverWidth: CGFloat = 300

    static func label(_ catalog: NativeAIModelCatalog, model: String, effort: String?) -> String {
        guard model != "default", catalog.contains(model) else { return NativeAppLocale.string("자동", Locale.current) }
        return catalog.label(model) + " · " + (effort ?? "medium")
    }

    var body: some View {
        let chosen = catalog.models.first { $0.id == model }
        let shape = RoundedRectangle(cornerRadius: capsule ? 19.5 : 6, style: .continuous)
        Button { open.toggle() } label: {
            HStack(spacing: 9) {
                Group { if let chosen { Circle().fill(NativeAIModelLook.color(chosen)) } else { NativeAIModelLook.autoDot } }.frame(width: capsule ? 8 : 7, height: capsule ? 8 : 7)
                Group { if let chosen { Text(verbatim: chosen.label) } else { Text("자동") } }.font(.system(size: capsule ? 14 : 13, weight: .medium))
                    .foregroundStyle(capsule ? NativeDesktopTheme.text : NativeDesktopTheme.secondary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.secondary)
            }
            .padding(.horizontal, capsule ? 14 : 8).frame(height: capsule ? 39 : 22)
            .background(open ? NativeDesktopTheme.raised : NativeDesktopTheme.bgApp, in: shape)
            .overlay { if capsule { shape.strokeBorder(NativeDesktopTheme.border, lineWidth: 1) } }
            .assistantHitArea(capsule ? 3 : 11)
        }
        .buttonStyle(NativeAssistantButtonStyle()).disabled(disabled)
        .accessibilityLabel("AI 모델: " + Self.label(catalog, model: model, effort: effort)).accessibilityIdentifier("native-ai-model-pill")
        // The popover centres on its anchor: this one sits where the card's middle belongs.
        .background(alignment: .bottomLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                .bandalPopover(isPresented: $open, arrowEdge: .top, width: Self.popoverWidth, radius: 14, padding: 8) {
                    NativeAIModelPicker(catalog: catalog, model: model, effort: effort,
                                        onSelect: { selected, chosenEffort, closes in onSelect(selected, chosenEffort); if closes { open = false } },
                                        onOpenUsage: { open = false; onOpenUsage() },
                                        onAttachDocument: onAttachDocument.map { action in { open = false; action() } },
                                        onAnnotate: onAnnotate.map { action in { open = false; action() } }, canAnnotate: canAnnotate,
                                        onGuide: onGuide.map { action in { open = false; action() } }, guiding: guiding)
                        .task { await onAppear() }
                }
                .padding(.leading, Self.popoverWidth / 2 - 8)
        }
    }
}

/// The model list (Figma 154:10047, colours 194:10943): Auto first, then every model the server lists
/// with its colour, use and cost; under it 생각 깊이, this month's usage and 충전.
/// Every choice applies at once; a model pick closes the popover.
struct NativeAIModelPicker: View {
    let catalog: NativeAIModelCatalog
    let model: String
    let effort: String?
    /// (model, effort, closes the popover)
    let onSelect: (String, String?, Bool) -> Void
    var onOpenUsage: (() -> Void)?
    var onAttachDocument: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var canAnnotate = false
    var onGuide: (() -> Void)?
    var guiding = false
    /// The popover carries the 모델 heading; Settings has its own card title.
    var titled = true
    @ObservedObject private var usage = AIUsage.shared
    private static let rowHeight: CGFloat = 54, rowGap: CGFloat = 4, visibleRows: CGFloat = 6

    private var selected: String { model == "default" || !catalog.contains(model) ? "default" : model }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowGap) {
            if titled {
                VStack(alignment: .leading, spacing: 2) {
                    Text("모델").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
                    Text("반달이 제공 · 키 입력 필요 없음").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            ScrollView { VStack(spacing: Self.rowGap) { rows } }
                .frame(maxHeight: Self.visibleRows * Self.rowHeight + (Self.visibleRows - 1) * Self.rowGap).scrollBounceBehavior(.basedOnSize)
            divider
            effortRow
            if let percent = usage.percent { divider; usageBlock(percent) }
            if onAttachDocument != nil || onAnnotate != nil || onGuide != nil {
                divider
                if let onAttachDocument { extra("현재 문서 첨부", "doc.text", action: onAttachDocument).accessibilityIdentifier("native-ai-attach-document") }
                if let onAnnotate { extra("지목해서 질문", "scope", action: onAnnotate).disabled(!canAnnotate).accessibilityIdentifier("native-ai-annotate") }
                if let onGuide { extra(guiding ? "짚어주기 끄기" : "PDF에서 짚어주기", "hand.point.up.left", action: onGuide).accessibilityIdentifier("native-ai-guide") }
            }
        }
    }

    private var divider: some View { NativeDesktopTheme.border.frame(height: 1) }

    @ViewBuilder private var rows: some View {
        row(id: "default", title: Text("자동"), hint: "질문에 맞춰 알아서 고름", dot: AnyView(NativeAIModelLook.autoDot), badge: "추천", premium: false) { onSelect("default", nil, true) }
            .accessibilityIdentifier("native-ai-model-default")
        ForEach(catalog.models) { item in
            row(id: item.id, title: Text(verbatim: item.label), hint: NativeAIModelLook.hint(item), dot: AnyView(Circle().fill(NativeAIModelLook.color(item))),
                badge: "×\(item.badge)", premium: item.badge > 4) { onSelect(item.id, effort ?? NativeAIPreferences.effort, true) }
                .accessibilityIdentifier("native-ai-model-" + item.id)
        }
        if catalog.models.isEmpty {
            Text("로그인하면 다른 모델도 고를 수 있어요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func row(id: String, title: Text, hint: String, dot: AnyView, badge: String, premium: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(NativeDesktopTheme.accent).opacity(selected == id ? 1 : 0).frame(width: 18, height: 18)
                HStack(spacing: 9) {
                    dot.frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        title.font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1)
                        BandalText(hint).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                BandalText(badge).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(premium ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(premium ? NativeAIModelLook.premiumTag : NativeDesktopTheme.surface, in: Capsule())
            }
            .padding(.horizontal, 12).frame(height: Self.rowHeight)
            .background(selected == id ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected == id ? .isSelected : [])
    }

    private func usageBlock(_ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("이번 달 사용량").font(.system(size: 13, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                Spacer()
                Text(verbatim: "\(percent)%").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(NativeDesktopTheme.text)
            }
            RoundedRectangle(cornerRadius: 3).fill(NativeDesktopTheme.surface).frame(height: 6).overlay(alignment: .leading) {
                GeometryReader { bar in
                    RoundedRectangle(cornerRadius: 3).fill(percent >= 90 ? Color.orange : NativeDesktopTheme.accent)
                        .frame(width: bar.size.width * Double(min(100, max(0, percent))) / 100)
                }
            }
            HStack {
                if let onOpenUsage {
                    Button("구독·사용량에서 자세히 보기 ›", action: onOpenUsage).font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
                        .foregroundStyle(NativeDesktopTheme.accent).accessibilityIdentifier("native-ai-usage-details")
                }
                Spacer()
                AICreditButton().font(.system(size: 13, weight: .medium)).buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text)
                    .padding(.horizontal, 10).frame(height: 24).background(NativeDesktopTheme.surface, in: Capsule())
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// A composer action kept out of sight (owner's decision 1): attach the document, point at a region.
    private func extra(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 18, height: 18)
                BandalText(title).font(.system(size: 15, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var effortRow: some View {
        HStack(spacing: 8) {
            Text("생각 깊이").font(.system(size: 13, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize()
            Spacer(minLength: 4)
            if selected == "default" {
                Text("자동은 가볍게 고정").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.muted).accessibilityIdentifier("native-ai-effort-fixed")
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(zip(NativeAIPreferences.efforts, ["가볍게", "보통", "깊게", "최대"])), id: \.0) { value, title in
                        let on = (effort ?? NativeAIPreferences.effort) == value
                        Button { onSelect(selected, value, false) } label: {
                            BandalText(title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
                                .padding(.horizontal, 9).frame(height: 28)
                                .background(on ? NativeDesktopTheme.overlay : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 2, y: 1).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("native-ai-effort-" + value).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }.padding(2).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-effort")
            }
        }.frame(minHeight: 36).padding(.horizontal, 12)
    }
}

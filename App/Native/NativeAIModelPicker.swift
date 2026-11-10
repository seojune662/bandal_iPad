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
    /// Settings › 구독·사용량 › 사용량 80%가 되면 알림.
    static let usageAlertKey = "native.ai.usageAlert"
}

/// Colour and one-line use per model family, shared by the pill and the picker.
enum NativeAIModelLook {
    static func color(provider: String) -> Color {
        switch provider {
        case "anthropic": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "openai": Color(red: 0.06, green: 0.64, blue: 0.5)
        case "google": Color(red: 0.26, green: 0.52, blue: 0.96)
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
    /// Auto's dot: the three providers side by side.
    static var autoDot: some View {
        Circle().fill(AngularGradient(colors: [color(provider: "anthropic"), color(provider: "openai"), color(provider: "google"), color(provider: "anthropic")], center: .center))
    }
}

/// "● Auto ▾" / "● Sonnet 5.5 ▾": the composer's pill. Opens `NativeAIModelPicker` in a popover.
struct NativeAIModelPill: View {
    let catalog: NativeAIModelCatalog
    let model: String
    let effort: String?
    var disabled = false
    let onSelect: (String, String?) -> Void
    let onOpenUsage: () -> Void
    var onAppear: () async -> Void = {}
    @State private var open = false

    static func label(_ catalog: NativeAIModelCatalog, model: String, effort: String?) -> String {
        guard model != "default", catalog.contains(model) else { return "Auto" }
        return catalog.label(model) + " · " + (effort ?? "medium")
    }

    var body: some View {
        let chosen = catalog.models.first { $0.id == model }
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Group { if let chosen { Circle().fill(NativeAIModelLook.color(provider: chosen.provider)) } else { NativeAIModelLook.autoDot } }.frame(width: 7, height: 7)
                Text(chosen?.label ?? "Auto").lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(NativeDesktopTheme.raised.opacity(open ? 1 : 0.6), in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityLabel("AI 모델: " + Self.label(catalog, model: model, effort: effort)).accessibilityIdentifier("native-ai-model-pill")
        .bandalPopover(isPresented: $open, arrowEdge: .bottom, width: 320) {
            NativeAIModelPicker(catalog: catalog, model: model, effort: effort,
                                onSelect: { selected, chosenEffort, closes in onSelect(selected, chosenEffort); if closes { open = false } },
                                onOpenUsage: { open = false; onOpenUsage() })
                .task { await onAppear() }
        }
    }
}

/// The model list: Auto first, then every model with its colour, use and cost; under it 생각 깊이,
/// this month's usage and 충전. Every choice applies at once; a model pick closes the popover.
struct NativeAIModelPicker: View {
    let catalog: NativeAIModelCatalog
    let model: String
    let effort: String?
    /// (model, effort, closes the popover)
    let onSelect: (String, String?, Bool) -> Void
    var onOpenUsage: (() -> Void)?
    /// The popover carries the 모델 heading; Settings has its own card title.
    var titled = true
    @ObservedObject private var usage = AIUsage.shared

    private var selected: String { model == "default" || !catalog.contains(model) ? "default" : model }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if titled {
                VStack(alignment: .leading, spacing: 2) {
                    Text("모델").font(.system(size: 14, weight: .semibold))
                    Text("반달이 제공 · 키 입력 필요 없음").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                }.padding(.horizontal, 8).padding(.bottom, 2)
            }
            ScrollView { VStack(spacing: 2) { rows } }.frame(maxHeight: 300).scrollBounceBehavior(.basedOnSize)
            BandalMenuDivider()
            effortRow
            if let percent = usage.percent {
                BandalMenuDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("이번 달 사용량").foregroundStyle(NativeDesktopTheme.secondary); Spacer(); Text("\(percent)%").fontWeight(.semibold).monospacedDigit() }.font(.system(size: 12))
                    ProgressView(value: Double(min(100, max(0, percent))), total: 100).tint(percent >= 90 ? .orange : NativeDesktopTheme.accent)
                    HStack {
                        if let onOpenUsage {
                            Button("구독·사용량에서 자세히 보기 ›", action: onOpenUsage).font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                                .foregroundStyle(NativeDesktopTheme.text).accessibilityIdentifier("native-ai-usage-details")
                        }
                        Spacer()
                        AICreditButton().font(.system(size: 12, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26)
                            .background(NativeDesktopTheme.text.opacity(0.07), in: Capsule())
                    }
                }.padding(.horizontal, 8).padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var rows: some View {
        row(id: "default", title: "자동", hint: "질문에 맞춰 알아서 고름", dot: AnyView(NativeAIModelLook.autoDot), badge: "추천", accent: false) { onSelect("default", nil, true) }
            .accessibilityIdentifier("native-ai-model-default")
        ForEach(catalog.models) { item in
            row(id: item.id, title: item.label, hint: NativeAIModelLook.hint(item), dot: AnyView(Circle().fill(NativeAIModelLook.color(provider: item.provider))),
                badge: "×\(item.badge)", accent: item.badge > 4) { onSelect(item.id, effort ?? NativeAIPreferences.effort, true) }
                .accessibilityIdentifier("native-ai-model-" + item.id)
        }
        if catalog.models.isEmpty {
            Text("로그인하면 다른 모델도 고를 수 있어요").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
        }
    }

    private func row(id: String, title: String, hint: String, dot: AnyView, badge: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).opacity(selected == id ? 1 : 0).frame(width: 16)
                dot.frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(hint).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(badge).font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(accent ? Color.orange : NativeDesktopTheme.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(accent ? Color.orange.opacity(0.14) : NativeDesktopTheme.text.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
            .background(selected == id ? NativeDesktopTheme.text.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityAddTraits(selected == id ? .isSelected : [])
    }

    @ViewBuilder private var effortRow: some View {
        HStack(spacing: 8) {
            Text("생각 깊이").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize()
            Spacer(minLength: 4)
            if selected == "default" {
                Text("자동은 가볍게 고정").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).accessibilityIdentifier("native-ai-effort-fixed")
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(zip(NativeAIPreferences.efforts, ["가볍게", "보통", "깊게", "최대"])), id: \.0) { value, title in
                        let on = (effort ?? NativeAIPreferences.effort) == value
                        Button { onSelect(selected, value, false) } label: {
                            Text(title).font(.system(size: 12, weight: on ? .semibold : .regular)).padding(.horizontal, 9).frame(height: 28)
                                .background(on ? NativeDesktopTheme.overlay : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 2, y: 1).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("native-ai-effort-" + value).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }.padding(2).background(NativeDesktopTheme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-effort")
            }
        }.frame(minHeight: 32).padding(.horizontal, 8)
    }
}

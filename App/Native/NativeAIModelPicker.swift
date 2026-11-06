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
}

/// "Auto ▾" / "Sonnet 5.5 · high": the composer's pill. Opens `NativeAIModelPicker` in a popover.
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
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(Self.label(catalog, model: model, effort: effort)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(NativeDesktopTheme.raised.opacity(open ? 1 : 0.6), in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityLabel("AI 모델: " + Self.label(catalog, model: model, effort: effort)).accessibilityIdentifier("native-ai-model-pill")
        .bandalPopover(isPresented: $open, arrowEdge: .bottom, width: 340) {
            NativeAIModelPicker(catalog: catalog, model: model, effort: effort,
                                onSelect: { selected, chosenEffort, closes in onSelect(selected, chosenEffort); if closes { open = false } },
                                onOpenUsage: { open = false; onOpenUsage() })
                .task { await onAppear() }
        }
    }
}

/// Cursor-style model list: search, Auto first, provider groups with the cost badge, effort,
/// and this month's usage. Every choice applies at once; a model pick closes the popover.
struct NativeAIModelPicker: View {
    let catalog: NativeAIModelCatalog
    let model: String
    let effort: String?
    /// (model, effort, closes the popover)
    let onSelect: (String, String?, Bool) -> Void
    var onOpenUsage: (() -> Void)?
    var searchable = true
    @ObservedObject private var usage = AIUsage.shared
    @State private var query = ""

    private var selected: String { model == "default" || !catalog.contains(model) ? "default" : model }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchable {
                BandalSearchList(prompt: "모델 검색", query: $query, maxHeight: 300, identifier: "native-ai-model-search") { rows }
            } else { rows }
            BandalMenuDivider()
            effortRow
            if let percent = usage.percent, let onOpenUsage {
                BandalMenuDivider()
                HStack(spacing: 6) {
                    Text("이번 달 AI 사용량 \(percent)%").font(.system(size: 12)).foregroundStyle(percent >= 90 ? .orange : NativeDesktopTheme.secondary)
                    Spacer()
                    Button("자세히", action: onOpenUsage).font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                        .foregroundStyle(NativeDesktopTheme.text).accessibilityIdentifier("native-ai-usage-details")
                }.frame(minHeight: 28).padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if matches("Auto") {
            BandalMenuRow("Auto", detail: "빠르고 가장 적게 써요", checked: selected == "default") { onSelect("default", nil, true) }
                .accessibilityIdentifier("native-ai-model-default")
        }
        ForEach(catalog.providers, id: \.self) { provider in
            let models = catalog.models.filter { $0.provider == provider && matches($0.label) }
            if !models.isEmpty {
                BandalSectionHeader(provider == "anthropic" ? "Anthropic" : provider == "openai" ? "OpenAI" : provider.capitalized).padding(.horizontal, 8).padding(.top, 4)
                ForEach(models) { row in
                    BandalMenuRow(title: row.label, checked: selected == row.id, action: { onSelect(row.id, effort ?? NativeAIPreferences.effort, true) }) {
                        if row.badge > 1 {
                            Text("최대 \(row.badge)×").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(NativeDesktopTheme.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(NativeDesktopTheme.raised, in: Capsule())
                        }
                    }.accessibilityIdentifier("native-ai-model-" + row.id)
                }
            }
        }
        if catalog.models.isEmpty {
            Text("로그인하면 다른 모델도 고를 수 있어요").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).padding(.horizontal, 8).padding(.vertical, 4)
        }
    }

    @ViewBuilder private var effortRow: some View {
        HStack(spacing: 8) {
            Text("Effort").font(.system(size: 12, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize()
            Spacer(minLength: 4)
            if selected == "default" {
                Text("low 고정").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).accessibilityIdentifier("native-ai-effort-fixed")
            } else {
                Picker("Effort", selection: Binding(get: { effort ?? NativeAIPreferences.effort }, set: { onSelect(selected, $0, false) })) {
                    ForEach(NativeAIPreferences.efforts, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).frame(width: 236).accessibilityIdentifier("native-ai-effort")
            }
        }.frame(minHeight: 32).padding(.horizontal, 8)
    }
}

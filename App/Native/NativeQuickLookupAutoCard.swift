import SwiftUI

/// 자동 찾아보기's card: small and white, at the bottom corner of the document. The first line names the page it
/// opens (globe, the site underlined with ↗) and closes it with ✕; then the title, a formula when AI 설명 found one,
/// and two or three lines. A tap opens the page in a browser tab; a finger on it keeps it; it leaves by itself.
struct NativeQuickLookupCompactCard: View {
    let card: NativeQuickLookupCenter.Card
    let center: NativeQuickLookupCenter
    @Environment(\.colorScheme) private var scheme
    /// When the finger came down on the card, and whether it has moved since.
    @State private var touchedAt: Date?
    @State private var moved = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                // A tap opens the page. A finger left on the card (reading it) or moved over it keeps the card and opens nothing.
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if touchedAt == nil { touchedAt = Date(); moved = false; center.hold() }
                        if hypot(value.translation.width, value.translation.height) > 8 { moved = true }
                    }
                    .onEnded { _ in
                        let tap = !moved && Date().timeIntervalSince(touchedAt ?? .distantPast) < 0.5
                        touchedAt = nil; moved = false
                        if tap { center.openInBrowser() }
                    })
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                .accessibilityAction { center.openInBrowser() }
                .accessibilityIdentifier("native-quick-lookup-open").accessibilityHint(Text("브라우저 탭에서 열기"))
            Button { center.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary).padding(.top, 2).padding(.trailing, 4)
                .accessibilityLabel("닫기").accessibilityIdentifier("native-quick-lookup-close")
        }
        .frame(maxWidth: searchOnly ? 340 : 300, alignment: .leading)
        .fixedSize(horizontal: searchOnly, vertical: true)
        .foregroundStyle(NativeDesktopTheme.text)
        .background(NativeGlass.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 10, y: 3)
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-quick-lookup-card").accessibilityValue(state)
    }

    @ViewBuilder private var content: some View {
        if searchOnly {
            // Nothing was found: one line that searches the web when tapped, no page loaded by itself.
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 12, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityHidden(true)
                (Text("웹에서 검색").underline() + Text(verbatim: " ↗")).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
                Text(verbatim: card.query.text).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, 12).padding(.trailing, 38).frame(minHeight: 36)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "globe").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                    (Text(verbatim: domain).underline() + Text(verbatim: " ↗")).font(.system(size: 12)).lineLimit(1)
                    if card.explanation != nil {
                        Text("AI 설명").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(NativeDesktopTheme.accentMuted, in: Capsule()).accessibilityIdentifier("native-quick-lookup-ai")
                    }
                }.foregroundStyle(NativeDesktopTheme.secondary).padding(.trailing, 30).frame(minHeight: 22)
                Text(verbatim: title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let formula = card.explanation?.formula { NativeQuickLookupFormula(latex: formula) }
                Text(verbatim: summary).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.text.opacity(0.85))
                    .lineLimit(card.explanation?.formula == nil ? 3 : 2).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
        }
    }

    private var searchOnly: Bool {
        if card.explanation == nil, case .result(.search) = card.phase { return true }
        return false
    }
    /// The site the card opens, without "www.".
    private var domain: String {
        let host = NativeQuickLookupCenter.pageURL(card)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private var title: String {
        if let explanation = card.explanation { return explanation.topic }
        switch card.phase {
        case .result(.dictionary(let definition)): return definition.headword + (definition.pronunciation.map { "  " + $0 } ?? "")
        case .result(.wikipedia(let summary)): return summary.title
        default: return card.query.text
        }
    }
    private var summary: String {
        if let explanation = card.explanation { return explanation.summary }
        switch card.phase {
        case .result(.dictionary(let definition)): return definition.lines.joined(separator: "\n")
        case .result(.wikipedia(let summary)): return summary.extract
        default: return ""
        }
    }
    /// For UI tests and assistive technology, as the button's card says it: which answer the card holds.
    private var state: String {
        let base: String
        switch card.phase {
        case .result(.dictionary): base = "dictionary"
        case .result(.wikipedia(let summary)): base = "wikipedia-" + summary.language
        default: base = "search"
        }
        return card.explanation == nil ? "auto-" + base : "auto-ai-" + base
    }
}

/// A formula of AI 설명, typeset in one line; wider than the card it scrolls sideways.
private struct NativeQuickLookupFormula: View {
    let latex: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let math = NativeAnswerMath.render(latex, size: 15, display: false, scheme: scheme) {
            ScrollView(.horizontal, showsIndicators: false) { Image(uiImage: math.image) }
                .frame(height: min(math.image.size.height, 40))
                .accessibilityElement().accessibilityLabel(Text(verbatim: latex)).accessibilityIdentifier("native-quick-lookup-formula")
        } else {
            Text(verbatim: latex).font(.system(size: 13, design: .monospaced)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                .accessibilityIdentifier("native-quick-lookup-formula")
        }
    }
}

/// Asked once, the first time a selection would look itself up: where the text goes, then 켜기 or 나중에.
/// It stays until answered; 나중에 leaves the lookup off (설정 › AI › 찾아보기 turns it on).
struct NativeQuickLookupConsentCard: View {
    let center: NativeQuickLookupCenter
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text("고른 글을 바로 찾아볼까요?").font(.system(size: 15, weight: .semibold)) } icon: {
                Image(systemName: "text.magnifyingglass").font(.system(size: 13, weight: .medium))
            }
            Text("글을 고르면 위키백과에서 찾아 작은 카드로 보여 줘요. 선택한 글이 위키백과로 전송돼요. 설정 › AI에서 언제든 바꿀 수 있어요.")
                .font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.2)) { center.answerAutomatic(true) } } label: {
                    Text("켜기").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(NativeDesktopTheme.bgApp).background(NativeDesktopTheme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }.accessibilityIdentifier("native-quick-lookup-consent-on")
                Button { withAnimation(.easeOut(duration: 0.2)) { center.answerAutomatic(false) } } label: {
                    Text("나중에").font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, minHeight: 34)
                        .background(NativeDesktopTheme.accentMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                }.accessibilityIdentifier("native-quick-lookup-consent-later")
            }
        }
        .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text)
        .padding(12).frame(maxWidth: 300, alignment: .leading)
        .background(NativeGlass.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 10, y: 3)
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-quick-lookup-consent")
    }
}

/// 설정 › AI › 찾아보기: the automatic lookup and AI 설명.
struct NativeQuickLookupSettingsGroup: View {
    @AppStorage(NativeQuickLookupPreferences.autoKey) private var auto: Bool?
    @AppStorage(NativeQuickLookupPreferences.explainKey) private var explains = NativeQuickLookupPreferences.explainsByDefault
    init() { _ = NativeQuickLookupPreferences.ready }
    var body: some View {
        NativeSettingsGroup(title: "찾아보기", description: "단어 하나는 내장 사전, 그 밖은 위키백과에서 찾아요. AI 설명은 Plus·Pro에서 여러 줄을 골랐을 때만, 이미 동의한 AI 제공사의 가장 저렴한 모델로 한 번 보내요. 하루 Plus 30회, Pro 100회까지예요.") {
            NativeSettingsToggle(title: "글을 고르면 자동으로 찾아보기", note: "선택한 글이 위키백과로 전송돼요",
                                 isOn: Binding(get: { auto == true }, set: { auto = $0 })).accessibilityIdentifier("native-settings-auto-lookup")
            NativeSettingsToggle(title: "여러 줄은 AI가 짧게 설명", note: "선택한 글이 반달 서버를 거쳐 AI 제공사로 전송돼요", isOn: $explains)
                .disabled(auto != true).accessibilityIdentifier("native-settings-auto-lookup-ai")
        }
    }
}

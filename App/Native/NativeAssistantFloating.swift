import SwiftUI

/// How the workspace shows its AI conversation (the panel's 표시 방식 menu). Both show the same panel and
/// `NativeAssistantSession`; switching only moves it. Remembered across launches.
enum NativeAssistantPresentation: String {
    /// A column beside the document, in the slot the home sidebar also uses.
    case sidebar
    /// A small input bar over the document's bottom centre, the answer in a glass card above it.
    case floating

    static let key = "native.ai.presentation"
    var symbol: String { self == .sidebar ? "sidebar.left" : "rectangle.bottomthird.inset.filled" }
}

enum NativeAssistantFloatingMetrics {
    /// The bar and the card never grow wider than this, nor taller than `cardCeiling`; a longer answer scrolls in the card.
    static let maxWidth: CGFloat = 560
    static let cardCeiling: CGFloat = 380
    static let gap: CGFloat = 8
    static let sideMargin: CGFloat = 16
    static let bottomMargin: CGFloat = 12
    /// Kept clear at the top of the document: the tab strip and, under it, a PDF's tool palette.
    static let topClearance: CGFloat = 132
    static let cardRadius: CGFloat = 22
    static let barRadius: CGFloat = 24
    /// How far up from the document's bottom the bar and a full card can reach (the bar's own height, about 60,
    /// and the home-indicator inset, which the page runs under and the bar does not, included).
    static let reach: CGFloat = bottomMargin + 60 + gap + cardCeiling + 24
}

/// 플로팅: the input bar at the bottom, the card above it. The card is the header (model, 표시 방식, 새 대화, 접기,
/// 닫기) and, unless folded, the latest turn. Nothing here measures itself into state: the card's height is settled
/// in one layout pass by `NativeAssistantFloatingLayout`.
struct NativeAssistantFloatingStack<Header: View, Transcript: View, Composer: View>: View {
    let showsTranscript: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let transcript: Transcript
    @ViewBuilder let composer: Composer
    /// Set by `NativeAssistantHost` while the bar is closed or stepped aside: the card and bar leave the hierarchy
    /// (VoiceOver included; hiding them from accessibility does not reach these containers). The panel stays.
    @Environment(\.nativeAssistantFloatingHidden) private var hidden
    private typealias M = NativeAssistantFloatingMetrics

    var body: some View {
        ZStack { if !hidden { grouped.transition(.opacity.combined(with: .offset(y: 16))) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// From iOS 26 the card and bar are one glass group, so they read as one surface over the page.
    @ViewBuilder private var grouped: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: 0) { stack } } else { stack }
    }

    private var stack: some View {
        NativeAssistantFloatingLayout(ceiling: M.cardCeiling, gap: M.gap) {
            NativeGlassSurface(in: RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous)) {
                VStack(spacing: 0) {
                    header
                    if showsTranscript {
                        NativeGlass.hairline.frame(height: 1)
                        ScrollView {
                            transcript.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
                        }
                        // Opens on the end of the answer and stays there while it streams in.
                        .defaultScrollAnchor(.bottom)
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-floating-card")
            NativeGlassSurface(in: RoundedRectangle(cornerRadius: M.barRadius, style: .continuous)) {
                composer.padding(8)
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-floating-bar")
        }
        .frame(maxWidth: M.maxWidth)
        .padding(.horizontal, M.sideMargin).padding(.bottom, M.bottomMargin).padding(.top, M.topClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// Two subviews, card then bar: the bar at the bottom at its own height, the card above it at its own height up to
/// `ceiling` and up to what the bar leaves. The card's content scrolls in whatever it is given.
struct NativeAssistantFloatingLayout: Layout {
    let ceiling: CGFloat
    let gap: CGFloat

    private func heights(_ width: CGFloat, _ available: CGFloat?, _ subviews: Subviews) -> (card: CGFloat, bar: CGFloat) {
        guard subviews.count == 2 else { return (0, 0) }
        let bar = subviews[1].sizeThatFits(.init(width: width, height: nil)).height
        let room = max(0, (available ?? .infinity) - bar - gap)
        let card = subviews[0].sizeThatFits(.init(width: width, height: nil)).height
        return (min(card, ceiling, room), bar)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? NativeAssistantFloatingMetrics.maxWidth
        let h = heights(width, proposal.height, subviews)
        return CGSize(width: width, height: h.card + gap + h.bar)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let h = heights(bounds.width, bounds.height, subviews)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - h.bar), proposal: .init(width: bounds.width, height: h.bar))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - h.bar - gap - h.card), proposal: .init(width: bounds.width, height: h.card))
    }
}

/// Where the workspace draws its one AI panel: in its column beside the document (사이드바), or over the
/// document area (플로팅), where the panel lays out its bar and card at the bottom centre. The panel is the same
/// view in both places and is only moved, so switching keeps its draft, a streaming answer and its own state.
///
/// The column itself (its glass and divider) stays in the workspace's row; this draws the panel over it, cut to it.
struct NativeAssistantHost<Panel: View>: View {
    let floating: Bool
    /// The column is open, or the bar is shown.
    let visible: Bool
    /// Taking touches (not while the user marks an area for AI).
    let interactive: Bool
    /// The column's leading edge and width without its divider (사이드바).
    let columnLeading: CGFloat, columnWidth: CGFloat
    /// The document area's leading edge and width (플로팅).
    let documentLeading: CGFloat, documentWidth: CGFloat
    /// The PDFs on screen: the bar steps aside for what a page puts at its bottom.
    var paletteHost: NativePDFPaletteHost?
    @ViewBuilder let panel: Panel

    var body: some View {
        let page = floating ? pageBottom : (selecting: false, notice: false)
        // Marking an area for AI, or acting on a selection whose menu comes down where the bar is: out of the way until done.
        let shown = visible && (!floating || interactive && !page.selecting)
        HStack(spacing: 0) {
            panel.frame(width: floating ? documentWidth : columnWidth)
            Color.clear.frame(width: floating ? 0 : 1)
        }
        // A page's toast (노트에 넣었어요 · 되돌리기) sits at its bottom centre: the bar rises above it.
        .padding(.bottom, page.notice ? 64 : 0)
        .frame(width: floating ? documentWidth : (visible ? columnWidth + 1 : 0), alignment: .trailing)
        .frame(maxHeight: .infinity)
        // The column is cut at its sides (the input reaches below the home-indicator line); the floating card is not cut.
        .mask { Rectangle().padding(.bottom, -40).padding(floating ? -400 : 0) }
        .padding(.leading, floating ? documentLeading : columnLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: floating ? [shown, page.notice] : [])
        .allowsHitTesting(shown && interactive)
        .accessibilityHidden(!shown)
        .environment(\.nativeAssistantFloatingHidden, floating && !shown)
    }

    /// Read here, in the host's own body, so a PDF reporting its frame redraws only this view. Nothing is written back.
    private var pageBottom: (selecting: Bool, notice: Bool) {
        let entries = paletteHost.map { Array($0.entries.values) } ?? []
        let middle = documentLeading + documentWidth / 2, half = min(NativeAssistantFloatingMetrics.maxWidth, documentWidth) / 2 + 8
        let selecting = entries.contains { entry in
            guard entry.model.hasSelectionMenu, let selection = entry.model.selectionFrame else { return false }
            // `NativePDFSelectionBar` sits just above the selection (below it when there is no room), centred on it,
            // up to some 350 pt wide; the selection is in the page area's own space, the entry's frame in the window's.
            let lowest = entry.frame.minY + selection.maxY + 64, centre = entry.frame.minX + selection.midX
            return lowest > entry.frame.maxY - NativeAssistantFloatingMetrics.reach && abs(centre - middle) < half + 180
        }
        let models = entries.map(\.model)
        return (selecting, models.contains { $0.aiNoteNotice != nil || $0.paletteNotice != nil || $0.recordingNotice != nil || $0.mediaImportError != nil })
    }
}

extension EnvironmentValues {
    /// The floating card and bar are stepped aside (see `NativeAssistantHost`).
    @Entry var nativeAssistantFloatingHidden = false
}

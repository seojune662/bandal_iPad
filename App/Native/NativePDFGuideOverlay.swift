import SwiftUI

/// What 짚어주기 draws over the PDF body: the passage's lines lit, a laser pointer at their start, and the
/// step's note beside them. Only the note takes touches; a touch anywhere else reaches the page, which stops
/// the guide. Everything is positioned from what the host reported (`NativePDFGuidePlayer.target`) and the
/// overlay's own size; nothing it measures is written back anywhere.
struct NativePDFGuideOverlay: View {
    let guide: NativePDFGuidePlayer
    /// The band at the top the palette and the bars under it take.
    let top: CGFloat
    private static let mark = Color(uiColor: NativePDFSearchMarksView.currentMatch)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let target = guide.target {
                ForEach(Array(target.frames.enumerated()), id: \.offset) { _, frame in
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Self.mark.opacity(0.24))
                        .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Self.mark.opacity(0.9), lineWidth: 1.5) }
                        .frame(width: frame.width + 8, height: frame.height + 6)
                        .position(x: frame.midX, y: frame.midY)
                }
                .transition(.modifier(active: NativePDFGuideSweep(progress: 0.001), identity: NativePDFGuideSweep(progress: 1)).combined(with: .opacity))
                NativePDFGuidePointer().position(target.pointer).transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false).accessibilityHidden(true)
        .overlay {
            if guide.captioned, let step = guide.step {
                NativePDFGuideCaptionLayout(target: guide.target?.union, top: top, bottom: 0) {
                    NativePDFGuideCaption(step: step, number: guide.index + 1, count: guide.steps.count, revealed: guide.revealed, paused: guide.paused,
                                          found: guide.target != nil, guide: guide)
                        .id(guide.index)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: guide.target)
        .animation(.easeOut(duration: 0.2), value: guide.captioned)
        .animation(.easeOut(duration: 0.2), value: guide.index)
    }
}

/// A highlight drawn in from the passage's start.
private struct NativePDFGuideSweep: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View { content.scaleEffect(x: progress, y: 1, anchor: .leading) }
}

/// The laser pointer: the laser tool's red, with a slow ring around it.
private struct NativePDFGuidePointer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().stroke(Color(uiColor: .systemRed).opacity(pulse ? 0 : 0.55), lineWidth: 2).frame(width: 14, height: 14).scaleEffect(pulse ? 2.6 : 1)
            Circle().fill(Color(uiColor: .systemRed)).frame(width: 11, height: 11)
                .shadow(color: Color(uiColor: .systemRed).opacity(0.9), radius: 6)
                .overlay { Circle().fill(.white.opacity(0.85)).frame(width: 4, height: 4) }
        }
        .frame(width: 40, height: 40)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Puts the caption beside the passage, or along the bottom with no room there (`NativePDFGuidePlacement`).
/// It asks the caption its height at a width; that answer never leaves this layout pass.
private struct NativePDFGuideCaptionLayout: Layout {
    var target: CGRect?
    var top: CGFloat
    var bottom: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { proposal.replacingUnspecifiedDimensions() }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let caption = subviews.first else { return }
        let placed = NativePDFGuidePlacement.place(target: target, in: CGRect(origin: .zero, size: bounds.size), top: top, bottom: bottom) { width in
            caption.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        caption.place(at: CGPoint(x: bounds.minX + placed.frame.minX, y: bounds.minY + placed.frame.minY), anchor: .topLeading, proposal: ProposedViewSize(placed.frame.size))
    }
}

/// The note box. Its look lives only here, to become the shared glass surface later.
/// The whole note is laid out from the first character (the unwritten rest is clear), so the box keeps one
/// size while it is written.
private struct NativePDFGuideCaption: View {
    let step: NativePDFGuideStep
    let number: Int
    let count: Int
    let revealed: Int
    let paused: Bool
    let found: Bool
    let guide: NativePDFGuidePlayer
    private var written: AttributedString {
        var text = AttributedString(step.note)
        if revealed < step.note.count {
            text[text.index(text.startIndex, offsetByCharacters: max(0, revealed))...].foregroundColor = .clear
        }
        return text
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(verbatim: "\(number)/\(count) · p.\(step.page)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(NativeDesktopTheme.secondary)
                Spacer(minLength: 8)
                control("chevron.left", Text("이전 단계"), identifier: "previous") { guide.previous() }.disabled(number == 1)
                control(paused ? "play.fill" : "pause.fill", paused ? Text("계속") : Text("일시정지"), identifier: "pause") { guide.togglePause() }
                control("chevron.right", Text("다음 단계"), identifier: "next") { guide.next() }
                control("xmark", Text("짚어주기 닫기"), identifier: "close") { guide.close() }
            }
            Text(written).font(.system(size: 15)).lineSpacing(3).foregroundStyle(NativeDesktopTheme.text)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture { guide.advance() }
                .accessibilityLabel(Text(verbatim: step.note)).accessibilityAddTraits(.isButton)
                .accessibilityValue(Text(verbatim: "step=\(number)/\(count) page=\(step.page) found=\(found ? 1 : 0) written=\(revealed >= step.note.count ? 1 : 0)"))
                .accessibilityIdentifier("native-pdf-guide-note")
        }
        .padding(.leading, 14).padding(.trailing, 4).padding(.top, 2).padding(.bottom, 12)
        .background(NativeDesktopTheme.overlay.opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NativeDesktopTheme.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-guide-caption")
    }
    private func control(_ symbol: String, _ label: Text, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier("native-pdf-guide-" + identifier)
    }
}

/// The composer's row while 짚어주기 is on: what it does, and turning it off.
struct NativePDFGuideModeRow: View {
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.point.up.left").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).accessibilityHidden(true)
            Text("짚어주기").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.text)
            Text("PDF에서 위치를 짚으며 설명해요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted).frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("짚어주기 끄기").accessibilityIdentifier("native-ai-guide-off")
        }.frame(minHeight: 44).accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-guide-mode")
    }
}

import SwiftUI
import UIKit
import Combine

struct NativePDFTextEditor: View {
    @ObservedObject var draft: NativePDFTextDraft
    var isBusy = false
    var errorMessage: String? = nil
    var canCancel = true
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    @State private var extras = false

    /// Docked under the page (above the software keyboard); the text itself is edited on the page.
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).padding(.horizontal, 12).padding(.top, 8)
                    .accessibilityIdentifier("native-pdf-text-error")
            }
            HStack(alignment: .center, spacing: 4) {
                formatRow.disabled(errorMessage != nil)
                Spacer(minLength: 0)
                Button("취소", action: onCancel).disabled(isBusy || !canCancel).frame(minHeight: 44).padding(.horizontal, 6)
                    .accessibilityIdentifier("native-pdf-cancel-text")
                Button(errorMessage == nil ? "완료" : "다시 저장", action: finish).disabled(isBusy || !draft.hasText)
                    .font(.system(size: 15, weight: .semibold)).frame(minHeight: 44).padding(.horizontal, 6)
                    .accessibilityIdentifier("native-pdf-save-text")
            }.padding(.trailing, 8)
        }
        .background(NativeDesktopTheme.bgApp)
        .disabled(isBusy)
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-pdf-text-sheet")
    }

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Menu {
                        Button("본문 · 14 pt") { draft.preset(size: 14, bold: false) }.accessibilityIdentifier("native-pdf-text-preset-body")
                        Button("제목 · 24 pt") { draft.preset(size: 24, bold: true) }.accessibilityIdentifier("native-pdf-text-preset-title")
                        Button("주석 · 10 pt") { draft.preset(size: 10, bold: false) }.accessibilityIdentifier("native-pdf-text-preset-caption")
                    } label: { Label("스타일", systemImage: "textformat").frame(minHeight: 44).padding(.horizontal, 8) }
                    Button { draft.stepSize(-1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }.accessibilityLabel("글자 작게")
                    NativePDFTextSizeField(draft: draft).frame(width: 50, height: 44)
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    Button { draft.stepSize(1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("글자 크게")
                    Divider().frame(height: 24)
                    toggle("bold", symbol: "bold", label: "굵게", selected: draft.style.bold)
                    toggle("italic", symbol: "italic", label: "기울임", selected: draft.style.italic)
                    toggle("underline", symbol: "underline", label: "밑줄", selected: draft.style.underline)
                    Button { extras.toggle() } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("텍스트 추가 서식").accessibilityIdentifier("native-pdf-text-more")
                        .popover(isPresented: $extras) {
                            VStack(spacing: 0) {
                                HStack {
                                    Text("텍스트 서식").font(.headline)
                                    Spacer()
                                    Button("완료") { extras = false }.frame(minHeight: 44)
                                        .accessibilityIdentifier("native-pdf-text-format-close")
                                }.padding(.horizontal, 12)
                                Divider()
                                extraControls
                            }.frame(width: 340).padding(.bottom, 4)
                                .presentationCompactAdaptation(.popover)
                        }
                }.padding(.horizontal, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(["left", "center", "right"], id: \.self) { align in
                        Button { draft.apply(["align": align]) } label: {
                            Image(systemName: "text.align\(align)").frame(width: 44, height: 44)
                                .background(draft.boxStyle.align == align ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.accessibilityLabel(align == "left" ? "왼쪽 정렬" : align == "center" ? "가운데 정렬" : "오른쪽 정렬")
                            .accessibilityIdentifier("native-pdf-text-align-" + align)
                            .accessibilityAddTraits(draft.boxStyle.align == align ? .isSelected : [])
                    }
                    Divider().frame(height: 24)
                    colorButtons(fill: false)
                }.padding(.horizontal, 8)
            }
        }.buttonStyle(.plain).background(NativeDesktopTheme.bgApp)
    }
    private var extraControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Text("배경").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                    Button { draft.apply(["fill": NSNull()]) } label: {
                        Image(systemName: "nosign").frame(width: 44, height: 44)
                            .background(draft.boxStyle.fill == nil ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.accessibilityLabel("배경 없음").accessibilityIdentifier("native-pdf-text-fill-none")
                    colorButtons(fill: true)
                    toggle("strike", symbol: "strikethrough", label: "취소선", selected: draft.style.strike)
                }
            }
            HStack {
                Text("불투명도").font(.caption)
                Slider(value: Binding(get: { draft.boxStyle.opacity }, set: { draft.apply(["opacity": $0]) }), in: 0.1...1, step: 0.05)
                    .accessibilityIdentifier("native-pdf-text-opacity")
                Text("\(Int((draft.boxStyle.opacity * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 40)
            }
            HStack {
                Text("상자 너비").font(.caption)
                Slider(value: Binding(get: { draft.widthFraction }, set: { draft.setWidth($0) }), in: 0.02...1)
                    .accessibilityLabel("텍스트 상자 너비").accessibilityIdentifier("native-pdf-text-width")
                Text("\(Int(draft.physicalWidth.rounded())) pt").font(.caption.monospacedDigit()).frame(width: 50)
            }.frame(minHeight: 44)
            HStack {
                Button(draft.savedDefaults ? "기본 서식 저장됨" : "기본으로 저장") { commitPoint(); draft.saveDefaults() }
                    .frame(minHeight: 44).accessibilityIdentifier("native-pdf-text-default-save")
                Spacer()
                if draft.existing {
                    Button("삭제", role: .destructive, action: onDelete).frame(minHeight: 44)
                        .accessibilityIdentifier("native-pdf-text-delete")
                }
            }.font(.callout)
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }
    private func colorButtons(fill: Bool) -> some View {
        ForEach(Array(NativePDFTextStyle.colors.enumerated()), id: \.element) { index, color in
            let selected = fill ? draft.boxStyle.fill == color : draft.style.color == color
            Button { draft.apply([fill ? "fill" : "color": color], inline: !fill) } label: {
                ZStack {
                    Circle().fill(Color(uiColor: NativePDFObjectRenderer.color(color))).frame(width: 23, height: 23)
                    if selected { Circle().stroke(Color.primary, lineWidth: 2).frame(width: 31, height: 31) }
                    if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                }.frame(width: 44, height: 44)
            }.accessibilityLabel((fill ? "배경 " : "글자색 ") + NativePDFTextStyle.labels[index])
                .accessibilityIdentifier("native-pdf-text-" + (fill ? "fill-" : "color-") + color)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
    private func toggle(_ key: String, symbol: String, label: String, selected: Bool) -> some View {
        Button { draft.toggle(key) } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
                .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.accessibilityLabel(label).accessibilityIdentifier("native-pdf-text-" + key)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func commitPoint() { draft.finishPendingPointInput?(); draft.commitPointInput() }
    private func finish() { commitPoint(); draft.finishComposition(); onSave() }
}

struct NativePDFTextSizeField: UIViewRepresentable {
    @ObservedObject var draft: NativePDFTextDraft
    func makeCoordinator() -> Coordinator { Coordinator(draft) }
    func makeUIView(context: Context) -> SizeField {
        let field = SizeField(); field.keyboardType = .decimalPad; field.textAlignment = .center
        field.delegate = context.coordinator
        field.accessibilityLabel = "글자 크기 포인트"; field.accessibilityIdentifier = "native-pdf-text-size-input"
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.cancel = { [weak draft, weak field] in
            draft?.cancelPointInput(); field?.text = draft?.pointDraft; field?.resignFirstResponder()
        }
        draft.finishPendingPointInput = { [weak field, weak draft] in
            guard let field, field.isFirstResponder else { return }
            field.unmarkText(); draft?.pointDraft = field.text ?? ""; draft?.commitPointInput()
            field.text = draft?.pointDraft
            field.resignFirstResponder()
        }
        return field
    }
    func updateUIView(_ field: SizeField, context: Context) {
        if !field.isFirstResponder { field.text = draft.pointDraft }
    }
    static func dismantleUIView(_ field: SizeField, coordinator: Coordinator) { coordinator.draft.finishPendingPointInput = nil }
    final class Coordinator: NSObject, UITextFieldDelegate {
        let draft: NativePDFTextDraft
        init(_ draft: NativePDFTextDraft) { self.draft = draft }
        @objc func changed(_ field: UITextField) { draft.pointDraft = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) { draft.editingPoint = true; field.selectAll(nil) }
        func textFieldDidEndEditing(_ field: UITextField) {
            // Save/step/preset may already have committed and normalized the
            // field while it still owned focus. Do not resurrect its old draft.
            if draft.editingPoint { draft.pointDraft = field.text ?? ""; draft.commitPointInput() }
            field.text = draft.pointDraft
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            guard field.markedTextRange == nil else { return false }
            field.resignFirstResponder(); return false
        }
    }
    final class SizeField: UITextField {
        var cancel: (() -> Void)?
        override var keyCommands: [UIKeyCommand]? {
            (super.keyCommands ?? []) + [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
        }
        @objc private func escape() { guard markedTextRange == nil else { return }; cancel?() }
    }
}

/// Owns the on-page text view. The page overlay positions it from `view.pageBox`
/// and this controller rescales the typography to the overlay width.
@MainActor final class NativePDFTextInput: NSObject, UITextViewDelegate {
    let draft: NativePDFTextDraft
    let view = NativePDFTextInputView(usingTextLayoutManager: false)
    private var appliedRevision = -1
    private var appliedScale: CGFloat = 0
    private var updating = false
    private var revisions: AnyCancellable?
    init(draft: NativePDFTextDraft, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        super.init()
        view.delegate = self
        view.textContainer.lineFragmentPadding = 0
        view.layoutManager.usesFontLeading = true
        view.isScrollEnabled = false
        view.allowsEditingTextAttributes = false
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "native-pdf-text-editor"
        view.accessibilityLabel = "텍스트 상자 내용"
        view.pageBox = draft.box
        view.onLayout = { [weak self] in self?.update() }
        view.onSave = onSave; view.onCancel = onCancel
        draft.finishPendingInput = { [weak self] in
            guard let self else { return }
            view.unmarkText(); accept()
        }
        // @Published emits before the value lands; apply after the mutation settled.
        revisions = draft.$revision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            view.pageBox = draft.box; view.superview?.setNeedsLayout(); update()
        }
    }
    func update() {
        guard !updating, view.bounds.width > 0, view.markedTextRange == nil else { return }
        let scale = max(0.01, view.bounds.width / draft.physicalWidth)
        guard appliedRevision != draft.revision || abs(appliedScale - scale) > 0.0001 else { return }
        updating = true; defer { updating = false }
        let selected = draft.selection
        view.attributedText = draft.attributedText(scale: scale)
        let padding = NativePDFObjectRenderer.baseFontSize(draft.boxStyle.dictionary, surfaceWidth: draft.pageSize.width) * 0.36 * scale
        view.textContainerInset = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        view.textContainer.size = CGSize(width: max(1, view.bounds.width - padding * 2), height: .greatestFiniteMagnitude)
        view.selectedRange = selected
        view.typingAttributes = draft.typingAttributes(scale: scale)
        view.backgroundColor = draft.boxStyle.fill.map { NativePDFObjectRenderer.color($0).withAlphaComponent(0.18) } ?? .clear
        view.alpha = draft.boxStyle.opacity
        appliedRevision = draft.revision; appliedScale = scale
    }
    func accept() {
        // Before the first layout the view is empty; reading it back would wipe the draft.
        guard !updating, appliedRevision >= 0 else { return }
        draft.acceptEditorText(view.attributedText, selection: view.selectedRange, composing: view.markedTextRange != nil)
        appliedRevision = draft.revision
    }
    func detach() {
        draft.finishPendingInput = nil; revisions = nil
        view.delegate = nil; view.onLayout = nil; view.onSave = nil; view.onCancel = nil
    }
    func textViewDidChange(_ textView: UITextView) { accept() }
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !updating else { return }
        draft.setSelection(textView.selectedRange, composing: textView.markedTextRange != nil)
    }
}

final class NativePDFTextInputView: UITextView {
    /// Normalized page box the overlay maps to this view's frame.
    var pageBox: CGRect?
    var onLayout: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(finishFromKeyboard)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelFromKeyboard))
        ]
    }
    @objc func finishFromKeyboard() { guard markedTextRange == nil else { return }; onSave?() }
    @objc func cancelFromKeyboard() { guard markedTextRange == nil else { return }; onCancel?() }
}

import SwiftUI
import UIKit

/// A search field whose Esc and ⇧Return are UIKit key commands of the field itself. A focused SwiftUI
/// `TextField` keeps those keys, and scene-wide shortcuts would take them from every other field.
struct NativeSearchTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    var fontSize: CGFloat = 14
    /// Each increase takes focus (⌘F).
    var focusRequests = 0
    /// Return keeps the field editing, so it can be pressed again.
    var submitKeepsFocus = false
    var onSubmit: () -> Void = {}
    var onShiftSubmit: (() -> Void)?
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.accessibilityIdentifier = identifier
        field.returnKeyType = .search; field.autocapitalizationType = .none; field.autocorrectionType = .no; field.spellCheckingType = .no
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ view: Field, context: Context) {
        context.coordinator.parent = self
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = UIColor(NativeDesktopTheme.text)
        view.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(NativeGlass.fieldPrompt), .font: UIFont.systemFont(ofSize: fontSize)])
        view.shiftSubmit = onShiftSubmit; view.escape = onEscape
        // A syllable still being composed is the field's own; do not replace it.
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if context.coordinator.focusRequests != focusRequests {
            context.coordinator.focusRequests = focusRequests
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: uiView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeSearchTextField
        var focusRequests = 0
        init(_ parent: NativeSearchTextField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { if parent.text != field.text ?? "" { parent.text = field.text ?? "" } }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            if !parent.submitKeepsFocus { field.resignFirstResponder() }
            return false
        }
    }
    final class Field: UITextField {
        var shiftSubmit: (() -> Void)?
        var escape: (() -> Void)?
        override var keyCommands: [UIKeyCommand]? {
            // Esc during Korean composition cancels the syllable, as everywhere else.
            guard markedTextRange == nil else { return super.keyCommands }
            var commands = [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))]
            if shiftSubmit != nil { commands.append(UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(back))) }
            commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
            return commands + (super.keyCommands ?? [])
        }
        @objc private func cancel() { escape?() }
        @objc private func back() { shiftSubmit?() }
    }
}

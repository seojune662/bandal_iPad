import SwiftUI
import UIKit

/// A real URL field keeps the user's draft while a page redirects, selects the
/// entire URL on focus and supplies desktop-style suggestion keys to UIKit.
struct NativeBrowserAddressField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onMove: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.placeholder = "검색 또는 웹사이트 주소"
        field.accessibilityIdentifier = "native-browser-address"
        field.font = .systemFont(ofSize: 14)
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ view: Field, context: Context) {
        context.coordinator.parent = self
        view.move = onMove; view.escape = onEscape
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if focused != view.isFirstResponder {
            if focused { DispatchQueue.main.async { if self.focused { view.becomeFirstResponder() } } }
            else { view.resignFirstResponder() }
        }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeBrowserAddressField
        init(_ parent: NativeBrowserAddressField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.focused = true
            // The binding's focus callback restores the full URL before select.
            DispatchQueue.main.async { if field.isFirstResponder { field.selectAll(nil) } }
        }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focused = false }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { parent.onSubmit(); return false }
    }
    final class Field: UITextField {
        var move: ((Int) -> Void)?
        var escape: (() -> Void)?
        override var keyCommands: [UIKeyCommand]? {
            guard markedTextRange == nil else { return super.keyCommands }
            return [UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
             UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
             UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))]
        }
        @objc private func down() { move?(1) }
        @objc private func up() { move?(-1) }
        @objc private func cancel() { escape?() }
    }
}

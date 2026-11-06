import SwiftUI

/// Shared chrome for choices and edits made in place (1.4.0 UX pass): a popover anchored to the
/// control that opened it, compact menu rows, inline rename, a search list, a one-line confirm and a toast.
/// Sheets stay only where the system requires one (StoreKit, sign-in, file import, AI consent).
enum BandalMetrics {
    static let rowHeight: CGFloat = 36
    static let bodySize: CGFloat = 13
    static let headerSize: CGFloat = 11
    static let padding: CGFloat = 12
    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 8
    static let radiusLarge: CGFloat = 12
    static let shadow = Color.black.opacity(0.14)
}

extension View {
    /// A popover anchored to this view: arrow, closes on an outside tap or Esc, stays a popover in compact width.
    func bandalPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top, width: CGFloat? = 280,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(BandalDeferredPopover(isPresented: isPresented, arrowEdge: arrowEdge) {
            BandalPopoverBody(width: width, close: { isPresented.wrappedValue = false }, content: content)
        })
    }

    /// The anchored one-line confirmation that replaces `confirmationDialog`: title, optional one-line
    /// message and a single action; cancel is an outside tap or Esc.
    func bandalConfirm(_ title: String, isPresented: Binding<Bool>, message: String? = nil, action actionTitle: String,
                       destructive: Bool = false, identifier: String? = nil, perform: @escaping () -> Void) -> some View {
        bandalPopover(isPresented: isPresented, width: 260) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: BandalMetrics.bodySize, weight: .semibold))
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button(actionTitle) { isPresented.wrappedValue = false; perform() }
                        .font(.system(size: BandalMetrics.bodySize, weight: .semibold))
                        .foregroundStyle(destructive ? Color.red : NativeDesktopTheme.onAccent)
                        .padding(.horizontal, 12).frame(minHeight: 32)
                        .background(destructive ? Color.red.opacity(0.12) : NativeDesktopTheme.accent, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
                        .buttonStyle(.plain).accessibilityIdentifier(identifier ?? "bandal-confirm")
                }
            }
        }
    }

    /// A transient message at the bottom of this view; the binding clears itself after a few seconds.
    func bandalToast(_ message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) { BandalToast(message: message) }
    }
}

/// Presents a turn after the request: a popover asked for from a Menu item while that menu is
/// still closing is otherwise dropped, and the state stays "presented" with nothing on screen.
private struct BandalDeferredPopover<Body: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    @ViewBuilder let body: () -> Body
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .popover(isPresented: Binding(get: { shown }, set: { shown = $0; if !$0 { isPresented = false } }), arrowEdge: arrowEdge, content: body)
            .onChange(of: isPresented, initial: true) { _, wanted in
                if wanted { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if isPresented { shown = true } } } else { shown = false }
            }
    }
}

private struct BandalPopoverBody<Content: View>: View {
    let width: CGFloat?
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(BandalMetrics.padding)
            .frame(width: width, alignment: .leading)
            .foregroundStyle(NativeDesktopTheme.text)
            .background(NativeDesktopTheme.overlay)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(NativeDesktopTheme.overlay)
            .background { BandalEscapeKey(action: close) }
    }
}

extension Binding where Value == Bool {
    /// "Row `id` is being renamed" over one shared id: closing a row only clears the id while it is
    /// still that row's, so a field torn down after another row took over cannot cancel the new one.
    static func editing(_ id: String, in state: Binding<String?>) -> Binding<Bool> {
        Binding(get: { state.wrappedValue == id }, set: { if $0 { state.wrappedValue = id } else if state.wrappedValue == id { state.wrappedValue = nil } })
    }
}

/// Section header: 11pt, grey, bold capitals.
struct BandalSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased()).font(.system(size: BandalMetrics.headerSize, weight: .bold)).foregroundStyle(NativeDesktopTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).accessibilityAddTraits(.isHeader)
    }
}

/// One menu row: icon, title, an optional trailing detail (shortcut, badge) and a checkmark.
struct BandalMenuRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    var detail: String?
    var checked = false
    var destructive = false
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(destructive ? Color.red : NativeDesktopTheme.secondary) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: BandalMetrics.bodySize)).foregroundStyle(destructive ? Color.red : NativeDesktopTheme.text).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1) }
                }
                Spacer(minLength: 8)
                trailing()
                if checked { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(NativeDesktopTheme.accent) }
            }
            .padding(.horizontal, 8).frame(minHeight: BandalMetrics.rowHeight).contentShape(Rectangle())
        }.buttonStyle(BandalRowStyle())
    }
}

extension BandalMenuRow where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil, detail: String? = nil, checked: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, detail: detail, checked: checked, destructive: destructive, action: action) { EmptyView() }
    }
}

/// Grouped menu: rows separated by thin dividers, used inside a `bandalPopover`.
struct BandalMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { content() }.padding(-4) }
}

struct BandalMenuDivider: View {
    var body: some View { NativeDesktopTheme.border.frame(height: 1).padding(.vertical, 4) }
}

struct BandalRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
    }
}

/// Text that turns into a field in place: double-tap or `isEditing = true` (from a menu's 이름 변경),
/// Enter or losing focus commits, Esc cancels. Empty or unchanged text commits nothing.
struct BandalInlineEditor: View {
    let text: String
    @Binding var isEditing: Bool
    var font: Font = .system(size: BandalMetrics.bodySize)
    var identifier: String?
    let commit: (String) -> Void

    var body: some View {
        if isEditing {
            BandalEscapableField(initial: text, identifier: identifier.map { $0 + "-field" } ?? "bandal-inline-field") { value in
                isEditing = false
                if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value != text { commit(value) }
            }
            .padding(.horizontal, 4).frame(minHeight: 24)
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(NativeDesktopTheme.accent.opacity(0.5)) }
        } else {
            Text(text).font(font).lineLimit(1)
                .simultaneousGesture(TapGesture(count: 2).onEnded { isEditing = true })
                .accessibilityAction(named: "이름 변경") { isEditing = true }
        }
    }
}

/// A UIKit field because SwiftUI's TextField swallows a hardware Esc: `finish` gets the text on
/// Enter or focus loss and nil on Esc, once.
struct BandalEscapableField: UIViewRepresentable {
    let initial: String
    let identifier: String
    let finish: (String?) -> Void

    final class Field: UITextField {
        var onEscape: (() -> Void)?
        private var outsideTap: UITapGestureRecognizer?
        /// Focus as soon as the field is in a window (a menu may still be closing when it is made).
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, outsideTap == nil else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
            tap.cancelsTouchesInView = false
            window.addGestureRecognizer(tap); outsideTap = tap
            DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder(); self?.selectAll(nil) }
        }
        func detach() { if let outsideTap { outsideTap.view?.removeGestureRecognizer(outsideTap) }; outsideTap = nil }
        /// UIKit keeps a field focused on a tap elsewhere; here that tap ends editing (and commits).
        @objc private func tappedOutside(_ tap: UITapGestureRecognizer) {
            if !bounds.contains(tap.location(in: self)) { resignFirstResponder() }
        }
        override var keyCommands: [UIKeyCommand]? {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
            escape.wantsPriorityOverSystemBehavior = true
            return [escape] + (super.keyCommands ?? [])
        }
        @objc private func escape() { onEscape?() }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var finish: (String?) -> Void
        var done = false
        init(finish: @escaping (String?) -> Void) { self.finish = finish }
        func end(_ value: String?) { guard !done else { return }; done = true; finish(value) }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { end(field.text); return false }
        func textFieldDidEndEditing(_ field: UITextField) { end(field.text) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }
    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.text = initial
        field.font = .systemFont(ofSize: BandalMetrics.bodySize)
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.accessibilityIdentifier = identifier
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onEscape = { [weak field, coordinator = context.coordinator] in coordinator.end(nil); field?.resignFirstResponder() }
        return field
    }
    func updateUIView(_ field: Field, context: Context) { context.coordinator.finish = finish }
    static func dismantleUIView(_ field: Field, coordinator: Coordinator) { field.detach() }
}

/// A one-line entry in a popover (new name, URL, formula): Enter commits, Esc or an outside tap cancels.
struct BandalTextEntry: View {
    let title: String
    let prompt: String
    var initial = ""
    var actionTitle = "확인"
    var keyboard: UIKeyboardType = .default
    var identifier = "bandal-text-entry"
    var submitIdentifier: String?
    let commit: @MainActor (String) async throws -> Void
    @State private var value = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: BandalMetrics.headerSize, weight: .bold)).foregroundStyle(NativeDesktopTheme.muted)
            HStack(spacing: 6) {
                TextField(prompt, text: $value).font(.system(size: BandalMetrics.bodySize)).textFieldStyle(.plain)
                    .keyboardType(keyboard).textInputAutocapitalization(keyboard == .URL ? .never : .sentences).autocorrectionDisabled(keyboard == .URL)
                    .focused($focused).onSubmit(submit).disabled(busy)
                    .padding(.horizontal, 8).frame(minHeight: 32)
                    .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
                    .overlay { RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall).stroke(NativeDesktopTheme.border) }
                    .accessibilityIdentifier(identifier)
                Button(actionTitle, action: submit).font(.system(size: BandalMetrics.bodySize, weight: .semibold))
                    .disabled(busy || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 32).accessibilityIdentifier(submitIdentifier ?? identifier + "-submit")
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2) }
        }
        .onAppear { value = initial; focused = true }
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await commit(trimmed) } catch { self.error = error.localizedDescription; focused = true }
        }
    }
}

/// Search field (focused on appear) over a scrolling list; the caller filters with `query`.
struct BandalSearchList<Content: View>: View {
    var prompt = "검색"
    @Binding var query: String
    var maxHeight: CGFloat = 360
    var identifier = "bandal-search"
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                TextField(prompt, text: $query).font(.system(size: BandalMetrics.bodySize)).textFieldStyle(.plain)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).focused($focused).accessibilityIdentifier(identifier)
            }.padding(.horizontal, 8).frame(minHeight: 32)
                .background(NativeDesktopTheme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
            ScrollView { VStack(alignment: .leading, spacing: 0) { content() } }.frame(maxHeight: maxHeight).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focused = true }
    }
}

struct BandalToast: View {
    @Binding var message: String?
    var body: some View {
        ZStack {
            if let message {
                Text(message).font(.system(size: BandalMetrics.bodySize)).foregroundStyle(NativeDesktopTheme.onAccent)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(NativeDesktopTheme.accent.opacity(0.92), in: Capsule())
                    .shadow(color: BandalMetrics.shadow, radius: 10, y: 4)
                    .padding(.bottom, 24).padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { self.message = nil }
                    .accessibilityIdentifier("bandal-toast")
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        if self.message == message { withAnimation { self.message = nil } }
                    }
            }
        }.animation(.easeOut(duration: 0.2), value: message)
    }
}

/// Esc from a hardware keyboard. A focused text field swallows `onKeyPress`, a cancel shortcut still fires.
struct BandalEscapeKey: View {
    let action: () -> Void
    var body: some View {
        Button("", action: action).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

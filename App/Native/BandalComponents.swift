import SwiftUI

/// Shared chrome for choices and edits made in place (1.4.0 UX pass): a popover anchored to the
/// control that opened it, compact menu rows, inline rename, a search list, a one-line confirm and a toast.
/// Sheets stay only where the system requires one (StoreKit, sign-in, file import, AI consent).
enum BandalMetrics {
    /// A menu row in a glass popover (Figma: 42, or 62 with a detail line).
    static let rowHeight: CGFloat = 42
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
    /// `arrowEdge: nil` lets the system pick the side with room (a prompt that may open next to the keyboard).
    /// `radius` and `padding` follow the Figma frame of that popover (menus 8, forms 18).
    /// `dims: false` leaves the screen behind as it is (the note's tool popovers: Figma 261:8407 has no dimming layer).
    func bandalPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge? = .top, width: CGFloat? = 280,
                                      radius: CGFloat = 22, padding: CGFloat = BandalMetrics.padding, fill: Color = NativeGlass.popup, dims: Bool = true,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(BandalDeferredPopover(isPresented: isPresented, arrowEdge: arrowEdge, dims: dims) {
            BandalPopoverBody(width: width, radius: radius, padding: padding, fill: fill, arrowEdge: arrowEdge, close: { isPresented.wrappedValue = false }, content: content)
        })
    }

    /// The same popover placed by a point instead of this view's frame: the card's near edge sits 6 pt from
    /// `anchor` (a unit point of this view) moved by `offset`, centred on it. `bare` leaves the card to the content,
    /// which then draws its own (`bandalPopoverSurface`): a menu with a second card beside it.
    func bandalPopover<Content: View>(isPresented: Binding<Bool>, at anchor: UnitPoint, offset: CGSize = .zero, arrowEdge: Edge? = .top, width: CGFloat? = 280,
                                      radius: CGFloat = 22, padding: CGFloat = BandalMetrics.padding, bare: Bool = false,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.frame(width: 1, height: 1)
                    .modifier(BandalDeferredPopover(isPresented: isPresented, arrowEdge: arrowEdge) {
                        BandalPopoverBody(width: width, radius: radius, padding: padding, arrowEdge: arrowEdge, bare: bare, close: { isPresented.wrappedValue = false }, content: content)
                    })
                    .position(x: proxy.size.width * anchor.x + offset.width, y: proxy.size.height * anchor.y + offset.height)
            }.allowsHitTesting(false)
        }
    }

    /// The anchored one-line confirmation that replaces `confirmationDialog`: title, optional one-line
    /// message and a single action; cancel is an outside tap or Esc.
    func bandalConfirm(_ title: String, isPresented: Binding<Bool>, message: String? = nil, action actionTitle: String,
                       destructive: Bool = false, identifier: String? = nil, perform: @escaping () -> Void) -> some View {
        bandalPopover(isPresented: isPresented, width: 260) {
            VStack(alignment: .leading, spacing: 8) {
                BandalText(title).font(.system(size: BandalMetrics.bodySize, weight: .semibold))
                if let message { BandalText(message).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button { isPresented.wrappedValue = false; perform() } label: { BandalText(actionTitle) }
                        .font(.system(size: BandalMetrics.bodySize, weight: .semibold))
                        .foregroundStyle(destructive ? Color.red : Color.white)
                        .padding(.horizontal, 12).frame(minHeight: 32)
                        .background(destructive ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(NativeGlass.accent), in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
                        .buttonStyle(.plain).accessibilityIdentifier(identifier ?? "bandal-confirm")
                }
            }
        }
    }

    /// A popover's surface: the design's own glass card with no arrow and no system chrome.
    /// `arrowEdge` is the one given to `.popover`: the card sits on the opposite side of the anchor.
    func bandalPopoverSurface(radius: CGFloat = 22, arrowEdge: Edge? = .top, fill: Color = NativeGlass.popup) -> some View {
        bandalGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), fill: fill)
            .presentationBackground(.clear)
    }

    /// Anything that floats (palette, bars, popovers, menus, toasts): Figma `Glass/팝업`. A tint over glass,
    /// a 0.5 pt rim and one soft shadow (0, 8, blur 48).
    /// `adaptive: false` for a bar that floats over the white page: system glass there turns light and hands its
    /// content (and the popovers it opens) a light scheme in dark mode; a material keeps the app's.
    func bandalGlass<S: InsettableShape>(in shape: S, fill: Color = NativeGlass.popup, adaptive: Bool = true) -> some View {
        modifier(BandalGlassSurface(shape: shape, fill: fill, adaptive: adaptive))
    }

    /// A transient message at the bottom of this view; the binding clears itself after a few seconds.
    func bandalToast(_ message: Binding<String?>, symbol: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        overlay(alignment: .bottom) { BandalToast(message: message, symbol: symbol, actionTitle: actionTitle, action: action) }
    }
}

/// Presents a turn after the request: a popover asked for from a Menu item while that menu is
/// still closing is otherwise dropped, and the state stays "presented" with nothing on screen.
private struct BandalDeferredPopover<Body: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge?
    var dims = true
    @ViewBuilder let body: () -> Body
    @State private var shown = false
    @State private var appeared = false
    @Environment(\.self) private var environment
    func body(content: Content) -> some View {
        let presented = Binding(get: { shown }, set: { shown = $0; if !$0 { isPresented = false } })
        return content
            .background { BandalPopoverPresenter(isPresented: presented, edge: arrowEdge, dims: dims, environment: environment) { body().onAppear { appeared = true } } }
            .onChange(of: isPresented, initial: true) { _, wanted in
                if wanted { NativeInputTrace.record("popover.wanted") }
                guard wanted else { shown = false; appeared = false; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if !isPresented { NativeInputTrace.record("popover.withdrawn", "the binding went false within 50 ms of asking") }
                    if isPresented { shown = true }
                }
                // Still not on screen after the menu has surely closed: ask once more.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard isPresented, !appeared else { return }
                    shown = false
                    DispatchQueue.main.async { if isPresented { shown = true } }
                }
            }
    }
}

private struct BandalPopoverBody<Content: View>: View {
    let width: CGFloat?
    var radius: CGFloat = 22
    var padding = BandalMetrics.padding
    /// The tint over the glass; a popover over a dimmed sheet passes a denser one.
    var fill = NativeGlass.popup
    var arrowEdge: Edge? = .top
    var bare = false
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        card.presentationCompactAdaptation(.popover)
            .background { BandalEscapeKey(action: close) }
    }
    @ViewBuilder private var card: some View {
        let inner = content().padding(padding).frame(width: width, alignment: .leading).foregroundStyle(NativeDesktopTheme.text)
        if bare { inner } else { inner.bandalPopoverSurface(radius: radius, arrowEdge: arrowEdge, fill: fill) }
    }
}

private struct BandalGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    var adaptive = true
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        glass(content.background(fill, in: shape))
            .overlay { shape.strokeBorder(NativeGlass.rim, lineWidth: 0.5).allowsHitTesting(false) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.25), radius: 24, y: 8)
    }
    @ViewBuilder private func glass(_ view: some View) -> some View {
        if #available(iOS 26, *), adaptive { view.glassEffect(.regular, in: shape) }
        else { view.background(.ultraThinMaterial, in: shape) }
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
    @Environment(\.locale) private var locale
    init(_ title: String) { self.title = title }
    var body: some View {
        // Upper-cased after the lookup, as a string: VoiceOver and UI tests read "APPLE 캘린더" as before.
        Text(verbatim: NativeAppLocale.string(title, locale).uppercased()).font(.system(size: BandalMetrics.headerSize, weight: .bold)).foregroundStyle(NativeDesktopTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).accessibilityAddTraits(.isHeader)
    }
}

/// One menu row: icon, title, an optional trailing detail (shortcut, badge) and a checkmark.
struct BandalMenuRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    /// A drawn icon from the asset catalog (template, 20 pt), where the design has its own instead of an SF Symbol.
    var asset: String?
    var detail: String?
    var checked = false
    var destructive = false
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let asset { Image(asset).frame(width: 20, height: 20).foregroundStyle(destructive ? Color.red : NativeGlass.icon) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 17)).frame(width: 20, height: 20).foregroundStyle(destructive ? Color.red : NativeGlass.icon) }
                VStack(alignment: .leading, spacing: 2) {
                    BandalText(title).font(.system(size: 16, weight: .medium)).foregroundStyle(destructive ? Color.red : NativeDesktopTheme.text).lineLimit(1)
                    if let detail { BandalText(detail).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                trailing()
                if checked { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(NativeDesktopTheme.accent) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: BandalMetrics.rowHeight).contentShape(Rectangle())
        }.buttonStyle(BandalRowStyle())
    }
}

extension BandalMenuRow where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil, asset: String? = nil, detail: String? = nil, checked: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, asset: asset, detail: detail, checked: checked, destructive: destructive, action: action) { EmptyView() }
    }
}

/// Grouped menu: rows separated by thin dividers, used inside a `bandalPopover`.
struct BandalMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { content() }.padding(-4) }
}

struct BandalMenuDivider: View {
    var body: some View { BandalMenuDivider.line.frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6) }
    private static let line = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.11) : UIColor.black.withAlphaComponent(0.08) })
}

struct BandalRowStyle: ButtonStyle {
    var radius: CGFloat = 12
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? NativeGlass.selection : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
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
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BandalText(title).font(.system(size: BandalMetrics.headerSize, weight: .bold)).foregroundStyle(NativeDesktopTheme.muted)
            HStack(spacing: 6) {
                TextField(NativeAppLocale.string(prompt, locale), text: $value).font(.system(size: BandalMetrics.bodySize)).textFieldStyle(.plain)
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
/// `accessory` sits at the field's trailing edge (a filter chip).
struct BandalSearchList<Accessory: View, Content: View>: View {
    var prompt = "검색"
    @Binding var query: String
    var maxHeight: CGFloat = 360
    var identifier = "bandal-search"
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
                TextField(prompt, text: $query).font(.system(size: BandalMetrics.bodySize)).textFieldStyle(.plain)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).focused($focused).accessibilityIdentifier(identifier)
                accessory()
            }.padding(.horizontal, 8).frame(minHeight: 32)
                .background(NativeDesktopTheme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: BandalMetrics.radiusSmall))
            ScrollView { VStack(alignment: .leading, spacing: 0) { content() } }.frame(maxHeight: maxHeight).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focused = true }
    }
}

extension BandalSearchList where Accessory == EmptyView {
    init(prompt: String = "검색", query: Binding<String>, maxHeight: CGFloat = 360, identifier: String = "bandal-search", @ViewBuilder content: @escaping () -> Content) {
        self.init(prompt: prompt, query: query, maxHeight: maxHeight, identifier: identifier, accessory: { EmptyView() }, content: content)
    }
}

/// The keyboard's height while the window ignores it (a PDF text box is being typed in): views pinned to the
/// window's bottom (toasts, error banners) lift by it themselves.
@MainActor @Observable final class NativeKeyboardInset {
    static let shared = NativeKeyboardInset()
    var ignored = false
    private(set) var height: CGFloat = 0
    var lift: CGFloat { ignored ? height : 0 }
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated {
                let screen = UIScreen.main.bounds
                NativeKeyboardInset.shared.height = frame.isEmpty ? 0 : max(0, screen.maxY - frame.minY)
            }
        }
    }
}

struct BandalToast: View {
    @Binding var message: String?
    /// A status mark before the text (Figma: `checkmark.circle.fill` in green).
    var symbol: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        ZStack {
            if let message {
                HStack(spacing: 10) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Color(uiColor: .systemGreen)) }
                    BandalText(message).font(.system(size: 14, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
                        .multilineTextAlignment(.center).lineLimit(3)
                    if let actionTitle, let action {
                        NativeDesktopTheme.border.frame(width: 1, height: 16)
                        Button { self.message = nil; action() } label: { BandalText(actionTitle).font(.system(size: 14, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text).accessibilityIdentifier("bandal-toast-action")
                    }
                }
                    .padding(.horizontal, 16).frame(minHeight: 40)
                    .bandalGlass(in: Capsule())
                    .padding(.bottom, 24 + NativeKeyboardInset.shared.lift).padding(.horizontal, 16)
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

/// App text a component was handed as a `String` (a title, a menu row, a confirmation): shown in the app
/// language when the table has it. Unlike `Text("…")` it is never read as Markdown or as a format,
/// so a file or course name with `_`, `*` or `%` in it comes out as it is.
struct BandalText: View {
    private let text: String
    @Environment(\.locale) private var locale
    init(_ text: String) { self.text = text }
    var body: some View { Text(verbatim: NativeAppLocale.string(text, locale)) }
}

/// Esc from a hardware keyboard. A focused text field swallows `onKeyPress`, a cancel shortcut still fires.
struct BandalEscapeKey: View {
    let action: () -> Void
    var body: some View {
        Button("", action: action).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// Choices side by side in one track; the chosen one is raised. Used for settings, 생각 깊이 and the study board.
struct BandalSegmented: View {
    let options: [(value: String, title: String)]
    @Binding var selection: String
    var identifierPrefix = "bandal-segment-"
    /// An SF Symbol per option value, drawn before the title.
    var symbols: [String: String] = [:]
    /// The 34 pt size at the top of a sheet or popover; rows use the 28 pt default.
    var large = false
    /// The segments share the width they are given.
    var fills = false
    /// Read before each title ("상태 완료") where the bare word is another button's label.
    var spoken: String?
    /// The board header's track: black 6% on the sheet glass (dark: `Surface/Tool`).
    private static let largeTrack = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0x1f / 255, alpha: 1) : UIColor.black.withAlphaComponent(0.06) })
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = selection == option.value
                Button { selection = option.value } label: {
                    HStack(spacing: 6) {
                        if let symbol = symbols[option.value] { Image(systemName: symbol).font(.system(size: 13)) }
                        BandalText(option.title).lineLimit(1)
                    }
                        .font(.system(size: 14, weight: on ? .semibold : .regular)).padding(.horizontal, 14)
                        .frame(maxWidth: fills ? .infinity : nil).frame(height: large ? 34 : 29)
                        .foregroundStyle(on || !large ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
                        .background(on ? NativeDesktopTheme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: large ? 8 : 7))
                        .shadow(color: .black.opacity(on ? (large ? 0.08 : 0.1) : 0), radius: 1.5, y: 1).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(spoken.map { $0 + " " + option.title } ?? option.title)
                    .accessibilityIdentifier(identifierPrefix + option.value).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(large ? 3 : 2).background(large ? BandalSegmented.largeTrack : NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: large ? 11 : 9))
    }
}

/// One settings line: title (and a note under it) on the left, the control on the right.
struct BandalSettingRow<Control: View>: View {
    let title: String
    var note: String?
    var size: CGFloat = 16
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                BandalText(title).font(.system(size: size))
                if let note { BandalText(note).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }.frame(minHeight: 36)
    }
}

/// Preferences that live on this iPad only and are read where they apply.
enum NativeLocalPreferences {
    static let newDocumentKind = "native.newDocumentKind"
    static let homeTogglesSidebar = "native.homeTogglesSidebar"
    static let keyboardFoldsPanels = "native.keyboardFoldsPanels"
    static func bool(_ key: String, default value: Bool = true) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? value }
}

/// The design's switch, drawn rather than the system one: 51 × 31 in settings, 44 × 26 (`compact`) on the board.
struct BandalToggleStyle: ToggleStyle {
    var compact = false
    /// Set where the switch follows its label at a fixed distance instead of sitting at the row's far edge.
    var labelGap: CGFloat?
    /// The knob while off, where it is drawn differently from the knob while on (the board's is white in both appearances).
    var offKnob: Color?
    private static let off = NativeDesktopTheme.border
    private static let knob = NativeDesktopTheme.adaptive(0xffffff, 0x181818)
    func makeBody(configuration: Configuration) -> some View {
        let size = compact ? CGSize(width: 44, height: 26) : CGSize(width: 51, height: 31)
        return HStack(spacing: labelGap ?? 12) {
            configuration.label.accessibilityHidden(true)
            if labelGap == nil { Spacer(minLength: 8) }
            Capsule().fill(configuration.isOn ? NativeDesktopTheme.accent : Self.off)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? Self.knob : offKnob ?? Self.knob).padding(2).shadow(color: .black.opacity(0.15), radius: compact ? 1.5 : 2, y: compact ? 1 : 2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .accessibilityHidden(true)
                // The system's switch lies unseen over the drawing for VoiceOver and UI tests (a switch with
                // a label and a value); a touch goes to the drawing, which has 44 pt of height.
                .overlay {
                    Toggle(isOn: configuration.$isOn) { configuration.label }.labelsHidden().toggleStyle(.switch)
                        .frame(width: max(size.width, 51), height: 44).opacity(0.02).allowsHitTesting(false)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// Buttons as the design draws them. `.filled`: #1A1A1A, radius 12, 43 high (the main action of a card or popover).
/// `.outline`: paper with a hairline, radius 12, 45 high. `.soft`: #F7F7F7, radius 8, 31 high (inside settings rows).
struct BandalButtonStyle: ButtonStyle {
    enum Kind { case filled, outline, soft }
    var kind = Kind.filled
    /// Takes the width it is offered (stacked buttons in a popover).
    var fills = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = kind == .soft ? 8 : 12
        return configuration.label
            .font(.system(size: kind == .soft ? 14 : 15, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, kind == .soft ? 14 : 16)
            .frame(maxWidth: fills ? .infinity : nil).frame(height: kind == .soft ? 31 : kind == .outline ? 45 : 43)
            .foregroundStyle(kind == .filled ? NativeDesktopTheme.onAccent : NativeDesktopTheme.text)
            .background(kind == .filled ? NativeDesktopTheme.accent : kind == .outline ? NativeDesktopTheme.bgApp : NativeDesktopTheme.surface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { if kind == .outline { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(NativeDesktopTheme.border) } }
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
            .frame(minHeight: 44).contentShape(Rectangle())
    }
}

/// A search or text field as the design draws it: paper, hairline, radius 12, 45 high (50 with `large`),
/// a magnifier when `search`, and a clear button while there is text.
struct BandalField: View {
    let prompt: String
    @Binding var text: String
    var search = false
    var large = false
    var identifier = "bandal-field"
    var onSubmit: () -> Void = {}
    @Environment(\.locale) private var locale
    var body: some View {
        HStack(spacing: 8) {
            if search { Image(systemName: "magnifyingglass").font(.system(size: large ? 16 : 15)).foregroundStyle(NativeDesktopTheme.secondary) }
            TextField(NativeAppLocale.string(prompt, locale), text: $text).font(.system(size: large ? 16 : 15)).textFieldStyle(.plain)
                .autocorrectionDisabled(search).textInputAutocapitalization(search ? .never : .sentences)
                .onSubmit(onSubmit).accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: large ? 15 : 14)).frame(width: 28, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.muted).accessibilityLabel("지우기")
            }
        }
        .padding(.horizontal, large ? 16 : 14).frame(height: large ? 50 : 45)
        .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: large ? 14 : 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: large ? 14 : 12, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
    }
}

/// A card of choices (school, language, links): paper with a hairline, rows divided by an inset line.
struct BandalChoiceCard<Content: View>: View {
    var radius: CGFloat = 16
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
    }
}

/// The design's check mark: two strokes with round ends, 10.6 × 7.4 at weight 2.4 in a list row.
struct BandalCheck: View {
    var width: CGFloat = 10.6
    var weight: CGFloat = 2.4
    var body: some View {
        Path { path in path.move(to: CGPoint(x: 0, y: 0.524)); path.addLine(to: CGPoint(x: 1.0 / 3, y: 1)); path.addLine(to: CGPoint(x: 1, y: 0)) }
            .applying(CGAffineTransform(scaleX: width, y: width * 0.7))
            .stroke(style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round)).frame(width: width, height: width * 0.7)
    }
}

/// One row of a `BandalChoiceCard`: title over a detail, a check on the chosen one, 68 high (62 with `compact`).
struct BandalChoiceRow: View {
    let title: String
    var detail: String?
    var chosen = false
    var compact = false
    var showsDivider = true
    /// The chosen row lies on `surface` (a list of results); a list of settings shows the check alone.
    var tinted = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.system(size: compact ? 15 : 16, weight: .medium)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1).frame(minHeight: compact ? 21 : 22)
                    if let detail { Text(verbatim: detail).font(.system(size: compact ? 12 : 13)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1).frame(minHeight: compact ? 17 : 18) }
                }
                Spacer(minLength: 8)
                if chosen { BandalCheck(width: compact ? 9.4 : 10.6, weight: compact ? 2 : 2.4).foregroundStyle(NativeDesktopTheme.text).padding(.trailing, 3).accessibilityHidden(true) }
            }
            .padding(.horizontal, compact ? 14 : 16).frame(minHeight: compact ? 62 : 68)
            .background(chosen && tinted ? NativeDesktopTheme.surface : .clear).contentShape(Rectangle())
            .overlay(alignment: .bottom) { if showsDivider { NativeDesktopTheme.border.frame(height: 1).padding(.leading, compact ? 14 : 16) } }
        }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Presents `content` as a UIKit popover whose chrome is empty: no arrow, no background, no shadow of its own.
/// UIKit still places it beside the anchor, dismisses it on an outside tap and keeps it clear of the keyboard;
/// what shows is the card the content draws (`bandalPopoverSurface`). SwiftUI's `.popover` cannot drop the arrow.
private struct BandalPopoverPresenter<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let edge: Edge?
    var dims = true
    let environment: EnvironmentValues
    @ViewBuilder let content: () -> Content

    final class ClearBackground: UIPopoverBackgroundView {
        /// The gap between the anchor and the card.
        override static func arrowHeight() -> CGFloat { 6 }
        override static func arrowBase() -> CGFloat { 0 }
        override static func contentViewInsets() -> UIEdgeInsets { .zero }
        override static var wantsDefaultContentAppearance: Bool { false }
        private var direction = UIPopoverArrowDirection.any
        private var offset: CGFloat = 0
        override var arrowDirection: UIPopoverArrowDirection { get { direction } set { direction = newValue } }
        override var arrowOffset: CGFloat { get { offset } set { offset = newValue } }
        override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; layer.shadowOpacity = 0 }
        /// UIKit gives this view's layer the popover's shadow after it is made: solid black under the whole popover,
        /// which greys a translucent card and shows where the content leaves the popover clear.
        override func layoutSubviews() { super.layoutSubviews(); layer.shadowOpacity = 0 }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var host: UIHostingController<AnyView>?
        var close: () -> Void = {}
        var wanted = false
        var root = AnyView(EmptyView())
        var edge: Edge?
        var dims = true
        private var attempts = 0
        func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
        func presentationControllerDidDismiss(_ controller: UIPresentationController) { NativeInputTrace.record("popover.dismissed", "by the system (outside tap or adaptation)"); host = nil; close() }
        func sync(_ anchor: UIView) {
            guard wanted else {
                attempts = 0
                if let host { NativeInputTrace.record("popover.close", "binding went false"); self.host = nil; host.dismiss(animated: true) }
                return
            }
            if let host { host.rootView = root; return }
            // The anchor may not be in a window yet, or a menu may still be closing over the presenter: ask again shortly.
            guard anchor.window != nil, let presenter = BandalPopoverAnchor.controller(for: anchor), presenter.presentedViewController == nil else {
                if NativeInputTrace.isEnabled {
                    let controller = BandalPopoverAnchor.controller(for: anchor)
                    NativeInputTrace.record("popover.deferred", "attempt=\(attempts + 1) inWindow=\(anchor.window == nil ? 0 : 1) presenter=\(controller.map { String(describing: type(of: $0)).prefix(40) } ?? "nil") busyWith=\(controller?.presentedViewController.map { String(describing: type(of: $0)).prefix(48) + ($0.isBeingDismissed ? "[dismissing]" : "") } ?? "none")")
                }
                attempts += 1
                if attempts < 12 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak anchor] in if let self, let anchor, self.host == nil { self.sync(anchor) } } }
                return
            }
            attempts = 0
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            host.sizingOptions = .preferredContentSize
            host.modalPresentationStyle = .popover
            if let popover = host.popoverPresentationController {
                popover.sourceView = anchor; popover.sourceRect = anchor.bounds
                popover.permittedArrowDirections = switch edge { case .top: .up; case .bottom: .down; case .leading: .left; case .trailing: .right; case nil: .any }
                popover.popoverBackgroundViewClass = ClearBackground.self
                popover.delegate = self
            }
            self.host = host
            if NativeInputTrace.isEnabled {
                let frame = anchor.convert(anchor.bounds, to: nil)
                NativeInputTrace.record("popover.present", String(format: "anchor=(%.0f,%.0f %.0fx%.0f) presenter=%@", frame.minX, frame.minY, frame.width, frame.height, String(String(describing: type(of: presenter)).prefix(40))))
            }
            // The system rounds and clips a popover's content (about 26 pt); the card draws its own corners (14–34).
            // It also casts its own shadow, a dark rectangle the size of the whole popover, wider than the card: the card's shadow is the only one.
            presenter.present(host, animated: true) { [weak host] in
                var view = host?.view.superview
                while let current = view, !(current is UIWindow) {
                    current.layer.cornerRadius = 0; current.layer.masksToBounds = false; current.layer.shadowOpacity = 0
                    for sibling in current.subviews where String(describing: type(of: sibling)).contains("Shadow") { sibling.isHidden = true }
                    view = current.superview
                }
            }
            // UIKit's dimming view stays (it takes the outside tap); only its tint goes.
            if !dims { host.presentationController?.containerView?.subviews.first { String(describing: type(of: $0)).contains("Dimming") }?.alpha = 0.011 }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.isUserInteractionEnabled = false; view.isAccessibilityElement = false; return view }
    func updateUIView(_ anchor: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.close = { isPresented = false }
        coordinator.wanted = isPresented; coordinator.edge = edge; coordinator.dims = dims
        coordinator.root = AnyView(content().environment(\.self, environment))
        coordinator.sync(anchor)
    }
    /// The anchor leaves (its toolbar re-laid out, the palette changing shape or moving between window and pane):
    /// the popover goes with it, and the binding is left alone, so the anchor that replaces it opens the popover
    /// again. Clearing the binding here closed the pen settings whenever a choice inside them re-laid the palette.
    static func dismantleUIView(_ anchor: UIView, coordinator: Coordinator) {
        coordinator.host?.dismiss(animated: false); coordinator.host = nil
    }
}

enum BandalPopoverAnchor {
    static func controller(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next { if let controller = next as? UIViewController { return controller }; responder = next }
        return view.window?.rootViewController
    }
}

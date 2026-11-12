import SwiftUI

enum NativePaper: String, CaseIterable, Identifiable {
    case blank, lines, grid, dots
    var id: String { rawValue }
    var title: String {
        switch self { case .blank: return "빈 종이"; case .lines: return "줄"; case .grid: return "모눈"; case .dots: return "점" }
    }
}

/// What the 새 노트 sheet was answered with.
struct NativeNewNoteOptions: Equatable {
    var title: String
    var paper: NativePaper = .lines
    var landscape = false
    var orientation: String { landscape ? "landscape" : "portrait" }
    /// The name a note takes when none is typed: "노트 2026-11-12", as on the desktop.
    static func defaultTitle(_ date: Date = Date(), locale: Locale = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return NativeAppLocale.string("노트", locale) + " " + formatter.string(from: date)
    }
}

/// 새 노트, as the desktop app asks it: 제목, 종이 (빈 종이 · 줄 · 모눈 · 점), 방향 (세로 · 가로), 취소 · 만들기.
/// Shown before every new handwriting note: over the window from ＋ › 노트 and the home screen, and under the
/// library's ＋. `create` makes the note; what it throws stays in the sheet.
struct NativeNewNoteSheet: View {
    let cancel: () -> Void
    let create: @MainActor (NativeNewNoteOptions) async throws -> Void
    @Environment(\.locale) private var locale
    @State private var title = ""
    @State private var paper: NativePaper = .lines
    @State private var landscape = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BandalText("새 노트").font(.system(size: 22, weight: .bold)).foregroundStyle(NativeDesktopTheme.text).accessibilityAddTraits(.isHeader)
            label("제목").padding(.top, 14)
            TextField("", text: $title, prompt: Text(verbatim: NativeNewNoteOptions.defaultTitle(locale: locale)).foregroundStyle(NativeDesktopTheme.muted))
                .font(.system(size: 17)).textFieldStyle(.plain).focused($focused).submitLabel(.done).onSubmit(submit)
                .padding(.horizontal, 14).frame(height: 46)
                .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? AnyShapeStyle(NativeGlass.accent) : AnyShapeStyle(NativeDesktopTheme.border), lineWidth: focused ? 2 : 1) }
                .accessibilityLabel("제목").accessibilityIdentifier("native-new-note-title")
            label("종이").padding(.top, 16)
            // Each answer as wide as its name, wrapping to a second row when the sheet is narrow.
            NativeWindowCardFlow(spacing: 8) {
                ForEach(NativePaper.allCases) { option in
                    choice(NativeAppLocale.string(option.title, locale), chosen: paper == option, identifier: "native-new-note-paper-" + option.rawValue) { paper = option } mark: {
                        NativePaperPreview(paper: option).frame(width: 26, height: 34)
                    }
                }
            }
            label("방향").padding(.top, 16)
            HStack(spacing: 8) {
                choice(NativeAppLocale.string("세로", locale), chosen: !landscape, identifier: "native-new-note-portrait") { landscape = false } mark: { EmptyView() }
                choice(NativeAppLocale.string("가로", locale), chosen: landscape, identifier: "native-new-note-landscape") { landscape = true } mark: { EmptyView() }
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 12).accessibilityIdentifier("native-creation-error") }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(action: cancel) {
                    BandalText("취소").font(.system(size: 15, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
                        .padding(.horizontal, 18).frame(height: 44).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("native-new-note-cancel")
                Button(action: submit) {
                    Group { if busy { ProgressView().tint(NativeDesktopTheme.onAccent) } else { BandalText("만들기").font(.system(size: 15, weight: .semibold)) } }
                        .foregroundStyle(NativeDesktopTheme.onAccent).padding(.horizontal, 20).frame(minWidth: 76).frame(height: 44)
                        .background(NativeDesktopTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("native-new-note-create")
            }.buttonStyle(.plain).padding(.top, 20)
        }
        // The title is optional, so the sheet does not raise the keyboard by itself: Return and Esc answer it
        // from a hardware keyboard either way.
        .disabled(busy)
    }
    private func label(_ text: String) -> some View {
        BandalText(text).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).padding(.bottom, 8)
    }
    /// One answer: a radio mark, an optional picture and its name. The chosen one is shaded and ringed.
    private func choice<Mark: View>(_ name: String, chosen: Bool, identifier: String, pick: @escaping () -> Void, @ViewBuilder mark: () -> Mark) -> some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Circle().strokeBorder(chosen ? NativeDesktopTheme.text : NativeDesktopTheme.muted, lineWidth: 1.5).frame(width: 20, height: 20)
                    .overlay { if chosen { Circle().fill(NativeDesktopTheme.text).frame(width: 10, height: 10) } }
                mark()
                Text(verbatim: name).font(.system(size: 15, weight: chosen ? .medium : .regular)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1)
            }.padding(.leading, 10).padding(.trailing, 14).frame(height: 46).contentShape(Rectangle())
                .background(chosen ? NativeDesktopTheme.raised : NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(chosen ? NativeDesktopTheme.text : NativeDesktopTheme.border, lineWidth: chosen ? 1.5 : 1) }
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(chosen ? .isSelected : []).accessibilityIdentifier(identifier)
    }

    private func submit() {
        guard !busy else { return }
        busy = true; error = nil
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = NativeNewNoteOptions(title: name.isEmpty ? NativeNewNoteOptions.defaultTitle(locale: locale) : name, paper: paper, landscape: landscape)
        Task { @MainActor in
            do { try await create(options) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// A sheet of the paper, small: white with its ruling.
private struct NativePaperPreview: View {
    let paper: NativePaper
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step = size.width / 4.4
            if paper == .dots {
                for x in stride(from: step * 0.7, to: size.width - 1, by: step) {
                    for y in stride(from: step * 0.7, to: size.height - 1, by: step) { path.addEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)) }
                }
                context.fill(path, with: .color(.black.opacity(0.45)))
            } else if paper != .blank {
                for y in stride(from: step, to: size.height - 1, by: step) { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
                if paper == .grid {
                    for x in stride(from: step, to: size.width - 1, by: step) { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
                }
                context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 0.7)
            }
        }
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.22), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// A sheet owns its asynchronous operation until completion; an older request
/// cannot dismiss a newly presented sheet or lose a validation error.
struct NativeNameSheet: View {
    let title: String
    let prompt: String
    let actionTitle: String
    let defaultValue: String?
    let action: @MainActor (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(title: String, prompt: String, initialValue: String = "", actionTitle: String = "만들기", defaultValue: String? = nil, action: @escaping @MainActor (String) async throws -> Void) {
        self.title = title; self.prompt = prompt; self.actionTitle = actionTitle; self.action = action
        self.defaultValue = defaultValue
        _name = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(prompt, text: $name).focused($focused).submitLabel(.done)
                    .onSubmit(submit).disabled(busy).accessibilityIdentifier("native-name-input")
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if busy { ProgressView() } else { Text(actionTitle).fontWeight(.semibold) }
                    }.disabled(busy || (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && defaultValue == nil))
                }
            }
            .interactiveDismissDisabled(busy)
            .task { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = typed.isEmpty ? defaultValue ?? "" : typed
        guard !busy, !value.isEmpty else { return }
        busy = true; error = nil
        Task { @MainActor in
            do { try await action(value); dismiss() }
            catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

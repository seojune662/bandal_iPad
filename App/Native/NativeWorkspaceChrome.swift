import SwiftUI

enum NativeHomeSection: String, CaseIterable, Identifiable {
    case courses, projects
    var id: String { rawValue }
    var title: String { self == .courses ? "과목" : "프로젝트" }
}

/// Uses the scene's available width, never the physical screen, so Stage Manager
/// and Split View have the same behavior as rotation on a full-screen iPad.
/// Columns, left to right: navigation, courses, AI chat, editor, materials.
struct NativeWorkspaceChromeLayout: Equatable {
    let width: Double
    let leftPinned: Bool
    let aiPinned: Bool
    let rightPinned: Bool
    let leftWidth: Double
    let aiWidth: Double
    let rightWidth: Double
    let compactRightWidth: Double
    let compactAIWidth: Double
    static let editorMinimum: Double = 440
    static let leftMinimum: Double = 200
    static let aiMinimum: Double = 300
    static let rightMinimum: Double = 320
    /// True when rails of these widths (one separator each) still leave the editor its minimum.
    static func fits(_ widths: [Double], in width: Double) -> Bool {
        width - 48 - Double(widths.count) - widths.reduce(0, +) >= editorMinimum
    }
    /// Below these widths a rail cannot sit beside the editor, so it falls back to a drawer.
    static func fitsLeft(_ width: Double) -> Bool { fits([leftMinimum], in: width) }
    static func fitsAI(_ width: Double) -> Bool { fits([aiMinimum], in: width) }
    static func fitsRight(_ width: Double) -> Bool { fits([rightMinimum], in: width) }

    init(width: Double, leftOpen: Bool, rightOpen: Bool, aiOpen: Bool = false, leftRequested: Double = 240,
         rightRequested: Double = 360, aiRequested: Double = 340, showsWorkspace: Bool = true) {
        let w = max(0, width.isFinite ? width : 0)
        self.width = w
        // The view closes rails that no longer fit when one opens; this order only
        // settles restored state where everything was left open.
        var mins: [Double] = []
        aiPinned = showsWorkspace && aiOpen && Self.fits(mins + [Self.aiMinimum], in: w)
        if aiPinned { mins.append(Self.aiMinimum) }
        rightPinned = showsWorkspace && rightOpen && Self.fits(mins + [Self.rightMinimum], in: w)
        if rightPinned { mins.append(Self.rightMinimum) }
        leftPinned = showsWorkspace && leftOpen && Self.fits(mins + [Self.leftMinimum], in: w)
        if leftPinned { mins.append(Self.leftMinimum) }
        var extra = max(0, w - 48 - Self.editorMinimum - Double(mins.count) - mins.reduce(0, +))
        func grow(_ pinned: Bool, _ requested: Double, _ minimum: Double, _ maximum: Double) -> Double {
            guard pinned else { return 0 }
            let target = min(maximum, max(minimum, requested.isFinite ? requested : minimum))
            let value = min(target, minimum + extra); extra -= value - minimum; return value
        }
        leftWidth = grow(leftPinned, leftRequested, Self.leftMinimum, 360)
        aiWidth = grow(aiPinned, aiRequested, Self.aiMinimum, 520)
        rightWidth = grow(rightPinned, rightRequested, Self.rightMinimum, 520)
        compactRightWidth = w < 600 ? w : min(360, max(0, w - 48))
        compactAIWidth = w < 600 ? max(0, w - 48) : min(380, max(0, w - 48))
    }
}


struct NativeHomeSectionPicker: View {
    @Binding var selection: NativeHomeSection
    var body: some View {
        HStack(spacing: 18) {
            ForEach(NativeHomeSection.allCases) { section in
                Button { selection = section } label: {
                    Text(section.title).font(NativeDesktopTheme.font(13, weight: selection == section ? .semibold : .regular))
                        .foregroundStyle(selection == section ? NativeGlass.icon : NativeGlass.panelTertiary)
                        .frame(height: 39)
                        .overlay(alignment: .bottom) {
                            if selection == section { RoundedRectangle(cornerRadius: 1).fill(NativeGlass.icon).frame(height: 2).padding(.horizontal, -1) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("native-home-" + section.rawValue)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.bottom, 1)
            .overlay(alignment: .bottom) { NativeGlass.hairline.frame(height: 1) }
            .padding(.bottom, 11)
    }
}

/// Search field shared by the course and project rails and the files panel.
struct NativeRailSearchField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String
    /// Esc empties the field while it has focus.
    var escapeClears = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(NativeGlass.fieldGlyph).frame(width: 16)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(NativeGlass.fieldPrompt)).textFieldStyle(.plain).foregroundStyle(NativeDesktopTheme.text).accessibilityIdentifier(identifier)
                .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never)
                // Either route may deliver Esc while the field has focus: the key press, or the cancel shortcut.
                .onKeyPress(.escape) { guard escapeClears, !text.isEmpty else { return .ignored }; text = ""; return .handled }
                .background { if escapeClears, focused, !text.isEmpty { BandalEscapeKey { text = "" } } }
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(NativeGlass.fieldGlyph) }.buttonStyle(.plain).accessibilityLabel("검색어 지우기") }
        }.font(NativeDesktopTheme.font(12))
            .padding(.leading, 9).padding(.trailing, 8).frame(height: 34)
            .background(NativeGlass.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NativeGlass.fieldStroke) }
    }
}

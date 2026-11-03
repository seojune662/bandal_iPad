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

/// The small tab on the trailing edge of the left columns that shows or hides AI chat.
struct NativeAIRailHandle: View {
    let open: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: open ? "chevron.left" : "sparkles")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                .frame(width: 16, height: 56)
                .background(NativeDesktopTheme.surface, in: UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8))
                .overlay { UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8).stroke(NativeDesktopTheme.border) }
                .frame(width: 44, height: 72, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(open ? "AI 닫기" : "AI 열기")
            .accessibilityIdentifier("native-ai-rail-toggle")
    }
}

struct NativeHomeSectionPicker: View {
    @Binding var selection: NativeHomeSection
    var body: some View {
        HStack(spacing: 20) {
            ForEach(NativeHomeSection.allCases) { section in
                Button { selection = section } label: {
                    Text(section.title).font(NativeDesktopTheme.font(14, weight: selection == section ? .semibold : .regular))
                        .foregroundStyle(selection == section ? NativeDesktopTheme.text : NativeDesktopTheme.muted)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if selection == section { Capsule().fill(NativeDesktopTheme.text).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("native-home-" + section.rawValue)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
            .padding(.bottom, 10)
    }
}

/// Search field shared by the course and project rails.
struct NativeRailSearchField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
            TextField(prompt, text: $text).textFieldStyle(.plain).foregroundStyle(NativeDesktopTheme.text).accessibilityIdentifier(identifier)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("검색어 지우기") }
        }.font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.muted)
            .padding(.horizontal, 10).frame(minHeight: 36)
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(NativeDesktopTheme.border) }
    }
}

struct NativeInspectorHeader: View {
    var body: some View {
        HStack {
            Text("자료").font(NativeDesktopTheme.font(14, weight: .semibold))
                .accessibilityAddTraits(.isButton).accessibilityIdentifier("native-inspector-materials")
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).frame(height: 44)
            .background(NativeDesktopTheme.surface)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
    }
}

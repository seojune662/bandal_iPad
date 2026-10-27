import SwiftUI

enum NativeHomeSection: String, CaseIterable, Identifiable {
    case courses, projects
    var id: String { rawValue }
    var title: String { self == .courses ? "과목" : "프로젝트" }
}

enum NativeInspectorTab: String, CaseIterable, Identifiable {
    case materials, assistant
    var id: String { rawValue }
    var title: String { self == .materials ? "자료" : "AI" }
    var symbol: String { self == .materials ? "doc.on.doc" : "sparkles" }
}

/// Uses the scene's available width, never the physical screen, so Stage Manager
/// and Split View have the same behavior as rotation on a full-screen iPad.
struct NativeWorkspaceChromeLayout: Equatable {
    let width: Double
    let leftPinned: Bool
    let rightPinned: Bool
    let leftWidth: Double
    let rightWidth: Double
    let compactRightWidth: Double

    init(width: Double, leftOpen: Bool, rightOpen: Bool, leftRequested: Double = 240,
         rightRequested: Double = 360, showsWorkspace: Bool = true) {
        self.width = max(0, width.isFinite ? width : 0)
        leftPinned = showsWorkspace && leftOpen && self.width >= 1200
        rightPinned = showsWorkspace && rightOpen && self.width >= 900
        let left = min(360, max(200, leftRequested.isFinite ? leftRequested : 240))
        let right = min(520, max(320, rightRequested.isFinite ? rightRequested : 360))
        let budget = max(0, self.width - 48 - 480 - (leftPinned ? 1 : 0) - (rightPinned ? 1 : 0))
        leftWidth = leftPinned ? min(left, max(200, budget - (rightPinned ? 320 : 0))) : 0
        rightWidth = rightPinned ? min(right, max(320, budget - leftWidth)) : 0
        compactRightWidth = self.width < 600 ? self.width : min(360, max(0, self.width - 48))
    }
}

struct NativeHomeSectionPicker: View {
    @Binding var selection: NativeHomeSection
    var body: some View {
        HStack(spacing: 4) {
            ForEach(NativeHomeSection.allCases) { section in
                Button { selection = section } label: {
                    Text(section.title).font(NativeDesktopTheme.font(14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selection == section ? NativeDesktopTheme.text : NativeDesktopTheme.muted)
                        .background(selection == section ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("native-home-" + section.rawValue)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    }
}

struct NativeInspectorHeader: View {
    @Binding var selection: NativeInspectorTab
    var body: some View {
        HStack(spacing: 4) {
            ForEach(NativeInspectorTab.allCases) { tab in
                Button { selection = tab } label: {
                    Image(systemName: tab.symbol).font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(selection == tab ? NativeDesktopTheme.text : NativeDesktopTheme.muted)
                        .overlay(alignment: .bottom) {
                            if selection == tab { Capsule().fill(NativeDesktopTheme.text).frame(width: 22, height: 2) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(tab.title)
                    .accessibilityIdentifier("native-inspector-" + tab.rawValue)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.leading, 8).padding(.trailing, 4)
            .background(NativeDesktopTheme.surface)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
    }
}

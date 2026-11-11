import SwiftUI

/// The long-press menu of a note or file (Figma 129:3094, "iOS 기본 컨텍스트 메뉴 그대로"): the system's own
/// context menu, which dims the screen, lifts the pressed card and draws the glass card. On top the three
/// tiles 이름 변경 · 공유 · 삭제, then the design's rows, then `extra` for what the design does not show.
struct NativeMaterialMenu<Extra: View>: View {
    let rename: () -> Void
    /// Nil for a folder, which has nothing to share.
    let share: (() -> Void)?
    let delete: () -> Void
    @Binding var sort: String
    @ViewBuilder var extra: () -> Extra
    @Environment(\.locale) private var locale
    var body: some View {
        ControlGroup {
            Button(action: rename) { Label { BandalText("이름 변경") } icon: { Image(systemName: "pencil") } }
            Button { share?() } label: { Label { BandalText("공유") } icon: { Image(systemName: "square.and.arrow.up") } }.disabled(share == nil)
            Button(role: .destructive, action: delete) { Label { BandalText("삭제") } icon: { Image(systemName: "trash") } }
        }
        // A note belongs to one course: moving it to another, keeping it outside one and offline copies
        // need storage and sync that do not exist yet.
        NativeMenuPending(title: "과목으로 이동", symbol: "folder")
        NativeMenuPending(title: "오프라인 저장", symbol: "icloud")
        NativeMenuPending(title: "과목에서 빼기", symbol: "folder.badge.minus", destructive: true)
        Divider()
        Picker(NativeAppLocale.string("정렬 기준", locale), selection: $sort) {
            BandalText("이름순").tag(NativeLibraryPresentation.Sort.name.rawValue)
            BandalText("최근 수정순").tag(NativeLibraryPresentation.Sort.recent.rawValue)
        }.pickerStyle(.menu)
        extra()
    }
}

/// A row the design draws for a feature that is not built: shown, disabled, marked "준비 중".
struct NativeMenuPending: View {
    let title: String
    let symbol: String
    var destructive = false
    @Environment(\.locale) private var locale
    var body: some View {
        Button(role: destructive ? .destructive : nil) {} label: {
            Label(NativeAppLocale.string(title, locale) + " · " + NativeAppLocale.string("준비 중", locale), systemImage: symbol)
        }.disabled(true)
    }
}

/// One entry of the app's own long-press menu: a tile, a row, or a row that opens `children` in place.
struct NativeLongPressItem: Identifiable {
    enum Kind { case normal, destructive, pending }
    let title: String
    var symbol: String?
    var kind = Kind.normal
    var checked = false
    var children: [NativeLongPressItem] = []
    var action: () -> Void = {}
    var id: String { title }

    /// The rows the design gives a note: the three that wait for storage outside one course, then 정렬 기준.
    static func materialGroups(sort: Binding<String>) -> [[NativeLongPressItem]] {
        func choice(_ title: String, _ value: NativeLibraryPresentation.Sort) -> NativeLongPressItem {
            .init(title: title, checked: sort.wrappedValue == value.rawValue) { sort.wrappedValue = value.rawValue }
        }
        return [[.init(title: "과목으로 이동", symbol: "folder", kind: .pending), .init(title: "오프라인 저장", symbol: "icloud", kind: .pending),
                 .init(title: "과목에서 빼기", symbol: "folder.badge.minus", kind: .pending)],
                [.init(title: "정렬 기준", children: [choice("이름순", .name), choice("최근 수정순", .recent)])]]
    }
}

/// The long-press menu drawn to Figma 129:3094's numbers (the system's own is a size smaller on iPad): glass
/// r34, 250 wide, a row of tiles 57 high r20, then rows 40 high at 17 pt between inset separators.
struct NativeLongPressCard: View {
    let tiles: [NativeLongPressItem]
    let groups: [[NativeLongPressItem]]
    let close: () -> Void
    @State private var parent: NativeLongPressItem?
    @Environment(\.locale) private var locale
    private static let ink = NativeDesktopTheme.adaptive(0x1a1a1a, 0xf5f5f5)
    private static let red = NativeDesktopTheme.adaptive(0xff383c, 0xff4245)
    private static let faint = NativeDesktopTheme.adaptive(0xbfbfbf, 0x404040)
    private static let line = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.11) : UIColor(white: 0xe6 / 255, alpha: 1) })

    var body: some View {
        VStack(spacing: 0) {
            if let parent {
                row(.init(title: parent.title, symbol: "chevron.left") { self.parent = nil })
                separator
                ForEach(parent.children) { row($0) }
            } else {
                HStack(spacing: 6) { ForEach(Array(tiles.enumerated()), id: \.element.id) { index, item in tile(item, filled: index == 0) } }.padding(.horizontal, 10)
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    separator
                    ForEach(group) { row($0) }
                }
            }
        }.padding(.vertical, 10).frame(width: 250).bandalPopoverSurface(radius: 34)
    }
    private func color(_ item: NativeLongPressItem) -> Color { item.kind == .pending ? Self.faint : item.kind == .destructive ? Self.red : Self.ink }
    private func title(_ item: NativeLongPressItem) -> String {
        NativeAppLocale.string(item.title, locale) + (item.kind == .pending ? " · " + NativeAppLocale.string("준비 중", locale) : "")
    }
    private func tile(_ item: NativeLongPressItem, filled: Bool) -> some View {
        Button { close(); item.action() } label: {
            VStack(spacing: 5) {
                Image(systemName: item.symbol ?? "circle").font(.system(size: 17)).frame(height: 22)
                Text(verbatim: title(item)).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(height: 18)
            }.foregroundStyle(color(item)).frame(maxWidth: .infinity).frame(height: 57).contentShape(Rectangle())
                .background(filled ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }.buttonStyle(BandalRowStyle(radius: 20))
    }
    private func row(_ item: NativeLongPressItem) -> some View {
        Button {
            if item.children.isEmpty { close(); item.action() } else { parent = item }
        } label: {
            HStack(spacing: 8) {
                if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 17)).frame(width: 28, height: 20) }
                Text(verbatim: title(item)).font(.system(size: 17)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if !item.children.isEmpty { Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)) }
                if item.checked { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)) }
            }.foregroundStyle(color(item)).padding(.leading, 6).padding(.trailing, 8).frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(BandalRowStyle(radius: 12)).disabled(item.kind == .pending).padding(.horizontal, 16)
            .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
    private var separator: some View { Self.line.frame(height: 1).padding(.horizontal, 24).padding(.vertical, 10) }
}

/// What the window dims around while a long-press menu is open: the pressed card stays clear of it.
@Observable final class NativeLongPressDim {
    static let shared = NativeLongPressDim()
    var hole: CGRect?
    var radius: CGFloat = 16
}

/// Black 18% (dark 45%) over the whole window with the pressed card cut out. One of these sits over the workspace.
struct NativeLongPressDimLayer: View {
    private var dim = NativeLongPressDim.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { proxy in
            if let hole = dim.hole {
                let origin = proxy.frame(in: .global).origin
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRoundedRect(in: hole.offsetBy(dx: -origin.x, dy: -origin.y), cornerSize: CGSize(width: dim.radius, height: dim.radius), style: .continuous)
                }.fill(Color.black.opacity(scheme == .dark ? 0.45 : 0.18), style: FillStyle(eoFill: true)).transition(.opacity)
            }
        }.ignoresSafeArea().allowsHitTesting(false).animation(.easeOut(duration: 0.15), value: dim.hole)
    }
}

extension View {
    /// The app's own long-press menu for this view: dims the window around it and opens the card 16 under it
    /// (Figma 129:3094). The caller opens it (a long press) and draws its own lifted look from `isPresented`.
    func nativeLongPressMenu(isPresented: Binding<Bool>, radius: CGFloat, tiles: [NativeLongPressItem], groups: [[NativeLongPressItem]]) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.onChange(of: isPresented.wrappedValue) { _, shown in
                    NativeLongPressDim.shared.radius = radius
                    NativeLongPressDim.shared.hole = shown ? proxy.frame(in: .global) : nil
                }
            }
        }
        .bandalPopover(isPresented: isPresented, at: .bottom, offset: CGSize(width: 6, height: 10), width: nil, padding: 0, bare: true) {
            NativeLongPressCard(tiles: tiles, groups: groups) { isPresented.wrappedValue = false }
        }
    }
}

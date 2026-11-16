import SwiftUI
import UIKit

/// The cards that show once, and their order: 반달 잘 쓰는 법 after first-run setup, for someone new; the
/// new-feature card after an update, for someone who already used the app. Neither shows over anything else.
/// Nothing here is counted or sent anywhere: what was seen lives on this iPad only.
enum NativeGuideGate {
    enum Card: Equatable { case tour, intro }
    static let tourSeenKey = "native.guide.tour.seen"
    /// The new-feature card's key carries the feature and its version: a later feature gets a key of its own.
    static let introSeenKey = "native.guide.intro.tabGesture.v1"
    static let tourArgument = "--native-guide-tour"
    static let introArgument = "--native-guide-intro"

    /// What is due on this launch. Tests see neither unless they ask for one.
    static func due(onboardedThisLaunch: Bool, arguments: [String] = ProcessInfo.processInfo.arguments,
                    hostedTest: Bool = NSClassFromString("XCTestCase") != nil, defaults: UserDefaults = .standard) -> Card? {
        if arguments.contains("--native-ui-testing") || hostedTest {
            if arguments.contains(tourArgument) && !defaults.bool(forKey: tourSeenKey) { return .tour }
            if arguments.contains(introArgument) && !defaults.bool(forKey: introSeenKey) { return .intro }
            return nil
        }
        // Someone new meets the gesture inside the tour, which has a page for it.
        if onboardedThisLaunch { return defaults.bool(forKey: tourSeenKey) ? nil : .tour }
        return defaults.bool(forKey: introSeenKey) ? nil : .intro
    }

    /// Seen once, never again. The tour also counts as having seen the new-feature card.
    static func markSeen(_ card: Card, defaults: UserDefaults = .standard) {
        if card == .tour { defaults.set(true, forKey: tourSeenKey) }
        defaults.set(true, forKey: introSeenKey)
    }

    /// The workspace is quiet: first-run setup is over, the panes are on screen and nothing (a sheet, a popover,
    /// the paywall, a consent sheet, settings, the windows overview) lies over them.
    static func idle(restored: Bool, onboardingClosed: Bool, workspaceShown: Bool, overlay: Bool, presented: Bool) -> Bool {
        restored && onboardingClosed && workspaceShown && !overlay && !presented
    }

    /// A view controller is shown over the window (sheet, popover, the paywall, the AI consent sheet).
    @MainActor static var somethingPresented: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }

    /// 도움말 › 반달 잘 쓰는 법 and 설정 open the tour again.
    static let openTour = Notification.Name("native.guide.openTour")
}

/// The first-use tips: a line the first time a PDF opens, the lasso is picked and the AI panel opens.
/// "팁 그만 보기" turns them all off; 설정 › 일반 › 더 보기 turns them back on.
enum NativeFirstUseTip: String, CaseIterable, Identifiable {
    case pdf, lasso, ai
    var id: String { rawValue }
    static let offKey = "native.guide.tips.off"
    static let argument = "--native-guide-tips"
    var seenKey: String { "native.guide.tip." + rawValue }
    var symbol: String { switch self { case .pdf: "pencil.tip"; case .lasso: "lasso"; case .ai: "sparkles" } }
    var text: String {
        switch self {
        case .pdf: "펜슬로 쓰고, 손가락으로 넘기고, 두 손가락으로 확대해요"
        case .lasso: "글자를 올가미로 둘러싸면 찾아보기가 뜻을 보여 줘요"
        case .ai: "이 폴더의 자료를 읽고 답해요. 답은 노트에 넣기로 옮길 수 있어요"
        }
    }
    /// Whether this tip may show: tips are on, it has not been seen, and this is not a test that left them out.
    func isDue(arguments: [String] = ProcessInfo.processInfo.arguments, hostedTest: Bool = NSClassFromString("XCTestCase") != nil,
               defaults: UserDefaults = .standard) -> Bool {
        if (arguments.contains("--native-ui-testing") || hostedTest) && !arguments.contains(Self.argument) { return false }
        return !defaults.bool(forKey: Self.offKey) && !defaults.bool(forKey: seenKey)
    }
    func markSeen(defaults: UserDefaults = .standard) { defaults.set(true, forKey: seenKey) }
    static func stopAll(defaults: UserDefaults = .standard) { defaults.set(true, forKey: offKey) }
    /// 설정's switch: on again shows each tip once more.
    static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(!on, forKey: offKey)
        if on { allCases.forEach { defaults.removeObject(forKey: $0.seenKey) } }
    }
}

// MARK: - Cards

/// Over the workspace: the window dimmed and one card in the middle, as the 새 노트 sheet.
struct NativeGuideBackdrop<Content: View>: View {
    let width: CGFloat
    let identifier: String
    let dismiss: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: dismiss).accessibilityHidden(true)
            content()
                .padding(24).frame(width: width)
                .background(NativeGlass.sheet, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(NativeGlass.rim) }
                .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
                .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier(identifier)
                .onAppear { UIAccessibility.post(notification: .screenChanged, argument: nil) }
            BandalEscapeKey(action: dismiss)
        }
        .foregroundStyle(NativeDesktopTheme.text)
        .transition(.opacity)
    }
}

/// Three fingertips drawing together and apart. It plays a few times and rests; with 동작 줄이기 (or in a UI test,
/// which waits for the screen to settle) it is a still picture of the two movements.
struct NativeThreeFingerAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var together = false
    private static let still = ProcessInfo.processInfo.arguments.contains("--native-ui-testing")
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NativeDesktopTheme.surface)
            if reduceMotion || Self.still {
                HStack(spacing: 36) {
                    NativeThreeFingerDots(radius: 30, arrows: .inward)
                    NativeThreeFingerDots(radius: 30, arrows: .outward)
                }
            } else {
                NativeThreeFingerDots(radius: together ? 12 : 36, arrows: nil)
            }
        }
        .frame(height: 124)
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion, !Self.still else { return }
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(.easeInOut(duration: 0.6)) { together = true }
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.easeInOut(duration: 0.6)) { together = false }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }
}

struct NativeThreeFingerDots: View {
    enum Arrows { case inward, outward }
    let radius: CGFloat
    var arrows: Arrows?
    var dot: CGFloat = 18
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / 3
                Circle().fill(NativeGlass.accent).frame(width: dot, height: dot)
                    .offset(x: radius * cos(angle), y: radius * sin(angle))
                if let arrows {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(NativeDesktopTheme.secondary)
                        .rotationEffect(.radians(Double(angle + .pi / 2 + (arrows == .inward ? .pi : 0))))
                        .offset(x: (radius + 17) * cos(angle), y: (radius + 17) * sin(angle))
                }
            }
        }.frame(width: (radius + 28) * 2, height: (radius + 28) * 2)
    }
}

/// One line of a card: a small picture, a line and a quieter line under it.
private struct NativeGuideLine<Picture: View>: View {
    let title: String
    var note: String?
    var weight = Font.Weight.semibold
    @ViewBuilder var picture: () -> Picture
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            picture().frame(width: 36, height: 36)
                .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                BandalText(title).font(.system(size: 16, weight: weight)).fixedSize(horizontal: false, vertical: true)
                if let note { BandalText(note).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 새 기능 · 손가락 3개로 탭 열고 닫기, once after the update that brings it.
struct NativeTabGestureIntro: View {
    let openSettings: () -> Void
    let close: () -> Void
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                BandalText("새 기능").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                BandalText("손가락 3개로 탭 열고 닫기").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            }
            NativeThreeFingerAnimation()
            VStack(alignment: .leading, spacing: 14) {
                NativeGuideLine(title: "세 손가락을 모으면 탭이 닫혀요", note: "잘못 닫았으면 아래에 뜨는 되돌리기를 누르세요") {
                    NativeThreeFingerDots(radius: 7, dot: 6)
                }
                NativeGuideLine(title: "모았다가 펴면 새 탭을 열어요", note: "어떤 탭을 열지 고르는 메뉴가 떠요") {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(NativeGlass.accent)
                }
                if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning {
                    BandalText("VoiceOver나 스위치 제어를 쓰는 동안에는 이 동작이 꺼져 있어요.").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                }
            }
            HStack(spacing: 12) {
                Button(action: openSettings) {
                    BandalText("설정에서 열 탭 고르기").font(.system(size: 15, weight: .medium)).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(NativeGlass.accent).accessibilityIdentifier("native-tab-gesture-intro-settings")
                Spacer(minLength: 8)
                Button(action: close) { BandalText("확인").frame(minWidth: 96) }
                    .buttonStyle(BandalButtonStyle(kind: .filled)).accessibilityIdentifier("native-tab-gesture-intro-ok")
            }
        }
    }
}

/// 반달 잘 쓰는 법: a few pages of the way a study session runs, with the names the screens use.
struct NativeUsageTour: View {
    let close: () -> Void
    struct Page: Identifiable {
        let id: String
        let symbols: [String]
        let title: String
        let lines: [(symbol: String, text: String)]
    }
    static var pages: [Page] {
        var pages: [Page] = [
            .init(id: "pdf", symbols: ["doc.richtext", "pencil.tip"], title: "강의 PDF에 바로 필기해요", lines: [
                ("folder", "오른쪽 자료 목록에서 PDF를 열어요"),
                ("pencil.tip", "Apple Pencil로 쓰고, 손가락으로 넘겨요"),
                ("arrow.up.left.and.arrow.down.right", "두 손가락으로 벌리면 크게 볼 수 있어요"),
            ]),
            .init(id: "lookup", symbols: ["lasso", "text.magnifyingglass"], title: "모르는 말은 올가미로 둘러요", lines: [
                ("lasso", "PDF 도구에서 올가미를 고르고 모르는 말을 둘러싸요"),
                ("text.magnifyingglass", "찾아보기 카드가 뜻을 바로 보여 줘요"),
                ("hand.tap", "글자를 길게 눌러 고른 뒤 찾아보기를 눌러도 돼요"),
            ]),
            .init(id: "ai", symbols: ["sparkles"], title: "AI에게 이 자료로 물어봐요", lines: [
                ("person.crop.circle", "로그인하면 AI가 이 폴더의 자료를 읽고 답해요"),
                ("lasso", "올가미로 고른 곳은 AI에게 묻기로 바로 물어봐요"),
                ("plus", "답 아래 노트에 넣기로 필기 옆에 정리해요"),
                ("hand.point.up.left", "PDF를 연 채 짚어주기를 고르면 PDF 속 위치를 짚으며 설명해요"),
            ]),
            .init(id: "split", symbols: ["rectangle.split.2x1"], title: "나란히 펴 두고 세 손가락으로 탭을 바꿔요", lines: [
                ("rectangle.split.2x1", "탭을 화면 옆으로 끌면 PDF와 노트를 나란히 봐요"),
                ("xmark", "세 손가락을 모으면 지금 탭이 닫혀요"),
                ("plus", "모았다가 펴면 새 탭을 열어요"),
            ]),
            .init(id: "school", symbols: ["building.columns"], title: "학교 사이트는 사이드바에서 열어요", lines: [
                ("building.columns", "학교를 고르면 포털·LMS 바로가기가 사이드바에 들어와요"),
                ("globe", "바로가기를 누르면 반달 안의 브라우저 탭에서 열려요"),
            ]),
        ]
        if NativeReleaseFlags.showsRecording {
            pages.append(.init(id: "recording", symbols: ["mic", "sparkles"], title: "강의는 녹음하고 요약받아요", lines: [
                ("mic", "PDF 도구의 마이크로 녹음을 시작해요"),
                ("sparkles", "끝나면 끝내고 요약을 눌러 AI 요약을 받아요"),
                ("waveform", "녹음과 받아쓴 글은 녹음 탭에 남아요"),
            ]))
        }
        return pages
    }
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let pages = Self.pages, page = pages[min(index, pages.count - 1)], last = index >= pages.count - 1
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                BandalText("반달 잘 쓰는 법").font(.system(size: 13, weight: .semibold)).foregroundStyle(NativeDesktopTheme.secondary)
                Spacer()
                Button(action: close) { BandalText("건너뛰기").font(.system(size: 15, weight: .medium)).frame(minHeight: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary).accessibilityIdentifier("native-guide-tour-skip")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NativeDesktopTheme.surface)
                if page.id == "split" { NativeThreeFingerAnimation() }
                else {
                    HStack(spacing: 18) {
                        ForEach(page.symbols, id: \.self) { Image(systemName: $0).font(.system(size: 40, weight: .light)).foregroundStyle(NativeGlass.accent) }
                    }
                }
            }.frame(height: 124).accessibilityHidden(true)
            BandalText(page.title).font(.system(size: 22, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("native-guide-tour-page-" + page.id)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(page.lines.enumerated()), id: \.offset) { _, line in
                    NativeGuideLine(title: line.text, weight: .regular) { Image(systemName: line.symbol).font(.system(size: 15)).foregroundStyle(NativeGlass.accent) }
                }
            }.frame(minHeight: 150, alignment: .top)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { item in
                        Capsule().fill(item == index ? NativeDesktopTheme.text : NativeDesktopTheme.muted.opacity(0.45)).frame(width: item == index ? 18 : 6, height: 6)
                    }
                }.accessibilityElement().accessibilityLabel(Text(verbatim: "\(index + 1) / \(pages.count)")).accessibilityIdentifier("native-guide-tour-dots")
                Spacer(minLength: 8)
                if index > 0 {
                    Button { step(-1) } label: { BandalText("이전").frame(minWidth: 72) }
                        .buttonStyle(BandalButtonStyle(kind: .outline)).accessibilityIdentifier("native-guide-tour-back")
                }
                Button { if last { close() } else { step(1) } } label: { BandalText(last ? "시작하기" : "다음").frame(minWidth: 96) }
                    .buttonStyle(BandalButtonStyle(kind: .filled)).accessibilityIdentifier(last ? "native-guide-tour-done" : "native-guide-tour-next")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: index)
    }
    private func step(_ delta: Int) { index = min(max(0, index + delta), Self.pages.count - 1) }
}

/// A first-use tip at the foot of the workspace: one line, 알겠어요 and 팁 그만 보기.
struct NativeFirstUseTipCard: View {
    let tip: NativeFirstUseTip
    let dismiss: () -> Void
    let stopAll: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tip.symbol).font(.system(size: 16)).foregroundStyle(NativeGlass.accent).accessibilityHidden(true)
            BandalText(tip.text).font(.system(size: 14, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("native-guide-tip-text")
            NativeDesktopTheme.border.frame(width: 1, height: 18)
            Button(action: dismiss) { BandalText("알겠어요").font(.system(size: 14, weight: .semibold)).frame(minHeight: 40).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityIdentifier("native-guide-tip-ok")
            Button(action: stopAll) { BandalText("팁 그만 보기").font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 40).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityIdentifier("native-guide-tip-stop")
        }
        .foregroundStyle(NativeDesktopTheme.text)
        .padding(.horizontal, 16).frame(maxWidth: 680)
        .bandalGlass(in: Capsule())
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-guide-tip-" + tip.rawValue)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

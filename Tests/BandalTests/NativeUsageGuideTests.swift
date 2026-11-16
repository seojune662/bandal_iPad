import XCTest
@testable import Bandal

/// When 반달 잘 쓰는 법, the new-feature card and the first-use tips show: once each, after first-run setup,
/// and never over anything else.
final class NativeUsageGuideTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "NativeUsageGuideTests"
    override func setUp() { super.setUp(); defaults = UserDefaults(suiteName: suite); defaults.removePersistentDomain(forName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    private func due(onboarded: Bool, arguments: [String] = []) -> NativeGuideGate.Card? {
        NativeGuideGate.due(onboardedThisLaunch: onboarded, arguments: arguments, hostedTest: false, defaults: defaults)
    }

    func testSomeoneNewSeesTheTourOnceAndNotTheNewFeatureCard() {
        XCTAssertEqual(due(onboarded: true), .tour)
        NativeGuideGate.markSeen(.tour, defaults: defaults)
        XCTAssertNil(due(onboarded: true))
        XCTAssertNil(due(onboarded: false), "The tour has the gesture's page: the new-feature card would say it again")
    }

    func testSomeoneUpdatingSeesTheNewFeatureCardOnce() {
        XCTAssertEqual(due(onboarded: false), .intro)
        NativeGuideGate.markSeen(.intro, defaults: defaults)
        XCTAssertNil(due(onboarded: false))
        XCTAssertFalse(defaults.bool(forKey: NativeGuideGate.tourSeenKey), "Seeing the card does not count as the tour")
    }

    func testTheNewFeatureKeyCarriesItsVersion() {
        XCTAssertTrue(NativeGuideGate.introSeenKey.hasPrefix("native.guide."))
        XCTAssertTrue(NativeGuideGate.introSeenKey.hasSuffix(".v1"))
    }

    func testTestsSeeNeitherUnlessTheyAsk() {
        XCTAssertNil(due(onboarded: true, arguments: ["--native-ui-testing"]))
        XCTAssertNil(due(onboarded: false, arguments: ["--native-ui-testing"]))
        XCTAssertNil(NativeGuideGate.due(onboardedThisLaunch: false, arguments: [], hostedTest: true, defaults: defaults))
        XCTAssertEqual(due(onboarded: false, arguments: ["--native-ui-testing", NativeGuideGate.tourArgument]), .tour)
        XCTAssertEqual(due(onboarded: false, arguments: ["--native-ui-testing", NativeGuideGate.introArgument]), .intro)
        NativeGuideGate.markSeen(.intro, defaults: defaults)
        XCTAssertNil(due(onboarded: false, arguments: ["--native-ui-testing", NativeGuideGate.introArgument]), "Asked for, it still shows once")
    }

    func testOnlyAQuietWorkspaceShowsACard() {
        XCTAssertTrue(NativeGuideGate.idle(restored: true, onboardingClosed: true, workspaceShown: true, overlay: false, presented: false))
        XCTAssertFalse(NativeGuideGate.idle(restored: false, onboardingClosed: true, workspaceShown: true, overlay: false, presented: false))
        XCTAssertFalse(NativeGuideGate.idle(restored: true, onboardingClosed: false, workspaceShown: true, overlay: false, presented: false), "Onboarding first")
        XCTAssertFalse(NativeGuideGate.idle(restored: true, onboardingClosed: true, workspaceShown: false, overlay: false, presented: false), "Settings or help is open")
        XCTAssertFalse(NativeGuideGate.idle(restored: true, onboardingClosed: true, workspaceShown: true, overlay: true, presented: false), "The 새 노트 sheet is up")
        XCTAssertFalse(NativeGuideGate.idle(restored: true, onboardingClosed: true, workspaceShown: true, overlay: false, presented: true), "The paywall, a consent sheet or a popover is up")
    }

    func testEachTipShowsOnceAndStopAllEndsThem() {
        for tip in NativeFirstUseTip.allCases { XCTAssertTrue(tip.isDue(arguments: [], hostedTest: false, defaults: defaults)) }
        NativeFirstUseTip.pdf.markSeen(defaults: defaults)
        XCTAssertFalse(NativeFirstUseTip.pdf.isDue(arguments: [], hostedTest: false, defaults: defaults))
        XCTAssertTrue(NativeFirstUseTip.ai.isDue(arguments: [], hostedTest: false, defaults: defaults))
        NativeFirstUseTip.stopAll(defaults: defaults)
        for tip in NativeFirstUseTip.allCases { XCTAssertFalse(tip.isDue(arguments: [], hostedTest: false, defaults: defaults)) }
        // 설정's switch back on: each tip once more.
        NativeFirstUseTip.setEnabled(true, defaults: defaults)
        for tip in NativeFirstUseTip.allCases { XCTAssertTrue(tip.isDue(arguments: [], hostedTest: false, defaults: defaults)) }
    }

    func testTipsStayOutOfTestsUnlessAsked() {
        XCTAssertFalse(NativeFirstUseTip.lasso.isDue(arguments: ["--native-ui-testing"], hostedTest: false, defaults: defaults))
        XCTAssertTrue(NativeFirstUseTip.lasso.isDue(arguments: ["--native-ui-testing", NativeFirstUseTip.argument], hostedTest: false, defaults: defaults))
    }

    func testTourPagesUseTheScreensNames() {
        let pages = NativeUsageTour.pages
        XCTAssertTrue((4...6).contains(pages.count))
        XCTAssertEqual(pages.contains { $0.id == "recording" }, NativeReleaseFlags.showsRecording)
        let text = pages.flatMap { [$0.title] + $0.lines.map(\.text) }.joined(separator: " ")
        for name in ["올가미", "찾아보기", "AI에게 묻기", "노트에 넣기", "짚어주기", "세 손가락"] { XCTAssertTrue(text.contains(name), name) }
    }

    func testEveryGuideStringHasAnEnglishLine() throws {
        let url = try XCTUnwrap(Bundle(for: NativeWorkspaceStore.self).url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        var strings = NativeUsageTour.pages.flatMap { [$0.title] + $0.lines.map(\.text) } + NativeFirstUseTip.allCases.map(\.text)
        strings += ["반달 잘 쓰는 법", "건너뛰기", "이전", "다음", "시작하기", "새 기능", "손가락 3개로 탭 열고 닫기", "세 손가락을 모으면 탭이 닫혀요",
                    "모았다가 펴면 새 탭을 열어요", "설정에서 열 탭 고르기", "확인", "알겠어요", "팁 그만 보기", "탭을 닫았어요", "되돌리기",
                    "놓으면 탭 닫기", "놓으면 새 탭", "세 손가락으로 탭 열고 닫기", "세 손가락으로 펼쳐서 열기", "매번 고르기"]
        for string in strings { XCTAssertNotNil(table[string], string) }
    }
}

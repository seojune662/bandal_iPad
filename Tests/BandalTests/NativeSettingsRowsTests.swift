import XCTest
@testable import Bandal

final class NativeSettingsRowsTests: XCTestCase {
    func testUsageAlertFiresOnlyWhenCrossingEightyPercent() {
        XCTAssertTrue(AIUsage.crossesAlert(from: 79, to: 80))
        XCTAssertTrue(AIUsage.crossesAlert(from: 40, to: 95))
        XCTAssertFalse(AIUsage.crossesAlert(from: 80, to: 90), "Already above")
        XCTAssertFalse(AIUsage.crossesAlert(from: nil, to: 90), "First load is not a crossing")
        XCTAssertFalse(AIUsage.crossesAlert(from: 90, to: 10), "The monthly reset")
    }
    @MainActor func testUsageUpdatePostsOneNotificationAtTheThreshold() {
        UserDefaults.standard.removeObject(forKey: NativeAIPreferences.usageAlertKey)
        let usage = AIUsage(); var posted = 0
        usage.postNotification = { _ in posted += 1 }
        usage.update(["percent": 70]); usage.update(["percent": 82]); usage.update(["percent": 90])
        XCTAssertEqual(posted, 1)
        UserDefaults.standard.set(false, forKey: NativeAIPreferences.usageAlertKey)
        defer { UserDefaults.standard.removeObject(forKey: NativeAIPreferences.usageAlertKey) }
        let quiet = AIUsage(); quiet.postNotification = { _ in posted += 1 }
        quiet.update(["percent": 70]); quiet.update(["percent": 85])
        XCTAssertEqual(posted, 1, "Off in Settings")
    }
    func testAnswerLanguageAddsAnInstructionOnlyWhenChosen() {
        XCTAssertEqual(NativeAIPreferences.languageInstruction("auto"), "")
        XCTAssertEqual(NativeAIPreferences.languageInstruction(nil), "")
        XCTAssertTrue(NativeAIPreferences.languageInstruction("ko").contains("한국어"))
        XCTAssertTrue(NativeAIPreferences.languageInstruction("en").contains("English"))
    }
}

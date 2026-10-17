import XCTest
@testable import Bandal

final class NativeAssistantPreferenceTests: XCTestCase {
    func testDesktopProviderPreferenceMapsToCloudServiceIDs() {
        XCTAssertEqual(NativeAssistantPreferences.defaultProvider(["agentProvider": "codex"]), NativeAIProvider.openAI.rawValue)
        XCTAssertEqual(NativeAssistantPreferences.defaultProvider(["agentProvider": "claude-code"]), NativeAIProvider.anthropic.rawValue)
        XCTAssertEqual(NativeAssistantPreferences.defaultProvider(["agentProvider": "gemini"]), NativeAIProvider.google.rawValue)
    }
    func testMissingOrInvalidPreferenceMatchesSchemaDefault() {
        let defaults = NativeSettingsSchema.defaults(dataRoot: "/unused")
        XCTAssertEqual(NativeAssistantPreferences.defaultProvider([:]), defaults["agentProvider"] as? String)
        XCTAssertEqual(NativeAssistantPreferences.defaultProvider(["agentProvider": NSNull()]), defaults["agentProvider"] as? String)
        XCTAssertEqual(NativeAssistantPreferences.defaultProvider(["agentProvider": "unknown"]), defaults["agentProvider"] as? String)
    }
}

import XCTest
@testable import Bandal

final class NativeSidebarContractTests: XCTestCase {
    func testFavoriteDescriptorPreservesOriginalMaterialAndActualToolContentIDs() throws {
        let material = NativeDocumentReference(courseID: "course", relativePath: "자료/original.pdf", title: "별명", kind: "pdf")
        let pdf = try XCTUnwrap(NativeSidebarDescriptor.document(material))
        XCTAssertEqual(pdf["kind"] as? String, "pdf")
        XCTAssertEqual((pdf["payload"] as? [String: Any])?["relPath"] as? String, "자료/original.pdf")
        let assistant = NativeDocumentReference(courseID: "course", relativePath: "tab-uuid", title: "AI", kind: "assistant")
        let chat = try XCTUnwrap(NativeSidebarDescriptor.document(assistant, conversationID: "actual-conversation"))
        XCTAssertEqual((chat["payload"] as? [String: Any])?["conversationId"] as? String, "actual-conversation")
        let recording = NativeDocumentReference(courseID: "course", relativePath: "tab-uuid", title: "녹음", kind: "recordings")
        let audio = try XCTUnwrap(NativeSidebarDescriptor.document(recording, recordingID: "actual-recording"))
        XCTAssertEqual((audio["payload"] as? [String: Any])?["recordingId"] as? String, "actual-recording")
    }
    func testLearningHomeAndRootProjectHaveDifferentPortableFavoriteBindings() throws {
        let home = NativeDocumentReference(courseID: "course", relativePath: "tab-uuid", title: "학습 공간", kind: "learning-home")
        let project = NativeDocumentReference(courseID: "course", relativePath: "", title: "영어", kind: "learning")
        let homeRow = try XCTUnwrap(NativeSidebarDescriptor.document(home)), projectRow = try XCTUnwrap(NativeSidebarDescriptor.document(project))
        XCTAssertEqual(homeRow["kind"] as? String, "learning")
        XCTAssertNil((homeRow["payload"] as? [String: Any])?["rootRelPath"])
        XCTAssertEqual((projectRow["payload"] as? [String: Any])?["rootRelPath"] as? String, "")
    }
    func testPrivateOrMissingBrowserURLCannotProduceAnUnintendedFavorite() throws {
        let browser = NativeDocumentReference(courseID: "course", relativePath: "scope", title: "Browser", kind: "browser")
        XCTAssertNil(NativeSidebarDescriptor.document(browser))
        for url in ["javascript:alert(1)", "file:///private/local", "about:blank"] { XCTAssertNil(NativeSidebarDescriptor.document(browser, browserURL: url)) }
        let result = try XCTUnwrap(NativeSidebarDescriptor.document(browser, browserURL: "https://claude.ai/chat/existing"))
        XCTAssertEqual((result["payload"] as? [String: Any])?["initialUrl"] as? String, "https://claude.ai/chat/existing")
        XCTAssertEqual(NativeAIWebShortcut.all.map(\.title), ["ChatGPT", "Gemini", "Claude"])
        XCTAssertTrue(NativeAIWebShortcut.all[0].hosts.contains("chat.openai.com"))
    }
}

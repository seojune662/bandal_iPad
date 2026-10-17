import XCTest
@testable import Bandal

final class NativeNewTabMenuTests: XCTestCase {
    func testMenuOffersExactlyFiveTabKindsInOrderAndFiltersBySearch() {
        let initial = NativeNewTabCatalog.items(query: "", courseName: "Class")
        XCTAssertEqual(initial.map(\.id), ["new-browser", "new-whiteboard", "new-note", "chat", "recording"])
        XCTAssertEqual(initial.map(\.title), ["브라우저", "노트", "마크다운", "AI", "녹음"])
        XCTAssertEqual(NativeNewTabCatalog.items(query: "마크", courseName: "Class").map(\.id), ["new-note"])
        XCTAssertEqual(NativeNewTabCatalog.items(query: "필기", courseName: "Class").first?.action, .note)
        XCTAssertFalse(initial.contains { $0.title.contains("화이트보드") })
    }
    func testURLInputOpensExactURLRatherThanBecomingFileSearchOrShellScheme() {
        let rows = NativeNewTabCatalog.items(query: "example.edu/notes", courseName: "Class")
        XCTAssertEqual(rows.map(\.id), ["new-browser"])
        XCTAssertEqual(rows.first?.action, .browser(url: "https://example.edu/notes"))
        XCTAssertEqual(NativeNewTabCatalog.url("https://example.edu?q=one"), "https://example.edu?q=one")
        for input in ["a question", "file:///private/test", "javascript:alert(1)", "data:text/html,test"] { XCTAssertNil(NativeNewTabCatalog.url(input)) }
    }
}

final class NativeToolSelectionTests: XCTestCase {
    func testConversationFavoriteRestoresContentIDIntoAnIndependentWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeToolSelection.restoreConversation("conversation-a", workspaceID: "source/tab", root: root)
        let captured = try XCTUnwrap(NativeToolSelection.conversationID(workspaceID: "source/tab", root: root))
        XCTAssertNotEqual(captured, "source/tab")
        try NativeToolSelection.restoreConversation(captured, workspaceID: "favorite-tab", root: root)
        try NativeToolSelection.restoreConversation("conversation-b", workspaceID: "source/tab", root: root)
        XCTAssertEqual(NativeToolSelection.conversationID(workspaceID: "favorite-tab", root: root), "conversation-a")
        XCTAssertEqual(NativeToolSelection.conversationID(workspaceID: "source/tab", root: root), "conversation-b")
        XCTAssertNil(NativeToolSelection.conversationID(workspaceID: "new-tab", root: root))
    }

    func testRecordingFavoriteKeepsSelectionScopedToWorkspaceAndCourse() throws {
        let suite = "NativeToolSelectionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        NativeToolSelection.restoreRecording("recording-a", workspaceID: "tab-a", courseID: "course-a", defaults: defaults)
        let captured = try XCTUnwrap(NativeToolSelection.recordingID(workspaceID: "tab-a", courseID: "course-a", defaults: defaults))
        NativeToolSelection.restoreRecording(captured, workspaceID: "favorite-tab", courseID: "course-a", defaults: defaults)
        NativeToolSelection.restoreRecording("recording-b", workspaceID: "tab-a", courseID: "course-a", defaults: defaults)
        XCTAssertEqual(NativeToolSelection.recordingID(workspaceID: "favorite-tab", courseID: "course-a", defaults: defaults), "recording-a")
        XCTAssertEqual(NativeToolSelection.recordingID(workspaceID: "tab-a", courseID: "course-a", defaults: defaults), "recording-b")
        XCTAssertNil(NativeToolSelection.recordingID(workspaceID: "tab-a", courseID: "course-b", defaults: defaults))
    }
}

@MainActor
final class NativeStudyMarketClientTests: XCTestCase {
    func testUnconfiguredAndSignedOutStateDoesNotInventNetworkListingsOrAttemptTrading() async throws {
        var calls = 0
        let cloud = DesktopCloudService(environment: .init(configuration: { ("", "", "") }, signedIn: { false }, credential: { throw CancellationError() }, request: { _, _ in calls += 1; throw URLError(.unsupportedURL) }))
        let client = NativeStudyMarketClient(cloud: cloud)
        let context = try await client.request(["action": "context"]) as! [String: Any]
        XCTAssertEqual(context["configured"] as? Bool, false)
        XCTAssertEqual(context["tradingEnabled"] as? Bool, false)
        XCTAssertTrue((context["universities"] as? [Any])?.isEmpty == true)
        for action in ["listings", "order", "saveDraft", "refund"] {
            do { _ = try await client.request(["action": action]); XCTFail("Unsupported actions must not look successful") } catch { }
        }
        XCTAssertEqual(calls, 0)
    }
    func testBrowseUsesExistingPublicContractAndRemovesDownloadedResponse() async throws {
        var output: URL?
        let cloud = DesktopCloudService(environment: .init(configuration: { ("https://fixture.supabase.co", "public-test", "") }, signedIn: { false }, credential: { throw CancellationError() }, request: { request, _ in
            XCTAssertEqual(request.url?.path, "/functions/v1/study-market")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-test")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["action"] as? String, "listings")
            XCTAssertEqual((body["input"] as? [String: Any])?["q"] as? String, "미분")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); output = file
            try Data(#"{"listings":[{"id":"real-row","title":"미분"}],"nextCursor":null}"#.utf8).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        let client = NativeStudyMarketClient(cloud: cloud)
        let result = try await client.request(["action": "listings", "input": ["universityId": "school", "q": "미분"]]) as! [String: Any]
        XCTAssertEqual((result["listings"] as? [[String: Any]])?.first?["id"] as? String, "real-row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(output).path))
    }
}

import XCTest
@testable import Bandal

final class NativeBrowserAddressTests: XCTestCase {
    func testDirectNavigationAndEngineSearchUseTheSameResolutionAsSuggestions() throws {
        for value in ["localhost:8123/lecture", "http://intranet/lecture", "https://예시.한국/수학", "example.org/path?q=one"] {
            let resolved = try NativeBrowserAddress.resolve(value)
            XCTAssertEqual(NativeBrowserAddress.suggestions(value, engine: "google", tabs: [], favorites: [], services: [], history: []).first?.url, resolved.absoluteString)
            XCTAssertEqual(NativeBrowserAddress.suggestions(value, engine: "google", tabs: [], favorites: [], services: [], history: []).first?.kind, .address)
        }
        let searched = try NativeBrowserAddress.resolve("수학 & science", engine: "naver")
        XCTAssertEqual(URLComponents(url: searched, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "수학 & science")
        XCTAssertThrowsError(try NativeBrowserAddress.resolve("https://user:secret@example.org"))
        XCTAssertThrowsError(try NativeBrowserAddress.resolve("file:///private/test"))
    }
    func testSuggestionRankingDeduplicatesCanonicalAddressesAndKeepsSearchFirst() {
        let rows = NativeBrowserAddress.suggestions("lecture", engine: "google",
            tabs: [.init(title: "Lecture course", url: "https://EXAMPLE.org")],
            favorites: [.init(title: "Lecture copy", url: "https://example.org/"), .init(title: "Lecture resources", url: "https://resources.example/lecture")],
            services: [], history: [.init(title: "History", url: "https://lecture.example/unit")])
        XCTAssertEqual(rows.first?.kind, .search)
        XCTAssertEqual(rows.dropFirst().first?.url, "https://lecture.example/unit", "Host prefix wins over a title prefix")
        XCTAssertEqual(rows.filter { NativeBrowserAddress.canonical($0.url) == "https://example.org/" }.count, 1)
        XCTAssertEqual(rows.first { NativeBrowserAddress.canonical($0.url) == "https://example.org/" }?.kind, .tab)
    }
    func testKeyboardSelectionPreservesItsURLWhenDelayedHistoryChangesRanking() {
        let open = [NativeBrowserLink(title: "Lecture course", url: "https://school.example/lesson")]
        let initial = NativeBrowserAddress.suggestions("lecture", engine: "google", tabs: open, favorites: [], services: [], history: [])
        var selection = NativeBrowserSuggestionSelection(); selection.move(1, in: initial)
        XCTAssertEqual(initial[selection.index(in: initial)].url, open[0].url)
        let refreshed = NativeBrowserAddress.suggestions("lecture", engine: "google", tabs: open, favorites: [], services: [], history: [.init(title: "History", url: "https://lecture.example/material")])
        XCTAssertEqual(refreshed[1].url, "https://lecture.example/material")
        XCTAssertEqual(refreshed[selection.index(in: refreshed)].url, open[0].url, "Enter must keep the URL selected before history arrived")
    }
    func testSuggestionsMatchEveryNormalizedTermAndRejectUnsafeStoredLinks() {
        let rows = NativeBrowserAddress.suggestions("한글 자료", engine: "google", tabs: [], favorites: [
            .init(title: "한글", url: "https://example.org/%EC%9E%90%EB%A3%8C"),
            .init(title: "한글 자료", url: "https://user:secret@example.org"),
            .init(title: "한글 자료", url: "file:///private/test")], services: [], history: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.url, "https://example.org/%EC%9E%90%EB%A3%8C")
        let many = (0..<20).map { NativeBrowserLink(title: "Page \($0)", url: "https://example.org/\($0)") }
        XCTAssertEqual(NativeBrowserAddress.suggestions("page", engine: "google", tabs: [], favorites: many, services: [], history: []).count, 8)
    }
    func testInterruptedDownloadsOfferNetworkRetrySeparatelyFromMaterialRecovery() throws {
        for state in ["interrupted", "cancelled"] {
            let item = try XCTUnwrap(NativeBrowserDownloadItem(["id": "test", "state": state, "recoverable": false]))
            XCTAssertEqual(item.retryTitle, "다시 받기")
        }
        let material = try XCTUnwrap(NativeBrowserDownloadItem(["id": "test", "state": "completed", "recoverable": true]))
        XCTAssertEqual(material.retryTitle, "과목에 저장")
        let complete = try XCTUnwrap(NativeBrowserDownloadItem(["id": "test", "state": "completed", "recoverable": false]))
        XCTAssertNil(complete.retryTitle)
    }
    func testGenericTitlesRemainDistinguishableAndBlurredAddressHidesPath() {
        XCTAssertEqual(NativeBrowserAddress.title("Home", url: "https://www.school.example/private/lesson"), "school.example · Home")
        XCTAssertEqual(NativeBrowserAddress.display("http://localhost:8123/lecture?private=yes"), "http://localhost:8123")
        XCTAssertEqual(NativeBrowserAddress.display("about:blank"), "")
    }
}

@MainActor
final class NativeBrowserFeaturesTests: XCTestCase {
    func testExternalProfileMutationRefreshesEveryOpenSession() async throws {
        let (root, store, host, session) = await makeSession()
        defer { host.pages.keys.forEach(host.destroy); try? FileManager.default.removeItem(at: root) }
        let peer = NativeBrowserSession(store: store, host: host, workspaceID: "peer"); await peer.start()
        let saved = try await host.handle(channel: "browser:saveProfile", request: ["name": "New shared profile", "color": "blue", "icon": "person"]) as? [String: String]
        let id = try XCTUnwrap(saved?["id"])
        for _ in 0..<100 where session.profiles.contains(where: { $0["id"] == id }) == false || peer.profiles.contains(where: { $0["id"] == id }) == false { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.profiles.contains { $0["id"] == id }); XCTAssertTrue(peer.profiles.contains { $0["id"] == id })
        _ = try await host.handle(channel: "browser:deleteProfile", request: ["id": id])
        for _ in 0..<100 where session.profiles.contains(where: { $0["id"] == id }) || peer.profiles.contains(where: { $0["id"] == id }) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.profiles.contains { $0["id"] == id }); XCTAssertFalse(peer.profiles.contains { $0["id"] == id })
    }
    func testFindResultsAreBoundToBothTheOwningTabAndCurrentQuery() async throws {
        let (root, store, host, session) = await makeSession()
        defer { host.pages.keys.forEach(host.destroy); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(session.activeID)
        session.findStates[id] = .init(visible: true, query: "new", searchedQuery: "new")
        func emit(_ tab: String, query: String, count: Int) {
            store.events.send(.init(channel: "browser:page-event", payload: ["tabId": tab, "name": "found-in-page", "detail": ["result": ["query": query, "matches": count, "activeMatchOrdinal": 1]]]))
        }
        emit(id, query: "old", count: 50); XCTAssertNil(session.findState.count)
        emit(NativeBrowserSession.scopePrefix("foreign") + "x", query: "new", count: 50); XCTAssertNil(session.findState.count)
        emit(id, query: "new", count: 3); XCTAssertEqual(session.findState.count, 3)
        let second = try await session.add(); XCTAssertFalse(session.findState.visible)
        session.select(id); XCTAssertEqual(session.findState.count, 3)
        store.events.send(.init(channel: "browser:page-event", payload: ["tabId": second, "name": "did-start-loading"]))
        XCTAssertEqual(session.findState.count, 3, "Another tab's navigation must not close the active search")
        session.setFindVisible(false); emit(id, query: "new", count: 7); XCTAssertNil(session.findState.count)
    }
    func testFindReopenResetsOldResultsAndRepeatedOpenRequestsInputFocus() async throws {
        let (root, _, host, session) = await makeSession()
        defer { host.pages.keys.forEach(host.destroy); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(session.activeID)
        session.findStates[id] = .init(visible: true, query: "needle", searchedQuery: "needle", count: 3, ordinal: 2)
        session.setFindVisible(false)
        XCTAssertEqual(session.findState.query, "needle")
        XCTAssertNil(session.findState.count); XCTAssertNil(session.findState.searchedQuery)
        session.setFindVisible(true)
        XCTAssertTrue(session.findState.visible); XCTAssertNil(session.findState.count)
        XCTAssertNotNil(session.findTasks[id], "Reopening must request a new search, rather than displaying the removed highlight's count")
        let firstFocus = session.findState.focusRevision
        session.setFindVisible(true)
        XCTAssertGreaterThan(session.findState.focusRevision, firstFocus, "Cmd+F must refocus an already visible input")
        session.setFindVisible(false)
    }
    func testDownloadVisibilityKeepsPrivateScopesAndProfilesSeparateAfterTabClosure() async throws {
        let (root, _, host, session) = await makeSession()
        defer { host.pages.keys.forEach(host.destroy); try? FileManager.default.removeItem(at: root) }
        let privateID = try await session.add(isPrivate: true)
        let previousPrivate = NativeBrowserSession.scopePrefix("features") + "closed-tab"
        let foreign = NativeBrowserSession.scopePrefix("other") + "tab"
        session.downloadItems = [
            ["id": "mine", "tabId": privateID, "isPrivate": true],
            ["id": "closed", "tabId": previousPrivate, "isPrivate": true],
            ["id": "foreign", "tabId": foreign, "isPrivate": true],
            ["id": "other-profile", "tabId": privateID, "isPrivate": true, "profileId": "other"],
            ["id": "public", "tabId": privateID, "isPrivate": false]
        ].compactMap(NativeBrowserDownloadItem.init)
        XCTAssertEqual(Set(session.visibleDownloads.map(\.id)), ["mine", "closed"])
        session.select(try XCTUnwrap(session.tabs.first { !$0.isPrivate }?.id))
        XCTAssertEqual(session.visibleDownloads.map(\.id), ["public"])
    }
    func testDownloadOpenUsesImportCompletedAfterTheClickedRowSnapshot() async throws {
        let (root, store, host, session) = await makeSession()
        defer { host.pages.keys.forEach(host.destroy); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(session.activeID)
        let clicked = try XCTUnwrap(NativeBrowserDownloadItem(["id": "finished-during-dismiss", "tabId": id, "state": "completed", "courseId": "course-a", "fileName": "lecture.pdf"]))
        session.downloadItems = [clicked]
        var opened: [String: Any]?
        let subscription = store.events.sink { event in
            if event.channel == "nativeWorkspace:openDocument" { opened = event.payload as? [String: Any] }
        }
        defer { subscription.cancel() }
        store.events.send(.init(channel: "browser:download", payload: ["id": clicked.id, "tabId": id, "state": "completed", "courseId": "course-a", "fileName": "lecture.pdf", "relPath": "Downloads/lecture.pdf"]))
        try await session.downloadAction(clicked, action: "open")
        XCTAssertEqual(opened?["courseId"] as? String, "course-a")
        XCTAssertEqual(opened?["relPath"] as? String, "Downloads/lecture.pdf")
        XCTAssertEqual(opened?["kind"] as? String, "pdf")
    }
    func testDefaultZoomResetAndPrivateHistoryDoNotReadAnotherProfile() async throws {
        let (root, _, host, session) = await makeSession()
        defer { host.pages.keys.forEach(host.destroy); try? FileManager.default.removeItem(at: root) }
        session.preferences = ["browser": ["defaultZoomLevel": 2]]
        try await session.zoom(nil); XCTAssertEqual(session.zoomPercent, 144)
        try await session.zoom(1); XCTAssertEqual(session.zoomPercent, 173)
        try await session.add(isPrivate: true)
        let history = try await session.searchHistory(""); XCTAssertTrue(history.isEmpty)
    }
    private func makeSession() async -> (URL, NativeWorkspaceStore, DesktopBrowserHost, NativeBrowserSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-features-\(UUID())")
        let store = NativeWorkspaceStore(storageRoot: root); await store.start()
        let host = DesktopBrowserHost(root: root)
        host.emit = { channel, payload in store.events.send(.init(channel: channel, payload: payload)) }
        let session = NativeBrowserSession(store: store, host: host, workspaceID: "features")
        await session.start(); XCTAssertNil(session.error)
        return (root, store, host, session)
    }
}

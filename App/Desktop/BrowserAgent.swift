import Foundation
import WebKit
import ObjectiveC

@MainActor
private final class BrowserAgentState {
    // WKContentWorld must stay retained across requests: snapshot element
    // identities live in this world's JS heap until the next navigation.
    let world = WKContentWorld.world(name: "bandal-browser-agent")
    var documents: [String: (identity: String, generation: Int)] = [:]
    var script: String?
    var published: [String: [[String: Any]]] = [:]
    var active: [String: String] = [:]
}
@MainActor private var browserAgentStateKey: UInt8 = 0

extension DesktopBrowserHost {
    private var agentState: BrowserAgentState {
        if let state = objc_getAssociatedObject(self, &browserAgentStateKey) as? BrowserAgentState { return state }
        let state = BrowserAgentState(); objc_setAssociatedObject(self, &browserAgentStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC); return state
    }
    func agentGeneration(_ page: DesktopBrowserPage) -> Int {
        let identity = (page.state["authDocumentId"] as? String ?? "") + ":" + (page.state["url"] as? String ?? "")
        let previous = agentState.documents[page.tabID]
        if previous?.identity == identity { return previous!.generation }
        let generation = (previous?.generation ?? 0) + 1
        agentState.documents[page.tabID] = (identity, generation); return generation
    }
    func agentRequest(_ request: [String: Any]) async throws -> Any {
        let tool = try Self.string(request, "tool")
        var input = request["input"] as? [String: Any] ?? [:]
        if tool == "registerTab" {
            guard let tabID = input["tabId"] as? String, let page = pages[tabID], input["webContentsId"] as? Int == page.id else { throw DesktopBrowserError.invalid("브라우저 탭 등록") }
            return ["ok": true]
        }
        let courseID = try Self.string(request, "courseId")
        if tool == "syncTabs" {
            guard let tabs = input["tabs"] as? [[String: Any]], tabs.count <= 200,
                  tabs.allSatisfy({ $0["tabId"] is String && $0["url"] is String && $0["title"] is String }) else { throw DesktopBrowserError.invalid("브라우저 탭 목록") }
            agentState.published[courseID] = tabs; agentState.active[courseID] = input["activeTabId"] as? String
            return ["ok": true]
        }
        try requireAgentAccess()
        if tool == "lmsFetch" {
            let raw = try Self.string(input, "url", limit: 8192), origin = try Self.string(input, "origin", limit: 4096)
            let activePage = agentState.active[courseID].flatMap { pages[$0] }
            let profile = activePage?.courseID == courseID && activePage?.isPrivate == false ? activePage!.profileID : "default"
            return try await fetchLMS(url: raw, origin: origin, profileID: profile)
        }
        if tool == "download" {
            let url = try Self.navigationURL(Self.string(input, "url", limit: 8192))
            guard ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { throw DesktopBrowserError.invalid("자료 다운로드 주소") }
            var result: [String: Any] = ["courseId": courseID, "url": url.absoluteString, "dirRelPath": input["dirRelPath"] as? String ?? ""]
            if let tabID = input["tabId"] as? String {
                guard let page = pages[tabID], page.courseID == courseID, !page.isPrivate, !page.webView.isLoading else { throw DesktopBrowserError.unavailable("다운로드 원문 탭을 확인할 수 없습니다.") }
                if let expected = request["expectedUrl"] as? String, expected != page.webView.url?.absoluteString { throw DesktopBrowserError.unavailable("다운로드 원문 주소가 변경되었습니다.") }
                if let expected = request["expectedGeneration"] as? Int, expected != agentGeneration(page) { throw DesktopBrowserError.unavailable("다운로드 원문 페이지가 변경되었습니다.") }
                result["tabId"] = tabID
            }
            return result
        }
        if tool == "tabs" {
            var tabs = pages.values.filter { $0.courseID == courseID && !$0.isPrivate }.sorted { $0.id < $1.id }.map { page -> [String: Any] in
                ["tabId": page.tabID, "title": page.state["title"] ?? "", "url": page.state["url"] ?? "about:blank", "active": page.bounds != nil, "asleep": page.isSuspended, "generation": agentGeneration(page)]
            }
            for saved in agentState.published[courseID] ?? [] where !tabs.contains(where: { $0["tabId"] as? String == saved["tabId"] as? String }) && pages[saved["tabId"] as? String ?? ""]?.isPrivate != true {
                var asleep = saved; asleep["asleep"] = true; asleep["active"] = saved["tabId"] as? String == agentState.active[courseID]; asleep["generation"] = 0; tabs.append(asleep)
            }
            return ["status": "ok", "tabs": tabs, "activeTabId": agentState.active[courseID] as Any? ?? tabs.first(where: { $0["active"] as? Bool == true })?["tabId"] ?? NSNull()]
        }
        if tool == "open" {
            let address = try Self.navigationURL(Self.string(input, "url", limit: 8192))
            guard ["http", "https"].contains(address.scheme ?? ""), address.user == nil, address.password == nil else { throw DesktopBrowserError.invalid("AI 웹 주소") }
            try await prepareBrowserNetwork()
            let page = try createPage(tabID: UUID().uuidString, profileID: "default", isPrivate: false, courseID: courseID)
            page.load(navigationRequest(address))
            emit("browser:open-url", ["tabId": page.tabID, "courseId": courseID, "url": address.absoluteString, "profileId": page.profileID, "isPrivate": false, "webContentsId": page.id])
            try await waitForPage(page)
            return ["status": "ok", "tabId": page.tabID, "url": page.webView.url?.absoluteString ?? address.absoluteString, "generation": agentGeneration(page)]
        }
        let tabID = try Self.string(input, "tabId")
        if pages[tabID] == nil, agentState.published[courseID]?.contains(where: { $0["tabId"] as? String == tabID }) == true {
            // The original renderer owns profile/private mode for unloaded
            // tabs. Activate it and wait for its normal createPage path.
            emit("browser:activate-tab", ["tabId": tabID])
            let deadline = Date().addingTimeInterval(15)
            while pages[tabID] == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if let page = pages[tabID] { try await waitForPage(page) }
        }
        guard let page = pages[tabID], page.courseID == courseID, !page.isPrivate else { throw DesktopBrowserError.unavailable("이 과목의 일반 브라우저 탭만 사용할 수 있습니다.") }
        if page.isSuspended { _ = page.webView; try await waitForPage(page) }
        let generation = agentGeneration(page), url = page.state["url"] as? String ?? "about:blank"
        guard !page.webView.isLoading || tool == "stop" else { throw DesktopBrowserError.unavailable("페이지를 불러오는 중입니다. 완료된 뒤 다시 살펴봐 주세요.") }
        if let expected = request["expectedUrl"] as? String, expected != url { throw DesktopBrowserError.unavailable("확인한 주소가 변경되었습니다.") }
        if let expected = request["expectedGeneration"] as? Int, expected != generation { throw DesktopBrowserError.unavailable("확인한 페이지가 변경되었습니다. 다시 살펴봐 주세요.") }
        if tool == "savedLogin" {
            let origin = try DesktopCredentialsService.origin(url)
            let target = try credentialTarget(guestID: page.id, origin: origin)
            return ["guestWebContentsId": target.guestID, "origin": target.origin]
        }
        if tool == "handoff" {
            emit("browser:activate-tab", ["tabId": tabID])
            page.webView.becomeFirstResponder(); page.send("focus", ["webContentsId": page.id]); return ["status": "ok"]
        }
        if ["focus", "close", "stop"].contains(tool) {
            if tool == "close" { emit("browser:close-tab", ["tabId": tabID]); destroy(tabID) }
            else if tool == "stop" { page.stop() }
            else { emit("browser:activate-tab", ["tabId": tabID]); page.webView.becomeFirstResponder() }
            return ["status": "ok", "url": url]
        }
        if tool == "forward" || tool == "reload" {
            if tool == "forward" { guard page.webView.canGoForward else { throw DesktopBrowserError.unavailable("다음 페이지가 없습니다.") }; page.webView.goForward() }
            else { try page.reload() }
            try await waitForPage(page); return ["status": "ok", "url": page.webView.url?.absoluteString ?? url, "title": page.webView.title ?? "", "navigated": true]
        }
        if tool == "find" {
            let text = (input["query"] as? String) ?? (input["text"] as? String) ?? ""
            guard !text.isEmpty, text.count <= 1000 else { throw DesktopBrowserError.invalid("검색어") }
            let found = try await page.webView.callAsyncJavaScript(BrowserScripts.find, arguments: ["query": text, "next": false, "forward": true, "matchCase": false], in: nil, contentWorld: .defaultClient)
            return ["status": "ok", "url": url, "result": found ?? NSNull()]
        }
        if tool == "back" {
            guard page.state["canGoBack"] as? Bool == true else { throw DesktopBrowserError.unavailable("이전 페이지가 없습니다.") }
            try page.goBack(); try await waitForPage(page)
            return ["status": "ok", "url": page.webView.url?.absoluteString ?? "", "title": page.webView.title ?? "", "navigated": true]
        }
        guard ["inspect", "snapshot", "read", "act", "scroll", "hover", "key", "submit", "attachFile"].contains(tool) else { throw DesktopBrowserError.unsupported("AI 브라우저 \(tool)") }
        if tool == "submit" || tool == "attachFile" || tool == "key" {
            guard request["expectedUrl"] is String, request["expectedGeneration"] is Int, request["expectedFacts"] is [String: Any] else { throw DesktopBrowserError.unavailable("확인한 페이지와 입력 항목이 필요합니다.") }
            if tool != "key" || input["key"] as? String == "Enter" {
                guard input["approved"] as? Bool == true else { throw DesktopBrowserError.unavailable("이번 동작에 대한 확인이 필요합니다.") }
            }
        }
        if tool == "attachFile" {
            guard input["courseId"] as? String == courseID, let read = onAgentAttachment else { throw DesktopBrowserError.unavailable("이 과목 자료만 첨부할 수 있습니다.") }
            let relative = try Self.string(input, "relPath", limit: 8192)
            let file = try await read(courseID, relative)
            guard file.data.count <= 25 * 1024 * 1024, !file.name.isEmpty, file.name == (file.name as NSString).lastPathComponent, !file.name.contains("\\") else { throw DesktopBrowserError.unavailable("에이전트는 25MB 이하 파일을 첨부할 수 있습니다. 더 큰 파일은 직접 선택해 주세요.") }
            try requireAgentAccess()
            guard pages[tabID] === page, page.courseID == courseID, !page.webView.isLoading, agentGeneration(page) == generation else { throw DesktopBrowserError.unavailable("파일을 준비하는 동안 페이지가 변경되었습니다.") }
            input["file"] = ["name": file.name, "mimeType": file.mimeType, "dataBase64": file.data.base64EncodedString()]
        }
        let source: String
        if let cached = agentState.script { source = cached }
        else {
            guard let file = Bundle.main.resourceURL?.appendingPathComponent("DesktopNative/browser-agent.js") else { throw DesktopBrowserError.unavailable("브라우저 도구를 준비하지 못했습니다.") }
            source = try String(contentsOf: file, encoding: .utf8); agentState.script = source
        }
        input["tool"] = tool; input["generation"] = generation; input["expectedUrl"] = url
        if let facts = request["expectedFacts"] { input["expectedFacts"] = facts }
        if tool == "scroll", let target = input["to"] as? [String: Any], target["kind"] as? String == "ref" { input["ref"] = target["ref"] }
        let result = try await page.webView.callAsyncJavaScript("if(typeof globalThis.__bandalBrowserAgent!=='function'){\(source)} return await globalThis.__bandalBrowserAgent(input)", arguments: ["input": input], in: nil, contentWorld: agentState.world)
        try requireAgentAccess()
        guard pages[tabID] === page, page.courseID == courseID else { throw DesktopBrowserError.unavailable("브라우저 탭 소유권이 변경되었습니다.") }
        if ["inspect", "snapshot", "read"].contains(tool), agentGeneration(page) != generation { throw DesktopBrowserError.unavailable("읽는 동안 페이지가 변경되었습니다. 다시 시도해 주세요.") }
        return result ?? NSNull()
    }
    private func waitForPage(_ page: DesktopBrowserPage) async throws {
        let deadline = Date().addingTimeInterval(20)
        // Navigation becomes loading on the following main run-loop turn.
        try await Task.sleep(for: .milliseconds(50))
        while page.webView.isLoading {
            try Task.checkCancellation()
            guard pages[page.tabID] === page else { throw DesktopBrowserError.unavailable("브라우저 탭이 닫혔습니다.") }
            if Date() > deadline { throw DesktopBrowserError.unavailable("페이지 로드가 지연되고 있습니다. 잠시 뒤 다시 살펴봐 주세요.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

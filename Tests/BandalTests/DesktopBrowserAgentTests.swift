import XCTest
import WebKit
@testable import Bandal

@MainActor
final class DesktopBrowserAgentTests: XCTestCase {
    private func fixture(isPrivate: Bool = false) async throws -> (DesktopBrowserHost, DesktopBrowserPage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-agent-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        let page = try host.createPage(tabID: "fixture", profileID: "default", isPrivate: isPrivate, courseID: "course")
        page.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let loaded = expectation(description: "Real WebKit fixture loaded")
        host.emit = { channel, value in
            if channel == "browser:page-event", (value as? [String: Any])?["name"] as? String == "did-finish-load" { loaded.fulfill() }
        }
        page.webView.loadHTMLString("""
        <!doctype html><html><head><title>Browser fixture</title></head><body>
        <h1>Lecture fixture</h1><input id="query" aria-label="Query"><button type="button" id="expand" onclick="this.textContent='Expanded'">Expand</button>
        <form method="post" onsubmit="event.preventDefault();window.submitCount=(window.submitCount||0)+1">
        <input id="username" aria-label="Username"><input type="password" id="password" aria-label="Password">
        <button type="submit" id="submit">Submit</button></form><input type="file" id="attachment" aria-label="Attachment" onchange="window.attachedCount=(window.attachedCount||0)+1"><article><p>Actual article body for reading.</p></article>
        </body></html>
        """, baseURL: URL(string: "https://example.test/lecture"))
        await fulfillment(of: [loaded], timeout: 15); host.emit = { _, _ in }
        return (host, page)
    }
    private func call(_ host: DesktopBrowserHost, _ tool: String, input: [String: Any] = [:], expected: [String: Any] = [:]) async throws -> [String: Any] {
        var request: [String: Any] = ["tool": tool, "courseId": "course", "input": ["tabId": "fixture"].merging(input, uniquingKeysWith: { _, new in new })]
        request.merge(expected, uniquingKeysWith: { _, new in new })
        let result = try await host.agentRequest(request)
        return try XCTUnwrap(result as? [String: Any])
    }
    private func reference(_ snapshot: [String: Any], named name: String) throws -> String {
        let outline = try XCTUnwrap(snapshot["outline"] as? String)
        let line = try XCTUnwrap(outline.components(separatedBy: .newlines).first { $0.contains("\"\(name)\"") })
        let expression = try NSRegularExpression(pattern: "f[0-9]+:e[0-9]+@[0-9]+")
        let range = try XCTUnwrap(expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))?.range)
        return (line as NSString).substring(with: range)
    }
    private func fails(_ operation: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected refusal", file: file, line: line) } catch {}
    }
    func testOriginalDriverReadsTypesAndRejectsPasswordSubmitStaleAndChangedFacts() async throws {
        let (host, page) = try await fixture()
        let snapshot = try await call(host, "snapshot")
        XCTAssertEqual(snapshot["status"] as? String, "ok")
        let query = try reference(snapshot, named: "Query"), password = try reference(snapshot, named: "Password"), submit = try reference(snapshot, named: "Submit")
        let expected: [String: Any] = ["expectedUrl": page.webView.url!.absoluteString, "expectedGeneration": snapshot["generation"]!]
        let facts = try await call(host, "inspect", input: ["ref": query])["facts"]
        var approved = expected; approved["expectedFacts"] = facts
        _ = try await call(host, "act", input: ["ref": query, "action": ["kind": "type", "text": "lecture notes"]], expected: approved)
        let value = try await page.webView.evaluateJavaScript("document.querySelector('#query').value")
        XCTAssertEqual(value as? String, "lecture notes")
        await fails { try await self.call(host, "act", input: ["ref": password, "action": ["kind": "type", "text": "must never type"]], expected: expected) }
        await fails { try await self.call(host, "act", input: ["ref": submit, "action": ["kind": "click"]], expected: expected) }
        await fails { try await self.call(host, "inspect", input: ["ref": "f0:e1@9999"]) }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#query').type='password'")
        await fails { try await self.call(host, "act", input: ["ref": query, "action": ["kind": "type", "text": "changed type"]], expected: approved) }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#query').type='text';let n=document.createElement('button');n.textContent='Inserted';document.body.prepend(n)")
        await fails { try await self.call(host, "act", input: ["ref": query, "action": ["kind": "type", "text": "changed ordinal"]], expected: expected) }
        let read = try await call(host, "read")
        XCTAssertTrue((read["text"] as? String)?.contains("Actual article body") == true)
        let secret = try await page.webView.evaluateJavaScript("document.querySelector('#password').value")
        XCTAssertEqual(secret as? String, "")
    }
    func testCoursePrivacySettingsDownloadAndArticleOwnershipBoundaries() async throws {
        let (host, page) = try await fixture()
        await fails { try await host.agentRequest(["tool": "read", "courseId": "other-course", "input": ["tabId": "fixture"]]) }
        let download = try await call(host, "download", input: ["url": "https://example.test/material.pdf", "dirRelPath": "lectures"])
        XCTAssertEqual(download["courseId"] as? String, "course"); XCTAssertEqual(download["tabId"] as? String, "fixture")
        await fails { try await self.call(host, "download", input: ["url": "file:///secret"]) }
        host.applySettings(["agentUse": false, "trackingProtection": "off", "doNotTrack": false])
        await fails { try await self.call(host, "read") }
        await fails { try await self.call(host, "download", input: ["url": "https://example.test/material.pdf"]) }
        let address = page.webView.url!.absoluteString
        let script = "({title:document.title,text:document.querySelector('article').textContent})"
        let extracted = try await host.extractArticle(courseID: "course", tabID: "fixture", expectedURL: address, script: script, resolve: { _ in ["93.184.216.34"] })
        XCTAssertEqual((extracted["raw"] as? [String: Any])?["title"] as? String, "Browser fixture")
        await fails { try await host.extractArticle(courseID: "other-course", tabID: "fixture", expectedURL: address, script: script, resolve: { _ in ["93.184.216.34"] }) }
        await fails { try await host.extractArticle(courseID: "course", tabID: "fixture", expectedURL: address, script: script, resolve: { _ in ["127.0.0.1"] }) }
        await fails { try await host.extractArticle(courseID: "course", tabID: "fixture", expectedURL: address, script: script, resolve: { _ in
            await MainActor.run { page.courseID = "changed" }; return ["93.184.216.34"]
        }) }
    }
    func testNativeCredentialFillNeverTrustsSyntheticInputAndRejectsPrivateOrNavigatedPage() async throws {
        let (host, page) = try await fixture()
        let target = try host.credentialTarget(guestID: page.id, origin: "https://example.test")
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#username').value='forged';document.querySelector('#password').value='forged-password';document.querySelector('#password').dispatchEvent(new InputEvent('input',{bubbles:true}));window.__bandalNativeLoginCapture=()=>({username:'forged',password:'forged'});void 0")
        let ignored = try await host.captureLogin(target); XCTAssertNil(ignored)
        let filled = try await host.fillLogin(target, username: "fixture-user", password: "fixture-secret", autoSubmit: false)
        XCTAssertEqual(filled, ["filled": true, "submitted": false])
        let values = try await page.webView.evaluateJavaScript("[document.querySelector('#username').value,document.querySelector('#password').value,window.submitCount||0]") as? [Any]
        XCTAssertEqual(values?[0] as? String, "fixture-user"); XCTAssertEqual(values?[1] as? String, "fixture-secret"); XCTAssertEqual(values?[2] as? Int, 0)
        let untrustedFill = try await host.captureLogin(target); XCTAssertNil(untrustedFill)
        let submitted = try await host.fillLogin(target, username: "fixture-user", password: "fixture-secret", autoSubmit: true)
        XCTAssertEqual(submitted["submitted"], true)
        let count = try await page.webView.evaluateJavaScript("window.submitCount"); XCTAssertEqual(count as? Int, 1)
        _ = try await page.webView.evaluateJavaScript("history.replaceState({},'', '/changed')")
        await fails { try await host.fillLogin(target, username: "fixture-user", password: "fixture-secret", autoSubmit: false) }
        XCTAssertThrowsError(try host.credentialTarget(guestID: page.id, origin: "https://other.test"))
        let (privateHost, privatePage) = try await fixture(isPrivate: true)
        XCTAssertThrowsError(try privateHost.credentialTarget(guestID: privatePage.id, origin: "https://example.test"))
    }
    func testApprovedSemanticKeysSubmitAndFileAttachmentMutateActualDOMWithStaleGuards() async throws {
        let (host, page) = try await fixture()
        let snapshot = try await call(host, "snapshot")
        let submitRef = try reference(snapshot, named: "Submit"), fileRef = try reference(snapshot, named: "Attachment")
        let url = page.webView.url!.absoluteString, generation = snapshot["generation"]!
        let submitFacts = try await call(host, "inspect", input: ["ref": submitRef])["facts"]!
        let expected: [String: Any] = ["expectedUrl": url, "expectedGeneration": generation, "expectedFacts": submitFacts]
        await fails { try await self.call(host, "submit", input: ["ref": submitRef], expected: expected) }
        let submitted = try await call(host, "submit", input: ["ref": submitRef, "approved": true], expected: expected)
        XCTAssertEqual(submitted["semanticAction"] as? String, "activate-approved-submit-control")
        let submitCount = try await page.webView.evaluateJavaScript("window.submitCount"); XCTAssertEqual(submitCount as? Int, 1)
        _ = try await page.webView.evaluateJavaScript("document.querySelector('form').action='https://other.test/upload'")
        await fails { try await self.call(host, "submit", input: ["ref": submitRef, "approved": true], expected: expected) }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('#query').focus()")
        let focused = try await call(host, "inspect", input: ["focused": true])
        let focusedExpected: [String: Any] = ["expectedUrl": url, "expectedGeneration": generation, "expectedFacts": focused["facts"]!]
        let keyInput: [String: Any] = ["key": "Tab", "focusToken": focused["focusToken"]!]
        let tabbed = try await call(host, "key", input: keyInput, expected: focusedExpected)
        XCTAssertEqual(tabbed["semanticAction"] as? String, "focus-next-element")
        let active = try await page.webView.evaluateJavaScript("document.activeElement.id"); XCTAssertEqual(active as? String, "expand")
        await fails { try await self.call(host, "key", input: keyInput, expected: focusedExpected) }
        let buttonFocus = try await call(host, "inspect", input: ["focused": true])
        let buttonExpected: [String: Any] = ["expectedUrl": url, "expectedGeneration": generation, "expectedFacts": buttonFocus["facts"]!]
        await fails { try await self.call(host, "key", input: ["key": "Enter", "focusToken": buttonFocus["focusToken"]!], expected: buttonExpected) }
        _ = try await call(host, "key", input: ["key": "Enter", "focusToken": buttonFocus["focusToken"]!, "approved": true], expected: buttonExpected)
        let expanded = try await page.webView.evaluateJavaScript("document.querySelector('#expand').textContent"); XCTAssertEqual(expanded as? String, "Expanded")

        let fileFacts = try await call(host, "inspect", input: ["ref": fileRef])["facts"]!
        let fileExpected: [String: Any] = ["expectedUrl": url, "expectedGeneration": generation, "expectedFacts": fileFacts]
        var fileReads = 0
        host.onAgentAttachment = { course, path in
            XCTAssertEqual(course, "course"); XCTAssertEqual(path, "notes.txt"); fileReads += 1
            return (name: "notes.txt", mimeType: "text/plain", data: Data("actual fixture bytes".utf8))
        }
        let attachment: [String: Any] = ["ref": fileRef, "approved": true, "courseId": "course", "relPath": "notes.txt"]
        await fails { try await self.call(host, "attachFile", input: ["ref": fileRef, "approved": true, "courseId": "other-course", "relPath": "notes.txt"], expected: fileExpected) }
        XCTAssertEqual(fileReads, 0)
        let result = try await call(host, "attachFile", input: attachment, expected: fileExpected)
        XCTAssertEqual(result["attached"] as? Bool, true); XCTAssertEqual(result["submitted"] as? Bool, false)
        let content = try await page.webView.callAsyncJavaScript("return await document.querySelector('#attachment').files[0].text()", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(content as? String, "actual fixture bytes")
        let finalCount = try await page.webView.evaluateJavaScript("window.submitCount"); XCTAssertEqual(finalCount as? Int, 1)
        host.onAgentAttachment = { _, _ in
            _ = try await page.webView.evaluateJavaScript("history.replaceState({},'', '/different-page')")
            return (name: "notes.txt", mimeType: "text/plain", data: Data("must not attach".utf8))
        }
        await fails { try await self.call(host, "attachFile", input: attachment, expected: fileExpected) }
    }
}

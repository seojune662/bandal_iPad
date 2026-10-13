import Foundation
import WebKit

extension DesktopBrowserHost {
    func extractArticle(courseID: String, tabID: String, expectedURL: String, script: String,
                        resolve: PublicArticleClient.Resolver = PublicArticleClient().resolve) async throws -> [String: Any] {
        let address = try PublicArticleClient.validateURL(expectedURL)
        guard let page = pages[tabID], page.courseID == courseID, !page.webView.isLoading,
              let current = page.webView.url, try PublicArticleClient.validateURL(current.absoluteString) == address else {
            throw DesktopBrowserError.unavailable("이 과목에 연결된 현재 원문 탭을 확인할 수 없습니다.")
        }
        let document = page.state["authDocumentId"] as? String, ownership = page.ownershipRevision
        let resolved = try await resolve(address.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard !resolved.isEmpty, resolved.allSatisfy(PublicArticleClient.isPublicAddress) else { throw DesktopBrowserError.unavailable("로컬 또는 비공개 네트워크의 기사는 자동으로 읽지 않아요.") }
        try Task.checkCancellation()
        guard pages[tabID] === page, page.courseID == courseID, page.ownershipRevision == ownership,
              page.state["authDocumentId"] as? String == document, !page.webView.isLoading else { throw DesktopBrowserError.unavailable("원문 탭이 변경되었습니다. 다시 시도해 주세요.") }
        let result = try await page.webView.callAsyncJavaScript("const actual=new URL(location.href), wanted=new URL(expected); actual.hash=''; wanted.hash=''; if(actual.href !== wanted.href) throw new Error('Source tab changed'); return \(script)", arguments: ["expected": address.absoluteString], in: nil, contentWorld: .world(name: "bandal-article-extractor"))
        guard pages[tabID] === page, page.courseID == courseID, page.ownershipRevision == ownership,
              page.state["authDocumentId"] as? String == document, !page.webView.isLoading,
              let actual = page.webView.url, try PublicArticleClient.validateURL(actual.absoluteString) == address,
              let raw = result as? [String: Any] else { throw DesktopBrowserError.unavailable("원문 탭이 변경되었거나 본문을 추출하지 못했습니다.") }
        return ["raw": raw, "sourceUrl": address.absoluteString, "access": "source-tab"]
    }
}

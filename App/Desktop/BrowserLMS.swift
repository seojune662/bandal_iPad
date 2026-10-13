import Foundation
import WebKit

extension DesktopBrowserHost {
    func fetchLMS(url raw: String, origin: String, profileID: String) async throws -> [String: Any] {
        let url = try Self.navigationURL(raw)
        guard Self.origin(url) == origin, url.user == nil, url.password == nil,
              url.path.range(of: #"^/api/v1/courses/[0-9]+/(discussion_topics|assignments|modules|files)$"#, options: .regularExpression) != nil,
              isProfileAvailable(profileID), let store = persistence?.dataStore(profile: profileID, isPrivate: false) else {
            throw DesktopBrowserError.invalid("연결된 Canvas 강의실 목록 주소")
        }
        let cookies = await store.httpCookieStore.allCookies()
        try requireAgentAccess()
        guard isProfileAvailable(profileID) else { throw DesktopBrowserError.unavailable("브라우저 프로필이 변경되었습니다.") }
        let result = try await BrowserLMSResponse.fetch(url, cookies: cookies, doNotTrack: doNotTrack)
        try requireAgentAccess()
        guard isProfileAvailable(profileID) else { throw DesktopBrowserError.unavailable("브라우저 프로필이 변경되었습니다.") }
        return result
    }
}

private final class BrowserLMSRedirect: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let origin: String
    let scope: BrowserFaviconRedirect
    var redirects = 0
    static let limit: Int64 = 4 * 1024 * 1024
    init(url: URL, cookies: [HTTPCookie], doNotTrack: Bool) {
        origin = Self.origin(url)
        scope = BrowserFaviconRedirect(cookies: cookies, doNotTrack: doNotTrack)
    }
    nonisolated static func origin(_ url: URL) -> String {
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(port)"
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let address = newRequest.url, address.user == nil, address.password == nil, Self.origin(address) == origin else { completionHandler(nil); return }
        completionHandler(scope.request(for: address))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.limit || totalBytesExpectedToWrite > Self.limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum BrowserLMSResponse {
    static func fetch(_ url: URL, cookies: [HTTPCookie], doNotTrack: Bool) async throws -> [String: Any] {
        let delegate = BrowserLMSRedirect(url: url, cookies: cookies, doNotTrack: doNotTrack)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = delegate.scope.request(for: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
        guard let response = response as? HTTPURLResponse, size <= BrowserLMSRedirect.limit else {
            throw DesktopBrowserError.unavailable("강의실 응답이 너무 크거나 읽을 수 없습니다.")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= BrowserLMSRedirect.limit, let text = String(data: data, encoding: .utf8) else { throw DesktopBrowserError.unavailable("강의실 응답의 문자 형식을 읽을 수 없습니다.") }
        return ["status": "ok", "httpStatus": response.statusCode, "text": text, "url": response.url?.absoluteString ?? url.absoluteString]
    }
}

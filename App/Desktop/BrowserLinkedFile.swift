import Foundation

/// URLSession owns no cookie jar. The snapshot comes only from the selected
/// WK profile, with origin/path/secure filtering on each redirect.
private final class BrowserLinkedFileDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let byteLimit: Int64 = 150 * 1024 * 1024
    private let scope: BrowserFaviconRedirect
    private var redirects = 0
    init(cookies: [HTTPCookie], doNotTrack: Bool) { scope = BrowserFaviconRedirect(cookies: cookies, doNotTrack: doNotTrack) }
    func request(_ url: URL) -> URLRequest { var request = scope.request(for: url); request.timeoutInterval = 60; return request }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 10, let url = newRequest.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request(url))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.byteLimit || totalBytesExpectedToWrite > Self.byteLimit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
}

enum BrowserLinkedFile {
    static func fetch(_ url: URL, cookies: [HTTPCookie], doNotTrack: Bool = false) async throws -> (fileName: String, dataBase64: String) {
        guard url.user == nil, url.password == nil else { throw DesktopBrowserError.invalid("다운로드 주소") }
        let delegate = BrowserLinkedFileDelegate(cookies: cookies, doNotTrack: doNotTrack)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: delegate.request(url))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw DesktopBrowserError.unavailable("서버가 자료를 내려주지 않았습니다. 원래 웹 탭에서 로그인 상태를 확인해 주세요.") }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= BrowserLinkedFileDelegate.byteLimit else { throw DesktopBrowserError.unavailable("다운로드 자료가 비어 있거나 150 MB를 초과했습니다.") }
        let proposed = (response.suggestedFilename ?? response.url?.lastPathComponent ?? "다운로드") as NSString
        let safe = String(proposed.lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: ":", with: "_")
        let fileName = String(safe.prefix(180))
        return (fileName.isEmpty || fileName == "." || fileName == ".." ? "다운로드" : fileName, try Data(contentsOf: temporary, options: .mappedIfSafe).base64EncodedString())
    }
}

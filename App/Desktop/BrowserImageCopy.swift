import Foundation
import ImageIO
import UIKit
import WebKit

private final class BrowserImageRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let scope: BrowserFaviconRedirect
    private let userAgent: String?
    private var redirects = 0
    init(cookies: [HTTPCookie], doNotTrack: Bool, userAgent: String?) {
        scope = BrowserFaviconRedirect(cookies: cookies, doNotTrack: doNotTrack); self.userAgent = userAgent
    }
    func request(_ url: URL) -> URLRequest {
        var request = scope.request(for: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        return request
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 10, let url = newRequest.url, DesktopBrowserImageCopy.isWebImageURL(url) else { completionHandler(nil); return }
        completionHandler(request(url))
    }
}

@MainActor
enum DesktopBrowserImageCopy {
    nonisolated static func isWebImageURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
    static func decode(_ data: Data) throws -> UIImage {
        guard data.count <= 32 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 16_000_000,
              let image = UIImage(data: data) else {
            throw DesktopBrowserError.unavailable("복사할 이미지가 너무 크거나 지원되지 않는 형식입니다.")
        }
        return image
    }
    static func image(in webView: WKWebView, at point: CGPoint, doNotTrack: Bool) async throws -> UIImage {
        // Canvas handles blob/data URLs and already decoded same-origin images.
        if let raw = try await webView.callAsyncJavaScript(BrowserScripts.image, arguments: ["x": point.x, "y": point.y], in: nil, contentWorld: .defaultClient) as? String,
           let comma = raw.firstIndex(of: ","), let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])) {
            return try decode(data)
        }
        // A normal CDN image taints a canvas. Fetch its current source through
        // this exact tab's cookie scope; never use URLSession's shared jar.
        let raw = try await webView.callAsyncJavaScript("return document.elementFromPoint(x,y)?.closest('img')?.currentSrc || null", arguments: ["x": point.x, "y": point.y], in: nil, contentWorld: .defaultClient) as? String
        guard let raw, let url = URL(string: raw), isWebImageURL(url) else { throw DesktopBrowserError.unavailable("이 이미지의 원본을 복사할 수 없습니다.") }
        let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let delegate = BrowserImageRedirect(cookies: cookies, doNotTrack: doNotTrack, userAgent: userAgent)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: delegate.request(url))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true, response.expectedContentLength <= 32 * 1024 * 1024 else {
            throw DesktopBrowserError.unavailable("이미지 서버가 원본을 내려주지 않았습니다.")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 32 * 1024 * 1024 else { throw DesktopBrowserError.unavailable("32 MB를 넘는 이미지는 복사할 수 없습니다.") }
        }
        return try decode(data)
    }
}

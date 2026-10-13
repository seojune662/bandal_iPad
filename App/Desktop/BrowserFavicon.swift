import Foundation
import UIKit
import WebKit

/// Uses the selected WebKit session's cookies without consulting or persisting
/// anything in URLSession's shared cookie jar. Redirects rebuild the cookie
/// header for their own origin rather than forwarding a login cookie.
final class BrowserFaviconRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let cookies: [HTTPCookie]
    let doNotTrack: Bool
    init(cookies: [HTTPCookie], doNotTrack: Bool = false) { self.cookies = cookies; self.doNotTrack = doNotTrack }
    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        if doNotTrack { request.setValue("1", forHTTPHeaderField: "DNT"); request.setValue("1", forHTTPHeaderField: "Sec-GPC") }
        let host = url.host?.lowercased() ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let domainMatches = cookie.domain.hasPrefix(".") ? host == domain || host.hasSuffix("." + domain) : host == domain
            let path = url.path.isEmpty ? "/" : url.path
            let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
            return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = newRequest.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { completionHandler(nil); return }
        completionHandler(request(for: url))
    }
}

@MainActor
enum BrowserFavicon {
    static func fetch(_ url: URL, doNotTrack: Bool = false, store: WKWebsiteDataStore) async -> String? {
        let delegate = BrowserFaviconRedirect(cookies: await store.httpCookieStore.allCookies(), doNotTrack: doNotTrack)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: delegate.request(for: url))
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let type = response.mimeType?.lowercased(),
                  ["image/png", "image/jpeg", "image/gif", "image/webp", "image/x-icon", "image/vnd.microsoft.icon"].contains(type),
                  response.expectedContentLength <= 102_400 else { return nil }
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 102_400 { return nil } }
            guard !data.isEmpty, let image = UIImage(data: data), image.size.width <= 512, image.size.height <= 512,
                  let png = image.pngData(), png.count <= 262_144 else { return nil }
            return "data:image/png;base64," + png.base64EncodedString()
        } catch { return nil }
    }
}

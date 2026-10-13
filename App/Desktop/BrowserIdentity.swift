import Foundation
import WebKit

/// Keep WebKit's automatic desktop/mobile identity. Its desktop UA omits the
/// Safari compatibility token, causing some sites to serve obsolete HTML.
/// Append only the engine-reported token using the public configuration API;
/// never freeze a complete user agent or fabricate a Chrome/Safari version.
@MainActor
enum DesktopBrowserIdentity {
    private(set) static var applicationName: String?
    private static var preparation: Task<String, Error>?
    static func prepare() async throws {
        if applicationName != nil { return }
        if preparation == nil {
            preparation = Task {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let probe = WKWebView(frame: .zero, configuration: configuration)
                guard let identity = try await probe.evaluateJavaScript("navigator.userAgent") as? String,
                      let name = applicationName(from: identity) else {
                    throw DesktopBrowserError.unavailable("웹 엔진 정보를 확인하지 못했습니다. 반달을 다시 열어 주세요.")
                }
                return name
            }
        }
        applicationName = try await preparation!.value
    }
    static func applicationName(from identity: String) -> String? {
        guard identity.utf8.count <= 4096,
              let range = identity.range(of: #"\bAppleWebKit/[0-9]+(?:\.[0-9]+)*(?=\s|$)"#, options: .regularExpression) else { return nil }
        return identity[range].replacingOccurrences(of: "AppleWebKit/", with: "Safari/") + " Bandal"
    }
    static func configure(_ configuration: WKWebViewConfiguration) {
        if let applicationName { configuration.applicationNameForUserAgent = applicationName }
    }
}

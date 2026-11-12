import Foundation
import UIKit
import WebKit

/// Keep WebKit's automatic desktop/mobile identity. Its UA omits Safari's
/// `Version/… Safari/…` tokens, so Gmail and others report an unsupported browser.
/// Append exactly those two through the public configuration API: the Safari
/// token from the engine's own version, `Version/` from the system's (Safari has
/// carried the system's version number since iOS 13). Never replace the whole user agent.
@MainActor
enum DesktopBrowserIdentity {
    private static let preparation = BrowserIdentityPreparation()
    static var applicationName: String? { preparation.applicationName }
    static func prepare() async throws {
        try await preparation.prepare {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let probe = WKWebView(frame: .zero, configuration: configuration)
                guard let identity = try await probe.evaluateJavaScript("navigator.userAgent") as? String,
                      let name = applicationName(from: identity) else {
                    throw DesktopBrowserError.unavailable("웹 엔진 정보를 확인하지 못했습니다. 다시 시도해 주세요.")
                }
                return name
        }
    }
    static func applicationName(from identity: String, systemVersion: String = UIDevice.current.systemVersion) -> String? {
        let version = systemVersion.split(separator: ".", omittingEmptySubsequences: false).prefix(2).map(String.init)
        guard identity.utf8.count <= 4096, !version.isEmpty, version.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let range = identity.range(of: #"\bAppleWebKit/[0-9]+(?:\.[0-9]+)*(?=\s|$)"#, options: .regularExpression) else { return nil }
        return "Version/\(version[0]).\(version.count > 1 ? version[1] : "0") " + identity[range].replacingOccurrences(of: "AppleWebKit/", with: "Safari/")
    }
    static func configure(_ configuration: WKWebViewConfiguration) {
        if let applicationName { configuration.applicationNameForUserAgent = applicationName }
    }
}

/// Coalesce simultaneous tab creation, but never cache a failed preparation.
/// A generation prevents an old failed waiter from clearing a newer attempt.
@MainActor
final class BrowserIdentityPreparation {
    private(set) var applicationName: String?
    private var pending: Task<String, Error>?
    private var generation = 0

    func prepare(probe: @escaping @MainActor () async throws -> String) async throws {
        if applicationName != nil { return }
        if pending == nil { generation += 1; pending = Task { try await probe() } }
        let attempt = generation
        guard let task = pending else { return }
        do {
            let name = try await task.value
            if attempt == generation { applicationName = name; pending = nil }
        } catch {
            if attempt == generation { pending = nil }
            throw error
        }
    }
}

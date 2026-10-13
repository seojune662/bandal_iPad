import XCTest
import UIKit
import WebKit
@testable import Bandal

/// Explicitly opt in to anonymous, read-only public website requests. No account
/// is entered, no login form is submitted, no normal cookies are shared. Reports
/// retain only browser identity/layout counters; screenshots are XCTest artifacts.
@MainActor
final class BrowserWebsiteCompatibilityTests: XCTestCase {
    func testPublicLandingPagesWithAutomaticDesktopMobileAndEngineIdentity() async throws {
        guard ProcessInfo.processInfo.environment["BANDAL_VERIFY_PUBLIC_BROWSER"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_BANDAL_VERIFY_PUBLIC_BROWSER=1 for public website compatibility snapshots")
        }
        let sites = [URL(string: "https://www.google.com/")!, URL(string: "https://my.snu.ac.kr/")!]
        var results: [[String: Any]] = []
        for url in sites {
            for variant in ["automatic", "desktop", "mobile"] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-browser-\(UUID())")
                defer { try? FileManager.default.removeItem(at: root) }
                let host = DesktopBrowserHost(root: root)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first { $0.isKeyWindow }
                let window = UIWindow(windowScene: scene), controller = UIViewController()
                window.rootViewController = controller; window.makeKeyAndVisible()
                defer { window.isHidden = true; previous?.makeKeyAndVisible() }
                let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
                host.attach(to: controller.view, shell: shell)
                // Exercise the shipped renderer request route, including engine
                // preparation. No test user agent/configuration is substituted.
                _ = try await host.handle(channel: "browser:createPage", request: ["tabId": "fixture", "isPrivate": true])
                let page = try XCTUnwrap(host.pages["fixture"])
                page.bounds = controller.view.bounds; host.layoutPages()
                let mode = BrowserPresentationMode(rawValue: variant) ?? .automatic
                try host.presentationStore?.set(mode, profile: "default", host: url.host!, isPrivate: true)
                try await host.prepareBrowserNetwork()
                var completed = false, failed = false
                host.emit = { channel, value in
                    guard channel == "browser:page-event", let event = value as? [String: Any] else { return }
                    if event["name"] as? String == "did-finish-load" { completed = true }
                    if event["name"] as? String == "did-fail-load" { failed = true }
                }
                page.webView.load(host.navigationRequest(url))
                let deadline = Date().addingTimeInterval(30)
                while !completed && !failed && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
                if completed { try await Task.sleep(for: .milliseconds(1500)) }
                let diagnostic = (try? await page.webView.evaluateJavaScript("""
                (()=>({userAgent:navigator.userAgent,platform:navigator.platform,readyState:document.readyState,compatMode:document.compatMode,
                viewportWidth:innerWidth,documentWidth:document.documentElement.scrollWidth,devicePixelRatio,
                linkCount:document.querySelectorAll('a').length,buttonCount:document.querySelectorAll('button,[role=button]').length,
                formCount:document.forms.length,passwordFields:document.querySelectorAll('input[type=password]').length,
                stylesheetCount:document.styleSheets.length,scriptCount:document.scripts.length,
                bodyFont:getComputedStyle(document.body).fontFamily,
                googleModernSearch:!!document.querySelector('textarea[name=q]'),googleLegacySearch:!!document.querySelector('input[name=q]') }))()
                """)) as? [String: Any] ?? [:]
                var entry: [String: Any] = ["requestedHost": url.host!, "finalHost": page.webView.url?.host ?? "", "variant": variant, "completed": completed, "failed": failed, "httpStatus": page.state["httpStatus"] ?? 0]
                entry.merge(diagnostic) { _, next in next }; results.append(entry)
                if let image = try? await page.webView.takeSnapshot(configuration: nil) {
                    let shot = XCTAttachment(image: image); shot.name = "Public browser \(url.host!)-\(variant)"; shot.lifetime = .keepAlways; add(shot)
                }
                host.destroy("fixture")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        let report = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        report.name = "Public browser compatibility — identity and DOM counters"; report.lifetime = .keepAlways; add(report)
        // A blocked public network is reported as a test failure, never as
        // evidence that the site displayed correctly or modern UI was achieved.
        func successfulPage(_ result: [String: Any]) -> Bool {
            result["completed"] as? Bool == true && (200..<400).contains(result["httpStatus"] as? Int ?? 0)
        }
        XCTAssertTrue(results.contains { $0["requestedHost"] as? String == "www.google.com" && successfulPage($0) }, "Google landing page did not load; inspect the attached diagnostics")
        XCTAssertTrue(results.contains { $0["requestedHost"] as? String == "my.snu.ac.kr" && successfulPage($0) && ($0["linkCount"] as? Int ?? 0) > 5 && ($0["stylesheetCount"] as? Int ?? 0) > 0 }, "School portal did not render a public page; HTTP error documents are not a compatibility pass")
        for result in results where result["requestedHost"] as? String == "www.google.com" {
            XCTAssertTrue(successfulPage(result)); XCTAssertEqual(result["googleModernSearch"] as? Bool, true)
            XCTAssertEqual(result["googleLegacySearch"] as? Bool, false)
            if result["variant"] as? String == "desktop" { XCTAssertEqual(result["platform"] as? String, "MacIntel") }
            if result["variant"] as? String == "mobile" { XCTAssertEqual(result["platform"] as? String, "iPad") }
        }
    }
}

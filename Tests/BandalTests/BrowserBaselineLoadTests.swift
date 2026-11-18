import WebKit
import XCTest
@testable import Bandal

/// What the same sites take in a WKWebView with nothing of the app's: no scripts, rules or delegates beyond timing.
/// Compared with `NativePerformanceUITests.testLiveBrowserPageLoads` on the same simulator. Network: set
/// `TEST_RUNNER_BANDAL_LIVE_BROWSER=1`.
@MainActor
final class BrowserBaselineLoadTests: XCTestCase {
    private final class Timer: NSObject, WKNavigationDelegate {
        var started = 0.0, committed: Double?, finished: Double?
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = -1 }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = -1 }
    }

    func testBareWebViewLoadsTheSameSites() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_LIVE_BROWSER"] == "1", "Set TEST_RUNNER_BANDAL_LIVE_BROWSER=1 to load real sites.")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 820)); window.isHidden = false
        defer { window.isHidden = true }
        let creation = ProcessInfo.processInfo.systemUptime
        let view = WKWebView(frame: window.bounds, configuration: WKWebViewConfiguration())
        print(String(format: "[BASELINE] create ms=%.1f", (ProcessInfo.processInfo.systemUptime - creation) * 1000))
        window.addSubview(view)
        let timer = Timer(); view.navigationDelegate = timer
        let urls = ["https://www.google.com"] + Self.urls + Self.urls
        for url in urls {
            timer.started = ProcessInfo.processInfo.systemUptime; timer.committed = nil; timer.finished = nil
            view.load(URLRequest(url: try XCTUnwrap(URL(string: url))))
            let deadline = ProcessInfo.processInfo.systemUptime + 40
            while timer.finished == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
            print(String(format: "[BASELINE] %@ commit=%.0f finish=%.0f", url, timer.committed ?? -1, timer.finished ?? -1))
            // The slowest resources: what keeps the page "loading" after it is visible.
            let slowest = try? await view.evaluateJavaScript("""
                JSON.stringify({dcl: Math.round(performance.getEntriesByType('navigation')[0]?.domContentLoadedEventEnd||0), paint: Math.round(performance.getEntriesByName('first-contentful-paint')[0]?.startTime||0), slow: performance.getEntriesByType('resource').sort((a,b)=>b.responseEnd-a.responseEnd).slice(0,4).map(e=>Math.round(e.startTime)+'-'+Math.round(e.responseEnd)+' '+e.name.slice(0,90))})
                """) as? String
            print("[BASELINE] timing " + (slowest ?? "-"))
            try await Task.sleep(for: .seconds(1))
        }
    }
    static let urls = ["https://en.wikipedia.org/wiki/Entropy", "https://www.naver.com", "https://www.snu.ac.kr", "https://developer.apple.com/documentation/pdfkit"]
}
